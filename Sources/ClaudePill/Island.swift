import AppKit
import SwiftUI

/// One notice for the island above the pills: a limit warning, the daily recap, a capture
/// that just finished, an error. Shown for a few seconds, one at a time.
struct IslandNotice: Identifiable, Equatable {
    enum Level { case low, critical, reset, info, success }
    let id = UUID()
    /// Whose logo to show; none for notices about both, like the daily recap.
    var agent: Agent?
    /// SF Symbol shown when there's no agent logo or thumbnail.
    var symbol: String?
    /// A small picture, like the screenshot that was just taken.
    var thumbnail: NSImage?
    /// "Claude", "Codex · <account>", "Screenshot"…
    let name: String
    /// "5h" or "Weekly"; empty when it doesn't apply.
    var window: String = ""
    let text: String
    let level: Level
    var seconds: Double = 12
    /// What clicking the island does while this notice shows, instead of opening the usage panel.
    var onClick: (() -> Void)?

    static func == (a: IslandNotice, b: IslandNotice) -> Bool { a.id == b.id }

    var color: Color {
        switch level {
        case .low: .orange
        case .critical: .errorText
        case .reset, .success: .green
        case .info: .primary
        }
    }

    var tint: Color {
        switch level {
        case .low: Color.orange.opacity(0.16)
        case .critical: Color.red.opacity(0.18)
        case .reset, .success: Color.green.opacity(0.14)
        case .info: .pillBase
        }
    }
}

/// Everything that wants a moment in the island goes through here, so updates from any part
/// of the app (usage, the daily recap, screenshots and recordings) queue up in one place.
@MainActor
final class Island: ObservableObject {
    static let shared = Island()

    /// Waiting notices, oldest first; the first one is on show.
    @Published private(set) var notices: [IslandNotice] = []
    /// Set while a screen recording runs; the island shows its timer and a stop button.
    @Published var recordingSince: Date?
    private var timer: Task<Void, Never>?

    func post(_ notice: IslandNotice) {
        // The pill is switched off: fall back to the corner toast so the update isn't lost.
        guard PanelController.shared.isShown else {
            HUD.shared.show(HUDMessage(notice), duration: .seconds(min(notice.seconds, 6)))
            return
        }
        notices.append(notice)
        if notices.count == 1 { schedule() }
    }

    /// Clears the notice on show; the next one, if any, takes its place.
    func dismiss() {
        guard !notices.isEmpty else { return }
        notices.removeFirst()
        schedule()
    }

    /// Runs the notice's own action, if it has one. Returns false when it has none.
    func click() -> Bool {
        guard let notice = notices.first else { return false }
        dismiss()
        guard let action = notice.onClick else { return false }
        action()
        return true
    }

    private func schedule() {
        timer?.cancel()
        guard let seconds = notices.first?.seconds else { return }
        timer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { Island.shared.dismiss() }
        }
    }
}

extension HUDMessage {
    init(_ notice: IslandNotice) {
        let title = notice.window.isEmpty ? notice.name : "\(notice.name) · \(notice.window)"
        self.init(title: title, subtitle: notice.text,
                  symbol: notice.symbol ?? (notice.level == .critical ? "exclamationmark.triangle.fill" : "info"),
                  tint: notice.level == .info ? .blue : notice.color,
                  thumbnail: notice.thumbnail, onClick: notice.onClick)
    }
}
