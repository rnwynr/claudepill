import AppKit
import SwiftUI

/// The grabber above the pills, working like a small Dynamic Island: a short bar most of
/// the time, widening into a one-line notice when something happens (a usage limit runs low
/// or resets, a screenshot is taken, a recording is saved…) and into a live timer while
/// the screen is being recorded. Clicking it opens the usage panel.
struct UsageHandle: View {
    let open: Bool
    @ObservedObject var island = Island.shared

    var body: some View {
        Group {
            if let notice = island.notices.first, !open {
                NoticeIsland(notice: notice)
                    .id(notice.id)
                    .transition(.blurReplace)
            } else if let since = island.recordingSince, !open {
                RecordingIsland(since: since)
                    .transition(.blurReplace)
            } else {
                Capsule()
                    .fill(.primary.opacity(open ? 0.55 : 0.32))
                    .frame(width: open ? 46 : 34, height: 5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .transition(.blurReplace)
            }
        }
        .glassEffect(.regular.tint(tint).interactive(), in: .capsule)
        .contentShape(Rectangle().inset(by: -6))
        .onTapGesture {
            // A notice with its own action (reveal the file, open settings) does that instead.
            if island.click() { return }
            PanelController.shared.toggleUsage()
        }
        .animation(.spring(duration: 0.5, bounce: 0.3), value: island.notices.first?.id)
        .animation(.spring(duration: 0.5, bounce: 0.3), value: island.recordingSince)
        .help(help)
    }

    private var help: String {
        if !open, let notice = island.notices.first, notice.onClick != nil { return "\(notice.name) · \(notice.text)" }
        return open ? "Hide usage limits" : "Show usage limits"
    }

    private var tint: Color {
        guard !open else { return .pillBase }
        if let notice = island.notices.first { return notice.tint }
        if island.recordingSince != nil { return Color.red.opacity(0.16) }
        return .pillBase
    }
}

/// "[logo] Codex · work · 5h · 12% left", or "[thumbnail] Screenshot · Copied · 3024 × 1964"
private struct NoticeIsland: View {
    let notice: IslandNotice

    var body: some View {
        HStack(spacing: 6) {
            if let thumbnail = notice.thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 19)
                    .clipShape(.rect(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            } else if let agent = notice.agent, let icon = agent == .codex ? AppIcon.codex : AppIcon.claude {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 17, height: 17)
            } else if let symbol = notice.symbol {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(notice.level == .info ? Color.orange : notice.color)
            }
            Text(notice.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).layoutPriority(1)
            Text("·").foregroundStyle(.secondary)
            if !notice.window.isEmpty {
                Text(notice.window).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary)
            }
            Text(notice.text).font(.system(size: 12.5, weight: .bold)).foregroundStyle(notice.color)
                .lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 14)
        .frame(height: 30)
    }
}

/// "● Recording 0:42 [■]" while the screen is being recorded.
private struct RecordingIsland: View {
    let since: Date

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text("Recording").font(.system(size: 12.5, weight: .semibold))
            // Ticks once a second on its own; no timers of ours.
            Text(since, style: .timer)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                CaptureController.shared.perform(.record)
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Color.red.gradient, in: .circle)
            }
            .buttonStyle(.plain)
            .help("Stop recording")
        }
        .padding(.leading, 14)
        .padding(.trailing, 5)
        .frame(height: 30)
    }
}

/// Claude's and Codex's 5-hour and weekly limits, with Codex account switching.
struct UsagePanel: View {
    @ObservedObject var usage = UsageStore.shared
    @ObservedObject var stats = DailyStatsStore.shared
    @State private var confirming: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            claudeSection
            Divider().opacity(0.5)
            codexSection
            if stats.today.turns > 0 {
                Divider().opacity(0.5)
                todaySection
            }
        }
        .padding(14)
        .frame(width: pillWidth, alignment: .leading)
        .glassEffect(.regular.tint(.pillBase), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: Today

    private var todaySection: some View {
        let t = stats.today
        let claude = t.seconds(for: .claude), codex = t.seconds(for: .codex)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: "sun.horizon.fill").font(.system(size: 13)).foregroundStyle(.orange)
                    .frame(width: 18, height: 18)
                Text("Today").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(stats.summary).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if claude > 0 { share("Claude", claude, .claude) }
                if codex > 0 { share("Codex", codex, .codex) }
                Text("\(t.sessions.count) session\(t.sessions.count == 1 ? "" : "s")")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            if let top = t.busiest {
                HStack(spacing: 4) {
                    Text("Busiest:").foregroundStyle(.tertiary)
                    Text(top.title).lineLimit(1)
                    Text(UsageStore.duration(top.seconds)).foregroundStyle(.secondary).fixedSize()
                }
                .font(.system(size: 10.5))
            }
        }
    }

    private func share(_ name: String, _ seconds: Double, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text("\(name) \(UsageStore.duration(seconds))").font(.system(size: 10.5, weight: .medium))
        }
    }

    // MARK: Claude

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(icon: AppIcon.claude, name: "Claude",
                   trailing: usage.claude?.plan.map { AnyView(PlanBadge(plan: $0, tint: .claude)) })
            if let r = usage.claude, r.fiveHour != nil || r.weekly != nil {
                LimitBars(report: r, tint: .claude)
                // Older than two check-ins means nothing is keeping these numbers current.
                let stale = Date().timeIntervalSince(r.updatedAt) > 15 * 60
                Text("Updated \(relative(r.updatedAt))\(stale ? " · may be out of date" : "")")
                    .font(.system(size: 10, weight: stale ? .medium : .regular))
                    .foregroundStyle(stale ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                if let problem = r.problem {
                    Text(problem)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(usage.claude?.problem ?? "No limits yet. They load when the Claude Code CLI is signed in (run `claude` then /login), or after a message in a terminal session.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Codex

    private var codexSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(icon: AppIcon.codex, name: "Codex", trailing: usage.refreshing ? AnyView(Loader(seed: 7, tint: .codex).frame(width: 12, height: 12)) : nil)

            if let busy = usage.busy {
                HStack(spacing: 8) {
                    Loader(seed: 11, tint: .codex).frame(width: 14, height: 14)
                    Text(busy).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            } else {
                if usage.liveAccountId == nil {
                    // The signed-in login isn't saved yet.
                    accountRow(id: "live", label: usage.codexLiveEmail ?? "Signed-in account", email: nil,
                               report: usage.codexLive, current: true, account: nil)
                }
                ForEach(usage.codexAccounts) { account in
                    accountRow(id: account.id, label: account.label,
                               email: account.email == account.label ? nil : account.email,
                               report: usage.codexUsage[account.id],
                               current: account.id == usage.liveAccountId, account: account)
                }
                HStack(spacing: 6) {
                    if usage.liveAccountId == nil, usage.codexLiveEmail != nil {
                        smallButton("Save this login", "tray.and.arrow.down") { usage.saveCurrent() }
                    }
                    smallButton("Add account", "plus") { usage.addAccount() }
                    Spacer()
                    smallButton(nil, "arrow.clockwise") { usage.refresh() }
                        .help("Refresh")
                }
            }

            if let err = usage.lastError {
                Text(err).font(.system(size: 10.5)).foregroundStyle(Color.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func accountRow(id: String, label: String, email: String?, report: UsageReport?,
                            current: Bool, account: CodexAccount?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(current ? Color.codex : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
                Text(label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if let email {
                    Text(email).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let plan = report?.plan { PlanBadge(plan: plan, tint: .codex) }
                if account != nil {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Circle())
                        .onTapGesture { withAnimation(.snappy) { confirming = confirming == id ? nil : id } }
                        .help("Remove this saved login")
                }
            }
            if confirming == id, let account {
                HStack(spacing: 6) {
                    Text("Remove this saved login?").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    smallButton("Cancel", nil) { confirming = nil }
                    smallButton("Remove", nil, destructive: true) {
                        confirming = nil
                        usage.remove(account)
                    }
                }
            } else if let report, report.fiveHour != nil || report.weekly != nil {
                LimitBars(report: report, tint: .codex, compact: true)
            } else if let problem = report?.problem {
                Text(problem).font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else {
                Text("Loading…").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(current ? Color.codex.opacity(0.10) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            guard let account, !current, confirming != id else { return }
            usage.switchTo(account)
        }
        .help(current ? "Signed in to Codex" : (account == nil ? "" : "Click to switch Codex to this account"))
    }

    // MARK: Pieces

    private func header(icon: NSImage?, name: String, trailing: AnyView?) -> some View {
        HStack(spacing: 7) {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 18, height: 18)
            }
            Text(name).font(.system(size: 13, weight: .semibold))
            Spacer()
            if let trailing { trailing }
        }
    }

    /// A tap target rather than a Button: focusable controls in this non-activating panel
    /// sent SwiftUI's key-view loop into an endless rebuild that froze the app.
    private func smallButton(_ title: String?, _ symbol: String?, prominent: Bool = false, destructive: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Group {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)) }
                if let title { Text(title).font(.system(size: 11, weight: .medium)) }
            }
            .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : destructive ? AnyShapeStyle(Color.errorText) : AnyShapeStyle(.primary))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(prominent ? AnyShapeStyle(Color.codex) : AnyShapeStyle(.quaternary), in: Capsule())
            .contentShape(Capsule())
        }
        .onTapGesture(perform: action)
    }

    private func relative(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}

/// The 5-hour and weekly bars of one account.
private struct LimitBars: View {
    let report: UsageReport
    let tint: Color
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            if let w = report.fiveHour { row("5h", w) }
            if let w = report.weekly { row("Week", w) }
        }
    }

    private func row(_ name: String, _ w: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            bar(name, w)
            if let empty = w.emptyAt {
                Text("At this pace it runs out in ~\(UsageStore.duration(empty.timeIntervalSinceNow)), before it resets")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .padding(.leading, 38)
            }
        }
    }

    private func bar(_ name: String, _ w: UsageWindow) -> some View {
        let left = 100 - min(max(w.usedPercent, 0), 100)
        let color: Color = left <= 10 ? .errorText : (left <= 25 ? .orange : tint)
        return HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(color).frame(width: max(left > 0 ? 4 : 0, geo.size.width * left / 100))
                }
            }
            .frame(height: compact ? 5 : 6)
            Text("\(Int(left.rounded()))% left")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .frame(width: 54, alignment: .trailing)
            Text(resetText(w.resetsAt))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 74, alignment: .trailing)
        }
    }

    /// Time until the window starts over, leaving out units that are zero, and minutes once
    /// it's a day or more away: "23hr 59min", "2d 4hr".
    private func resetText(_ date: Date?) -> String {
        guard let date else { return "" }
        let mins = Int((date.timeIntervalSinceNow / 60).rounded(.up))
        if mins <= 0 { return "resets now" }
        let d = mins / 1440, h = (mins % 1440) / 60, m = mins % 60
        var parts: [String] = []
        if d > 0 { parts.append("\(d)d") }
        if h > 0 { parts.append("\(h)hr") }
        if m > 0, d == 0 { parts.append("\(m)min") } // minutes don't matter days out
        return parts.joined(separator: " ")
    }
}

private struct PlanBadge: View {
    let plan: String
    let tint: Color
    var body: some View {
        Text(plan.capitalized)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

/// The real app icons, so the panel shows each product's own logo.
enum AppIcon {
    static let claude: NSImage? = icon(bundleId: "com.anthropic.claudefordesktop", fallback: "/Applications/Claude.app")
    static let codex: NSImage? = CodexApp.appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }

    private static func icon(bundleId: String, fallback: String) -> NSImage? {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) ?? URL(fileURLWithPath: fallback)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
