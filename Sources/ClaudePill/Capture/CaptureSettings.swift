import AVFoundation
import Combine
import SwiftUI

struct CaptureSettingsView: View {
    static let windowID = "capture-settings"

    @Environment(CaptureController.self) private var app

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                ShortcutsSection()
                SavingSection(prefs: app.prefs)
                RecordingSection(prefs: app.prefs)
                GeneralSection()
            }
            .padding(.horizontal, 22)
            .padding(.top, 38)
            .padding(.bottom, 22)
        }
        .scrollIndicators(.never)
        .frame(width: 500, height: 720)
        .background(Backdrop())
    }

    private var header: some View {
        HStack(spacing: 14) {
            CaptureGlyph(size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("Capture")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Screenshots and recordings, one shortcut away.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Sections

private struct ShortcutsSection: View {
    @Environment(CaptureController.self) private var app

    var body: some View {
        GlassSection(title: "Shortcuts", symbol: "command") {
            ForEach(CaptureAction.allCases) { action in
                SettingRow(action.title, symbol: action.symbol) {
                    if app.hotkeyConflicts.contains(action) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("Another app already uses this combo. Pick a different one.")
                    }
                    ShortcutRecorder(action: action)
                }
            }
            Text("Tip: to use ⌘⇧4-style combos, turn off the matching ones in System Settings → Keyboard → Keyboard Shortcuts → Screenshots first.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SavingSection: View {
    @Bindable var prefs: CapturePreferences

    var body: some View {
        GlassSection(title: "Screenshots", symbol: "photo.on.rectangle") {
            SettingRow("Save to", symbol: "folder") {
                Text(prefs.saveFolder.abbreviatedPath)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 170, alignment: .trailing)
                Button("Change…", action: chooseFolder)
                    .buttonStyle(.glass)
            }
            ToggleRow("Play capture sound", symbol: "speaker.wave.2", isOn: $prefs.playSound)
            ToggleRow("Show captures in the island", symbol: "capsule", isOn: $prefs.showPreview)
            ToggleRow("Include cursor", symbol: "cursorarrow", isOn: $prefs.screenshotShowsCursor)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = prefs.saveFolder
        panel.prompt = "Choose"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            prefs.saveFolder = url
        }
    }
}

private struct RecordingSection: View {
    @Bindable var prefs: CapturePreferences

    var body: some View {
        GlassSection(title: "Recording", symbol: "record.circle") {
            SettingRow("Frame rate", symbol: "speedometer") {
                Picker("", selection: $prefs.frameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
            SettingRow("Codec", symbol: "film") {
                Picker("", selection: $prefs.codec) {
                    ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
            ToggleRow("System audio", symbol: "speaker.wave.3", isOn: $prefs.recordSystemAudio)
            ToggleRow("Microphone", symbol: "mic", isOn: microphoneBinding)
            ToggleRow("Show cursor", symbol: "cursorarrow.motionlines", isOn: $prefs.recordingShowsCursor)
            Text("Encoding runs on the Media Engine, so recording barely touches the CPU. HEVC gives smaller files; H.264 plays everywhere.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Ask for mic access up front so the first recording doesn't stall on a prompt.
    private var microphoneBinding: Binding<Bool> {
        Binding(
            get: { prefs.recordMicrophone },
            set: { enabled in
                guard enabled else { prefs.recordMicrophone = false; return }
                Task { @MainActor in
                    prefs.recordMicrophone = await AVCaptureDevice.requestAccess(for: .audio)
                }
            }
        )
    }
}

private struct GeneralSection: View {
    @Environment(CaptureController.self) private var app
    @State private var screenAccess = CGPreflightScreenCaptureAccess()

    var body: some View {
        // Open at Login lives in the menu, with the rest of Claude Pill's options.
        GlassSection(title: "Permissions", symbol: "lock.shield") {
            SettingRow("Screen Recording", symbol: screenAccess ? "checkmark.shield" : "lock.shield") {
                if screenAccess {
                    Text("Allowed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                } else {
                    Button("Open Settings", action: app.openScreenRecordingSettings)
                        .buttonStyle(.glassProminent)
                        .tint(.orange)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenAccess = CGPreflightScreenCaptureAccess()
        }
    }
}

// MARK: - Building blocks

private struct GlassSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

private struct SettingRow<Trailing: View>: View {
    let title: String
    let symbol: String
    let trailing: Trailing

    init(_ title: String, symbol: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.symbol = symbol
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 28)
    }
}

private struct ToggleRow: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool

    init(_ title: String, symbol: String, isOn: Binding<Bool>) {
        self.title = title
        self.symbol = symbol
        self._isOn = isOn
    }

    var body: some View {
        SettingRow(title, symbol: symbol) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

/// Static, colorful backdrop so the glass has something to refract. Rendered once — no animation.
private struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.6, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: scheme == .dark ? Self.dark : Self.light
        )
        .ignoresSafeArea()
    }

    private static let light: [Color] = [
        Color(red: 0.72, green: 0.85, blue: 1.00), Color(red: 0.82, green: 0.80, blue: 1.00), Color(red: 1.00, green: 0.84, blue: 0.86),
        Color(red: 0.80, green: 0.95, blue: 0.98), Color(red: 0.93, green: 0.92, blue: 1.00), Color(red: 1.00, green: 0.90, blue: 0.80),
        Color(red: 0.78, green: 0.92, blue: 0.88), Color(red: 0.86, green: 0.86, blue: 0.99), Color(red: 0.95, green: 0.82, blue: 0.95),
    ]

    private static let dark: [Color] = [
        Color(red: 0.06, green: 0.10, blue: 0.24), Color(red: 0.16, green: 0.08, blue: 0.30), Color(red: 0.28, green: 0.07, blue: 0.20),
        Color(red: 0.04, green: 0.18, blue: 0.24), Color(red: 0.10, green: 0.10, blue: 0.22), Color(red: 0.26, green: 0.12, blue: 0.10),
        Color(red: 0.03, green: 0.16, blue: 0.16), Color(red: 0.10, green: 0.08, blue: 0.26), Color(red: 0.20, green: 0.06, blue: 0.24),
    ]
}

private extension URL {
    var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

struct CaptureGlyph: View {
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
