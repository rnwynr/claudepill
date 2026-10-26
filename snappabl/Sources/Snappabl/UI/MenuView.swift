import SwiftUI

struct MenuView: View {
    @Environment(AppController.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var hasScreenAccess = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            GlassEffectContainer(spacing: 6) {
                VStack(spacing: 8) {
                    ForEach(CaptureAction.allCases) { action in
                        ActionRow(action: action,
                                  shortcut: app.prefs.shortcuts[action],
                                  conflict: app.hotkeyConflicts.contains(action),
                                  recordingSince: action == .record ? app.recordingStartedAt : nil) {
                            trigger(action)
                        }
                    }
                }
            }

            if !hasScreenAccess {
                Button(action: app.openScreenRecordingSettings) {
                    Label("Allow Screen Recording in System Settings", systemImage: "lock.fill")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.orange)
            }

            HStack(spacing: 8) {
                Button(action: app.openSaveFolder) {
                    Label("Folder", systemImage: "folder")
                }
                Spacer()
                Button {
                    dismiss()
                    openWindow(id: SettingsView.windowID)
                    NSApp.activate()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit Snappabl")
            }
            .buttonStyle(.glass)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { hasScreenAccess = app.hasScreenAccess }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppGlyph(size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text("Snappabl").font(.system(size: 14, weight: .bold, design: .rounded))
                Text(app.recorder.isRecording ? "Recording…" : "Ready")
                    .font(.system(size: 11))
                    .foregroundStyle(app.recorder.isRecording ? Color.red : Color.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 2)
    }

    private func trigger(_ action: CaptureAction) {
        let stopping = action == .record && app.recorder.isRecording
        dismiss()
        // Give the menu window a beat to animate away before the overlay appears.
        Task {
            if !stopping { try? await Task.sleep(for: .milliseconds(180)) }
            app.perform(action)
        }
    }
}

private struct ActionRow: View {
    let action: CaptureAction
    let shortcut: Shortcut?
    let conflict: Bool
    let recordingSince: Date?
    let onTap: () -> Void

    private var isLive: Bool { recordingSince != nil }

    private var tint: Color {
        switch action {
        case .screenshotToClipboard: .blue
        case .screenshotToFile: .indigo
        case .record: .red
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: isLive ? "stop.fill" : action.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(tint.gradient, in: .circle)

                VStack(alignment: .leading, spacing: 1) {
                    Text(isLive ? "Stop Recording" : action.title)
                        .font(.system(size: 13, weight: .semibold))
                    if let recordingSince {
                        Text(recordingSince, style: .timer)
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.red)
                    } else {
                        Text(action.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 4)

                if conflict {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("This shortcut is taken by another app. Change it in Settings.")
                }
                if let shortcut {
                    KeyBadge(text: shortcut.displayString)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .glassEffect(isLive ? .regular.tint(.red.opacity(0.22)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 18))
    }
}

struct KeyBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.primary.opacity(0.07), in: .capsule)
    }
}

struct AppGlyph: View {
    var size: CGFloat

    var body: some View {
        Image(systemName: "camera.viewfinder")
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [.cyan, .blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: .rect(cornerRadius: size * 0.28)
            )
    }
}
