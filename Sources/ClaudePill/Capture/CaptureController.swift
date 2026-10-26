import AppKit
import ScreenCaptureKit
import SwiftUI

/// Screenshots and screen recordings, started from global shortcuts or the menu. Everything
/// it has to say (copied, saved, failed, recording) shows up in the island above the pills.
@MainActor
@Observable
final class CaptureController {
    static let shared = CaptureController()

    let prefs = CapturePreferences.shared
    let recorder = RecordingService()
    private(set) var hotkeyConflicts: Set<CaptureAction> = []
    private(set) var recordingStartedAt: Date?

    @ObservationIgnored private var isSelecting = false
    @ObservationIgnored private var recordingChrome: RecordingChrome?

    private init() {}

    func start() {
        HotkeyManager.shared.onTrigger = { [weak self] action in self?.perform(action) }
        registerHotkeys()
        recorder.onFinish = { [weak self] result in self?.recordingDidFinish(result) }
        onboardIfNeeded()
        if let taken = CaptureAction.allCases.first(where: hotkeyConflicts.contains),
           let shortcut = prefs.shortcuts[taken] {
            Island.shared.post(IslandNotice(symbol: "keyboard", name: "Capture",
                                            text: "\(shortcut.displayString) is taken by another app",
                                            level: .low))
        }
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
                let url = try await ImageEncoder.write(png, to: prefs.saveFolder, prefix: "Screenshot")
                showPreview(IslandNotice(symbol: "square.and.arrow.down", thumbnail: thumbnail, name: "Screenshot",
                                         text: "Saved · \(url.lastPathComponent)", level: .success, seconds: 6,
                                         onClick: { NSWorkspace.shared.activateFileViewerSelecting([url]) }))
            } else {
                ImageEncoder.copyToClipboard(png)
                showPreview(IslandNotice(symbol: "doc.on.clipboard", thumbnail: thumbnail, name: "Screenshot",
                                         text: "Copied · \(image.width) × \(image.height)", level: .success,
                                         seconds: 4))
            }
        } catch {
            showError("Screenshot failed", error)
        }
    }

    private func startRecording(_ selection: CaptureSelection) async {
        let startedAt = Date()
        // Put the controls on screen first so the app has visible windows when the capture
        // filter is built — that guarantees they're excluded from the video. The island
        // carries the timer and stop button; the floating one is only needed when it's off.
        let chrome = RecordingChrome(selection: selection, startedAt: startedAt,
                                     showsPill: !PanelController.shared.isShown) { [weak self] in
            self?.perform(.record)
        }
        recordingChrome = chrome
        do {
            try await recorder.start(selection, prefs: prefs)
            recordingStartedAt = startedAt
            Island.shared.recordingSince = startedAt
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
        Island.shared.recordingSince = nil
        switch result {
        case .success(let url):
            Island.shared.post(IslandNotice(symbol: "film", name: "Recording",
                                            text: "Saved · \(url.lastPathComponent)", level: .success, seconds: 8,
                                            onClick: { NSWorkspace.shared.activateFileViewerSelecting([url]) }))
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
    /// `CGRequestScreenCaptureAccess()` is called only the first time: calling it on every
    /// shortcut press re-opened the system prompt each time.
    private func ensureScreenAccess() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if (try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)) != nil {
            return true
        }
        // Ask the system once, on the first capture, so the app shows up in the privacy list.
        if !UserDefaults.standard.bool(forKey: "capture.askedAccess") {
            UserDefaults.standard.set(true, forKey: "capture.askedAccess")
            CGRequestScreenCaptureAccess()
        }
        permissionNeeded()
        return false
    }

    private func permissionNeeded() {
        Island.shared.post(IslandNotice(symbol: "lock.fill", name: "Screen Recording",
                                        text: "Allow Claude Pill in Privacy & Security, then reopen it",
                                        level: .low, seconds: 8,
                                        onClick: { [weak self] in self?.openScreenRecordingSettings() }))
    }

    private func showPreview(_ notice: IslandNotice) {
        guard prefs.showPreview else { return }
        Island.shared.post(notice)
    }

    private func showError(_ title: String, _ error: Error) {
        if (error as? SCStreamError)?.code == .userDeclined { return permissionNeeded() }
        Island.shared.post(IslandNotice(symbol: "exclamationmark.triangle.fill", name: title,
                                        text: error.localizedDescription, level: .critical, seconds: 8))
    }

    /// The first time, say once which shortcuts take screenshots. Screen Recording access is
    /// asked for on the first capture, not at launch: most launches never take one.
    private func onboardIfNeeded() {
        let key = "capture.didOnboard"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let hints = CaptureAction.allCases
            .compactMap { action in prefs.shortcuts[action].map { "\($0.displayString) \(action.verb)" } }
            .joined(separator: " · ")
        Island.shared.post(IslandNotice(symbol: "camera.viewfinder", name: "Capture", text: hints, level: .info))
    }
}
