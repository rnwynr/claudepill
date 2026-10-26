import Foundation
import Observation

enum VideoCodec: String, CaseIterable, Identifiable {
    case hevc, h264
    var id: String { rawValue }
    var label: String { self == .hevc ? "HEVC" : "H.264" }
}

@MainActor
@Observable
final class CapturePreferences {
    static let shared = CapturePreferences()

    var saveFolder: URL { didSet { defaults.set(saveFolder.path, forKey: Keys.saveFolder) } }
    /// A missing entry means the user cleared that shortcut.
    var shortcuts: [CaptureAction: Shortcut] { didSet { saveShortcuts() } }
    var playSound: Bool { didSet { defaults.set(playSound, forKey: Keys.playSound) } }
    var showPreview: Bool { didSet { defaults.set(showPreview, forKey: Keys.showPreview) } }
    var screenshotShowsCursor: Bool { didSet { defaults.set(screenshotShowsCursor, forKey: Keys.screenshotCursor) } }
    var recordingShowsCursor: Bool { didSet { defaults.set(recordingShowsCursor, forKey: Keys.recordingCursor) } }
    var recordSystemAudio: Bool { didSet { defaults.set(recordSystemAudio, forKey: Keys.systemAudio) } }
    var recordMicrophone: Bool { didSet { defaults.set(recordMicrophone, forKey: Keys.microphone) } }
    var frameRate: Int { didSet { defaults.set(frameRate, forKey: Keys.frameRate) } }
    var codec: VideoCodec { didSet { defaults.set(codec.rawValue, forKey: Keys.codec) } }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let saveFolder = "capture.saveFolder"
        static let shortcuts = "capture.shortcuts"
        static let playSound = "capture.playSound"
        static let showPreview = "capture.showPreview"
        static let screenshotCursor = "capture.screenshotShowsCursor"
        static let recordingCursor = "capture.recordingShowsCursor"
        static let systemAudio = "capture.recordSystemAudio"
        static let microphone = "capture.recordMicrophone"
        static let frameRate = "capture.frameRate"
        static let codec = "capture.codec"
        static let all = [saveFolder, shortcuts, playSound, showPreview, screenshotCursor, recordingCursor,
                          systemAudio, microphone, frameRate, codec]
    }

    static let defaultFolder: URL = FileManager.default
        .urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Claude Pill", isDirectory: true)

    private init() {
        let d = UserDefaults.standard
        Self.importSnappablSettings(d)
        saveFolder = d.string(forKey: Keys.saveFolder).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultFolder
        shortcuts = Self.loadShortcuts(d) ?? CaptureAction.defaultShortcuts
        playSound = d.object(forKey: Keys.playSound) as? Bool ?? true
        showPreview = d.object(forKey: Keys.showPreview) as? Bool ?? true
        screenshotShowsCursor = d.object(forKey: Keys.screenshotCursor) as? Bool ?? false
        recordingShowsCursor = d.object(forKey: Keys.recordingCursor) as? Bool ?? true
        recordSystemAudio = d.object(forKey: Keys.systemAudio) as? Bool ?? false
        recordMicrophone = d.object(forKey: Keys.microphone) as? Bool ?? false
        let fps = d.integer(forKey: Keys.frameRate)
        frameRate = [30, 60].contains(fps) ? fps : 60
        codec = d.string(forKey: Keys.codec).flatMap(VideoCodec.init(rawValue:)) ?? .hevc
    }

    /// Capture used to be a separate app, Snappabl. Its settings come along once, so shortcuts
    /// and the save folder stay what they were.
    private static func importSnappablSettings(_ d: UserDefaults) {
        let done = "capture.importedSnappabl"
        guard !d.bool(forKey: done) else { return }
        d.set(true, forKey: done)
        guard let old = UserDefaults(suiteName: "app.snappabl.Snappabl") else { return }
        for key in Keys.all where d.object(forKey: key) == nil {
            let oldKey = String(key.dropFirst("capture.".count))
            if let value = old.object(forKey: oldKey) { d.set(value, forKey: key) }
        }
    }

    private static func loadShortcuts(_ d: UserDefaults) -> [CaptureAction: Shortcut]? {
        guard let data = d.data(forKey: Keys.shortcuts),
              let raw = try? JSONDecoder().decode([String: Shortcut].self, from: data) else { return nil }
        var result: [CaptureAction: Shortcut] = [:]
        for (key, value) in raw {
            if let action = CaptureAction(rawValue: key) { result[action] = value }
        }
        return result
    }

    private func saveShortcuts() {
        let raw = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) { defaults.set(data, forKey: Keys.shortcuts) }
    }
}
