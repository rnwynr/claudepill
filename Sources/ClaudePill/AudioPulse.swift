import AudioToolbox
import CoreAudio
import Foundation
import os

/// Listens to one music app's audio through a Core Audio process tap (macOS 14.4+) and
/// turns it into a 0…1-ish "kick" value the cover art bounces to. The tap only listens;
/// the music keeps playing out of the speakers as normal. macOS asks once for permission
/// to capture other apps' audio.
final class AudioPulse: @unchecked Sendable {
    static let shared = AudioPulse()

    /// Read every frame by the view; written from the audio thread.
    private let state = OSAllocatedUnfairLock(initialState: Meter())
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var bundlePrefix: String?
    private let queue = DispatchQueue(label: "claudepill.audiopulse", qos: .userInteractive)

    /// How hard the music is hitting right now, about 0 (quiet) to 1.5 (a big kick).
    var kick: Float { state.withLock { $0.kick } }
    /// True once the tap is running, so the view can fall back to a gentle breath otherwise.
    var live: Bool { state.withLock { $0.live } }

    /// Starts listening to the app with this bundle id (helpers included), or stops with nil.
    func follow(_ bundleId: String?) {
        guard bundleId != bundlePrefix || (bundleId != nil && !live) else { return }
        stop()
        bundlePrefix = bundleId
        guard let bundleId else { return }
        start(bundleId)
    }

    private func start(_ bundleId: String) {
        let processes = Self.audioProcesses(matching: bundleId)
        guard !processes.isEmpty else { return } // not making sound yet; tried again on the next state change

        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { tap = AudioObjectID(kAudioObjectUnknown); return }

        let format = Self.tapFormat(tap)
        let output = Self.defaultOutputUID()
        var info: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Claude Pill Listener",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        if let output {
            info[kAudioAggregateDeviceMainSubDeviceKey] = output
            info[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        guard AudioHardwareCreateAggregateDevice(info as CFDictionary, &aggregate) == noErr else { stop(); return }

        let rate = Float(format?.mSampleRate ?? 48_000)
        let channels = Int(max(format?.mChannelsPerFrame ?? 2, 1))
        let interleaved = (format?.mFormatFlags ?? 0) & kAudioFormatFlagIsNonInterleaved == 0
        let state = self.state
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let data = first.mData else { return }
            let stride = interleaved ? channels : 1
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size / stride
            let samples = data.assumingMemoryBound(to: Float.self)
            state.withLock { $0.feed(samples, count: count, stride: stride, rate: rate) }
        }
        guard status == noErr, AudioDeviceStart(aggregate, proc) == noErr else { stop(); return }
        state.withLock { $0.live = true }
    }

    func stop() {
        if aggregate != kAudioObjectUnknown {
            AudioDeviceStop(aggregate, proc)
            if let proc { AudioDeviceDestroyIOProcID(aggregate, proc) }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        proc = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
        bundlePrefix = nil
        state.withLock { $0 = Meter() }
    }

    // MARK: Core Audio lookups

    /// Audio-producing processes whose bundle id starts with `prefix`, e.g. Spotify and its helpers.
    private static func audioProcesses(matching prefix: String) -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { (string($0, kAudioProcessPropertyBundleID) ?? "").hasPrefix(prefix) }
    }

    private static func defaultOutputUID() -> String? {
        var addr = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }

    private static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var addr = address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &format) == noErr ? format : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}

/// Follows the bass: a low-passed envelope that jumps on each hit and falls back quickly,
/// compared with its own slow average so quiet and loud songs bounce about the same.
private struct Meter {
    var live = false
    /// The kick eased in over ~60 ms and out over ~300 ms, so the cover swells rather than snaps.
    var kick: Float = 0
    private var raw: Float = 0
    private var low: Float = 0
    private var envelope: Float = 0
    private var average: Float = 0.001

    mutating func feed(_ samples: UnsafePointer<Float>, count: Int, stride: Int, rate: Float) {
        guard count > 0 else { return }
        let lowpass = 1 - exp(-2 * Float.pi * 140 / rate) // keep roughly the kick drum and bass
        var energy: Float = 0
        for i in 0..<count {
            low += lowpass * (samples[i * stride] - low)
            energy += low * low
        }
        let rms = (energy / Float(count)).squareRoot()
        let dt = Float(count) / rate
        // Instant attack, ~110 ms release; the average drifts over ~1.5 s.
        envelope = rms > envelope ? rms : envelope * exp(-dt / 0.11)
        average += (rms - average) * (1 - exp(-dt / 1.5))
        let floor = max(average, 0.002)
        raw = min(max((envelope - floor * 1.1) / floor, 0), 1.5)
        kick += (raw - kick) * (1 - exp(-dt / (raw > kick ? 0.06 : 0.3)))
    }
}
