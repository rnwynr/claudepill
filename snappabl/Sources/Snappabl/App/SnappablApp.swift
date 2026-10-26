import SwiftUI

@main
struct SnappablApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(app)
        } label: {
            Image(systemName: app.recorder.isRecording ? "record.circle.fill" : "camera.viewfinder")
        }
        .menuBarExtraStyle(.window)

        Window("Snappabl Settings", id: SettingsView.windowID) {
            SettingsView()
                .environment(app)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultLaunchBehavior(.suppressed)
        .defaultPosition(.center)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppController.shared.start()
    }

    /// Let an in-progress recording finalize its file before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let recorder = AppController.shared.recorder
        guard recorder.isRecording else { return .terminateNow }
        Task {
            await recorder.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
