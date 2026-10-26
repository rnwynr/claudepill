import Carbon.HIToolbox
import SwiftUI

/// Click, then press a combo. Esc cancels, ⌫ clears.
struct ShortcutRecorder: View {
    let action: CaptureAction
    @Environment(AppController.self) private var app
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            recorderButton
            if app.prefs.shortcuts[action] != nil && !isRecording {
                Button {
                    app.setShortcut(nil, for: action)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.glass)
                .help("Clear shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    @ViewBuilder
    private var recorderButton: some View {
        let button = Button(action: { isRecording ? stop() : start() }) {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 104)
        }
        if isRecording {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }

    private var label: String {
        if isRecording { return "Type shortcut…" }
        return app.prefs.shortcuts[action]?.displayString ?? "Record Shortcut"
    }

    private func start() {
        isRecording = true
        // Otherwise pressing an existing combo would fire it instead of recording it.
        HotkeyManager.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == UInt16(kVK_Escape) && mods.isEmpty {
            stop()
            return
        }
        if (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)) && mods.isEmpty {
            app.setShortcut(nil, for: action)
            stop()
            return
        }
        guard let shortcut = Shortcut(event: event) else {
            NSSound.beep()
            return
        }
        app.setShortcut(shortcut, for: action)
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording {
            isRecording = false
            app.registerHotkeys()
        }
    }
}
