import AVFoundation
import ScreenCaptureKit

/// Screen recording through `SCRecordingOutput`: ScreenCaptureKit hands frames straight to the
/// hardware HEVC/H.264 encoder and writes the file itself. We never touch, copy or convert a
/// pixel, which is what keeps recording CPU low.
@MainActor
@Observable
final class RecordingService {
    private(set) var isRecording = false
    private(set) var isStarting = false

    @ObservationIgnored var onFinish: ((Result<URL, Error>) -> Void)?
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var recordingOutput: SCRecordingOutput?
    @ObservationIgnored private var outputURL: URL?

    private let callbacks = StreamCallbacks()
    private let sampleQueue = DispatchQueue(label: "local.boywithalo.claudepill.capture", qos: .utility)

    init() {
        callbacks.onFinished = { [weak self] in
            Task { @MainActor in self?.finish(nil) }
        }
        callbacks.onError = { [weak self] error in
            Task { @MainActor in self?.finish(error) }
        }
    }

    func start(_ selection: CaptureSelection, prefs: CapturePreferences) async throws {
        guard stream == nil, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let target = try CaptureTarget.make(for: selection, content: content)

        let config = SCStreamConfiguration()
        target.apply(to: config)
        config.width = Self.evenPixels(target.pixelSize.width)
        config.height = Self.evenPixels(target.pixelSize.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(prefs.frameRate))
        config.showsCursor = prefs.recordingShowsCursor
        config.ignoreShadowsSingleWindow = true
        // Native encoder input format: avoids a BGRA → YUV conversion pass per frame.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        config.capturesAudio = prefs.recordSystemAudio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = prefs.recordMicrophone

        let recording = SCRecordingOutputConfiguration()
        let fileType: AVFileType = recording.availableOutputFileTypes.contains(.mp4) ? .mp4 : .mov
        let codec: AVVideoCodecType = prefs.codec == .hevc ? .hevc : .h264
        recording.outputFileType = fileType
        recording.videoCodecType = recording.availableVideoCodecTypes.contains(codec) ? codec : .h264
        let url = try FileNaming.nextURL(in: prefs.saveFolder, prefix: "Recording",
                                         ext: fileType == .mp4 ? "mp4" : "mov")
        recording.outputURL = url

        let stream = SCStream(filter: target.filter, configuration: config, delegate: callbacks)
        do {
            // No-op sinks: the recording output does the real work. Attaching them keeps
            // ScreenCaptureKit from logging "stream output not found" for every dropped sample.
            try stream.addStreamOutput(callbacks, type: .screen, sampleHandlerQueue: sampleQueue)
            if config.capturesAudio {
                try stream.addStreamOutput(callbacks, type: .audio, sampleHandlerQueue: sampleQueue)
            }
            if config.captureMicrophone {
                try stream.addStreamOutput(callbacks, type: .microphone, sampleHandlerQueue: sampleQueue)
            }
            let output = SCRecordingOutput(configuration: recording, delegate: callbacks)
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
            recordingOutput = output
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        self.stream = stream
        outputURL = url
        isRecording = true
    }

    func stop() async {
        guard let stream, let url = outputURL else { return }
        do {
            try await stream.stopCapture()
        } catch {
            finish(error)
            return
        }
        // The recording output reports completion via its delegate; this is only a fallback
        // in case that callback never arrives.
        try? await Task.sleep(for: .seconds(3))
        if outputURL == url { finish(nil) }
    }

    private func finish(_ error: Error?) {
        guard let url = outputURL else { return } // already reported
        stream = nil
        recordingOutput = nil
        outputURL = nil
        isRecording = false
        // "Stop sharing" from the system's menu bar indicator ends the stream with
        // `.userStopped`; the file is still valid.
        if let error, (error as? SCStreamError)?.code != .userStopped {
            onFinish?(.failure(error))
        } else {
            onFinish?(.success(url))
        }
    }

    /// Video encoders want even dimensions.
    private static func evenPixels(_ value: CGFloat) -> Int {
        max(2, Int(value.rounded(.down)) & ~1)
    }
}

private final class StreamCallbacks: NSObject, SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate {
    var onFinished: (() -> Void)?
    var onError: ((Error) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onError?(error)
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        onError?(error)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        onFinished?()
    }
}
