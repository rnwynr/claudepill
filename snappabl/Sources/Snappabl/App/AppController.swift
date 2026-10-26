import AppKit
import ScreenCaptureKit
import SwiftUI

@MainActor
@Observable
final class AppController {
    static let shared = AppController()

    let prefs = Preferences.shared
    let recorder = RecordingService()
    private(set) var hotkeyConflicts: Set<CaptureAction> = []
    private(set) var recordingStartedAt: Date?

    @ObservationIgnored private var isSelecting = false
    @ObservationIgnored private var recordingChrome: RecordingChrome?

    private init() {}

    func start() {
        NSApp.setActivationPolicy(.accessory) // belt and braces for runs without the Info.plist
        HotkeyManager.shared.onTrigger = { [weak self] action in self?.perform(action) }
        registerHotkeys()
        recorder.onFinish = { [weak self] result in self?.recordingDidFinish(result) }
        onboardIfNeeded()
    }

    // MARK: - Shortcuts

    func registerHotkeys() {
        hotkeyConflicts = HotkeyManager.shared.register(prefs.shortcuts)
    }

    func setShortcut(_ shortcut: Shortcut?, for action: CaptureAction) {
        if let shortcut {
            // One combo, one action.
            for (other, existing) in prefs.shortcuts where other != action && existing == shortcut {
                prefs.shortcuts[other] = nil
            }
        }
        prefs.shortcuts[action] = shortcut
        registerHotkeys()
    }

    // MARK: - Actions

    func perform(_ action: CaptureAction) {
        Task { await run(action) }
    }

    private func run(_ action: CaptureAction) async {
        if action == .record {
            if recorder.isStarting { return }
            if recorder.isRecording {
                await recorder.stop()
                return
            }
        }
        guard !isSelecting else { return }
        isSelecting = true
        guard await ensureScreenAccess() else {
            isSelecting = false
            return
        }
        let selection = await SelectionOverlay.present(for: action)
        isSelecting = false
        guard let selection else { return }

        switch action {
        case .screenshotToClipboard: await screenshot(selection, toFile: false)
        case .screenshotToFile: await screenshot(selection, toFile: true)
        case .record: await startRecording(selection)
        }
    }

    private func screenshot(_ selection: CaptureSelection, toFile: Bool) async {
        do {
            let shot = try await Screenshotter.capture(selection, showsCursor: prefs.screenshotShowsCursor)
            let image = shot.image
            if prefs.playSound { CaptureSound.play() }
            let png = try await ImageEncoder.png(shot)
            let thumbnail = prefs.showPreview ? ImageEncoder.thumbnail(image) : nil

            if toFile {
                let url = try await ImageEncoder.write(png, to: prefs.saveFolder, prefix: "Snappabl")
                showPreview(HUDMessage(title: "Screenshot saved", subtitle: url.lastPathComponent,
                                       thumbnail: thumbnail,
                                       onClick: { NSWorkspace.shared.activateFileViewerSelecting([url]) }))
            } else {
                ImageEncoder.copyToClipboard(png)
                showPreview(HUDMessage(title: "Copied to clipboard", subtitle: "\(image.width) × \(image.height) px",
                                       symbol: "doc.on.clipboard", thumbnail: thumbnail))
            }
        } catch {
            showError("Screenshot failed", error)
        }
    }

    private func startRecording(_ selection: CaptureSelection) async {
        let startedAt = Date()
        // Put the controls on screen first so Snappabl has visible windows when the capture
        // filter is built — that guarantees they're excluded from the video.
        let chrome = RecordingChrome(selection: selection, startedAt: startedAt) { [weak self] in
            self?.perform(.record)
        }
        recordingChrome = chrome
        do {
            try await recorder.start(selection, prefs: prefs)
            recordingStartedAt = startedAt
        } catch {
            chrome.close()
            recordingChrome = nil
            showError("Couldn't start recording", error)
        }
    }

    private func recordingDidFinish(_ result: Result<URL, Error>) {
        recordingChrome?.close()
        recordingChrome = nil
        recordingStartedAt = nil
        switch result {
        case .success(let url):
            HUD.shared.show(HUDMessage(title: "Recording saved", subtitle: url.lastPathComponent,
                                       symbol: "film", tint: .red,
                                       onClick: { NSWorkspace.shared.activateFileViewerSelecting([url]) }),
                            duration: .seconds(4))
        case .failure(let error):
            showError("Recording failed", error)
        }
    }

    // MARK: - Helpers

    func openSaveFolder() {
        try? FileManager.default.createDirectory(at: prefs.saveFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(prefs.saveFolder)
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    var hasScreenAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// `CGPreflightScreenCaptureAccess()` can report false until the app relaunches, even after
    /// access was granted, so a "no" is double-checked by asking ScreenCaptureKit directly.
    /// Deliberately never calls `CGRequestScreenCaptureAccess()` here: that's what re-opened the
    /// system prompt on every shortcut press.
    private func ensureScreenAccess() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if (try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)) != nil {
            return true
        }
        HUD.shared.show(HUDMessage(title: "Screen Recording permission needed",
                                   subtitle: "Turn on Snappabl in Privacy & Security, then quit and reopen it. Click to open.",
                                   symbol: "lock.fill", tint: .orange,
                                   onClick: { [weak self] in self?.openScreenRecordingSettings() }),
                        duration: .seconds(6))
        return false
    }

    private func showPreview(_ message: HUDMessage) {
        guard prefs.showPreview else { return }
        HUD.shared.show(message)
    }

    private func showError(_ title: String, _ error: Error) {
        let declined = (error as? SCStreamError)?.code == .userDeclined
        let onClick: (() -> Void)? = declined ? { [weak self] in self?.openScreenRecordingSettings() } : nil
        HUD.shared.show(HUDMessage(title: declined ? "Screen Recording permission needed" : title,
                                   subtitle: declined ? "Click to open Privacy & Security." : error.localizedDescription,
                                   symbol: declined ? "lock.fill" : "exclamationmark.triangle.fill",
                                   tint: .orange,
                                   onClick: onClick),
                        duration: .seconds(5))
    }

    private func onboardIfNeeded() {
        let key = "didOnboard"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        let hints = CaptureAction.allCases
            .compactMap { action in prefs.shortcuts[action].map { "\($0.displayString) \(action.title.lowercased())" } }
            .joined(separator: " · ")
        HUD.shared.show(HUDMessage(title: "Snappabl lives in your menu bar", subtitle: hints,
                                   symbol: "camera.viewfinder", tint: .blue),
                        duration: .seconds(6))
    }
}
