import AppKit
import SwiftUI

extension Color {
    /// Claude's clay orange.
    static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)

    /// A light wash of the window background so text stays readable over busy content.
    static let pillBase = Color(nsColor: .windowBackgroundColor).opacity(0.5)

    /// Codex's blue, standing in for Claude's orange on Codex sessions.
    static let codex = Color(red: 0.204, green: 0.502, blue: 1.0)

    /// Red that stays readable on light and dark glass.
    static let errorText = Color(nsColor: .systemRed)
}

let pillWidth: CGFloat = 340

extension SessionInfo {
    /// The agent's colour: Claude orange or Codex blue.
    var accent: Color { agent == .codex ? .codex : .claude }
}
private let pillShape = RoundedRectangle(cornerRadius: 26, style: .continuous)

// MARK: - Root

struct PillStack: View {
    @ObservedObject var store = SessionStore.shared
    @ObservedObject var panel = PanelController.shared
    @ObservedObject var music = NowPlayingStore.shared
    /// Off by default: with it on, neighbouring pills melt into each other.
    @AppStorage("pill.liquidMerge") private var liquidMerge = false
    @Namespace private var glass
    @Namespace private var musicSpace
    @State private var overflowOpen = false
    var onSize: (CGSize) -> Void = { _ in }

    var body: some View {
        GlassEffectContainer(spacing: liquidMerge ? 14 : 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    UsageHandle(open: panel.usageOpen)
                        .glassEffectID("handle", in: glass)
                        .reportFrame("handle")
                    // The hidden player lives here, and grows back out of the same glass.
                    if music.collapsed, let track = music.current {
                        MiniDisc(track: track, space: musicSpace)
                            .glassEffectID("music", in: glass)
                            .glassEffectTransition(.matchedGeometry)
                            .reportFrame("disc")
                    }
                }
                .frame(width: pillWidth)
                if panel.usageOpen {
                    UsagePanel()
                        .glassEffectID("usage", in: glass)
                        .reportFrame("usage")
                        .transition(.blurReplace)
                }
                if !music.collapsed, let track = music.current {
                    NowPlayingPill(track: track, hovering: panel.hoveredId == "music",
                                   compact: store.visible.contains { $0.state == .waiting }, space: musicSpace)
                        .glassEffectID("music", in: glass)
                        .glassEffectTransition(.matchedGeometry)
                        .reportFrame("music")
                        .transition(.opacity)
                }
                if store.visible.isEmpty {
                    // With nothing running only the handle shows; it opens the usage panel.
                    // The idle pill stays only to say the hooks still need installing.
                    if !store.hooksInstalled {
                        IdlePill(hooksInstalled: false)
                            .glassEffectID("idle", in: glass)
                            .reportFrame("idle")
                            .frame(width: pillWidth) // centred in the column the session pills use
                    }
                } else {
                    if store.overflow > 0 && panel.anchorBottom { overflowChip }
                    // Most urgent first, nearest the edge the stack hangs from.
                    ForEach(panel.anchorBottom ? store.visible.reversed() : store.visible) { session in
                        SessionPill(session: session, hovering: panel.hoveredId == session.id)
                            .glassEffectID(session.id, in: glass)
                            .transition(.blurReplace)
                    }
                    if store.overflow > 0 && !panel.anchorBottom { overflowChip }
                }
            }
        }
        .padding(14) // room for the glass edge highlight, shadow and pulse
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .gesture(WindowDrag())
        // The window has a fixed size and the stack hangs from one corner, so pills never
        // shift under the pointer while one of them grows or shrinks.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: panel.anchorBottom ? .bottomLeading : .topLeading)
        .coordinateSpace(.named(pillWindowSpace))
        .onChange(of: store.overflow) { _, count in
            if count == 0 { overflowOpen = false }
        }
    }

    private var overflowChip: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.35, bounce: 0.15)) { overflowOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("+\(store.overflow) more")
                    Image(systemName: overflowOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(overflowOpen ? "Collapse extra sessions" : "Show \(store.overflow) extra sessions")

            if overflowOpen {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.overflowSessions) { session in
                            Button {
                                SessionOpener.open(session)
                                if session.state.isFinished || session.state == .waiting { store.dismiss(session.id) }
                                withAnimation { overflowOpen = false }
                            } label: {
                                HStack(spacing: 10) {
                                    StatusIcon(session: session)
                                        .frame(width: 18, height: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.title)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.primary)
                                        Text(session.subtitle)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "arrow.up.forward")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 48)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: CGFloat(min(store.overflow, 4)) * 50)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: overflowOpen ? pillWidth : 110)
        .glassEffect(.regular.tint(.pillBase), in: RoundedRectangle(cornerRadius: overflowOpen ? 22 : 18))
        .glassEffectID("overflow", in: glass)
        .reportFrame("overflow")
        .frame(width: pillWidth)
    }
}

/// Moves the floating panel with the pointer. Uses screen coordinates so it stays smooth
/// while the window itself moves under the cursor.
private struct WindowDrag: Gesture {
    var body: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { _ in PanelController.shared.dragChanged() }
            .onEnded { _ in PanelController.shared.dragEnded() }
    }
}

// MARK: - Session pill

let pillWindowSpace = "pillWindow"

extension View {
    /// Tells the panel where this piece of glass is, for hover and click-through.
    func reportFrame(_ id: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(pillWindowSpace)) } action: { frame in
            PanelController.shared.pillFrames[id] = frame
        }
        // A view that's gone must stop catching clicks where it used to be.
        .onDisappear { PanelController.shared.pillFrames[id] = nil }
    }
}

struct SessionPill: View {
    let session: SessionInfo
    let hovering: Bool

    private var attention: Bool { session.state == .waiting }

    private var primary: AnyShapeStyle { attention ? AnyShapeStyle(Color.black) : AnyShapeStyle(.primary) }
    private var secondary: AnyShapeStyle { attention ? AnyShapeStyle(Color.black.opacity(0.62)) : AnyShapeStyle(.secondary) }
    private var tertiary: AnyShapeStyle { attention ? AnyShapeStyle(Color.black.opacity(0.45)) : AnyShapeStyle(.tertiary) }

    var body: some View {
        HStack(alignment: hovering || !session.options.isEmpty ? .top : .center, spacing: 12) {
            StatusIcon(session: session)
                .frame(width: 22, height: 22)
                .padding(.top, hovering || !session.options.isEmpty ? 1 : 0)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(primary)
                        .lineLimit(1)
                    if session.agents > 0 { AgentBadge(count: session.agents, tint: session.accent, onWhite: attention) }
                }

                Text(hovering ? session.detail : session.subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(subtitleStyle)
                    .lineLimit(hovering ? 14 : (session.isQuestion ? 2 : 1))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)

                if !session.options.isEmpty {
                    OptionChips(options: session.options)
                        .padding(.top, 5)
                }

                if !session.tasks.isEmpty {
                    if hovering {
                        TaskChecklist(tasks: session.tasks, tint: session.accent, onWhite: attention)
                            .padding(.top, 5)
                            .transition(.opacity)
                    } else {
                        Text("Step \(min(session.tasksDone + 1, session.tasks.count)) of \(session.tasks.count)")
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(tertiary)
                    }
                }

                if hovering {
                    Text(meta)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(tertiary)
                        .padding(.top, 3)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 11)
        .frame(width: pillWidth, alignment: .leading)
        .contentShape(pillShape)
        // Glass tints get darkened in dark mode, so a pill that needs you gets a real white
        // fill and keeps the liquid glass only around its edge.
        .background(attention ? Color.white.opacity(0.94) : Color.clear, in: pillShape)
        .glassEffect(glassStyle, in: pillShape)
        // Errors keep readable glass and are marked by a red edge instead of a red tint.
        .overlay {
            if session.state == .error {
                pillShape.strokeBorder(Color.errorText.opacity(0.75), lineWidth: 1.5).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if !session.tasks.isEmpty {
                TaskProgressBar(done: session.tasksDone, total: session.tasks.count, tint: session.accent)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 4)
                    .allowsHitTesting(false)
            }
        }
        .modifier(AttentionPulse(active: attention))
        .reportFrame(session.id)
        .onTapGesture {
            SessionOpener.open(session)
            // Once you've gone to look, a finished session or one asking for you is handled.
            if session.state.isFinished || session.state == .waiting { SessionStore.shared.dismiss(session.id) }
        }
        .help(openHint)
    }

    private var subtitleStyle: AnyShapeStyle {
        if session.state == .error || session.warning { return AnyShapeStyle(Color.errorText) }
        return secondary
    }

    private var glassStyle: Glass {
        switch session.state {
        case .waiting: .regular.interactive()
        default: .regular.tint(.pillBase).interactive()
        }
    }

    @ViewBuilder private var trailing: some View {
        if hovering {
            Group {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(attention ? AnyShapeStyle(Color.black.opacity(0.55)) : AnyShapeStyle(.secondary))
                    .frame(width: 20, height: 20)
                    .background(attention ? AnyShapeStyle(Color.black.opacity(0.08)) : AnyShapeStyle(.quaternary), in: Circle())
            }
            .contentShape(Circle())
            .onTapGesture { SessionStore.shared.dismiss(session.id) }
            .help("Hide this session")
            .transition(.scale.combined(with: .opacity))
        } else if session.state.isBusy || session.state == .waiting {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(elapsed(since: session.turnStartedAt, now: ctx.date))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(tertiary)
            }
        }
    }

    private var meta: String {
        var parts: [String] = []
        if !session.folder.isEmpty { parts.append(session.folder) }
        parts.append(SessionOpener.hostName(session))
        parts.append(ago(session.updatedAt))
        return parts.joined(separator: " · ")
    }

    private var openHint: String {
        let open = "Click to open in \(SessionOpener.hostName(session))"
        return session.state.isFinished || session.state == .waiting ? open + " and clear it" : open
    }
}

/// A hairline along the bottom of a pill, filling as the agent ticks off its task list.
private struct TaskProgressBar: View {
    let done: Int
    let total: Int
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.18))
                Capsule().fill(tint)
                    .frame(width: max(3, geo.size.width * CGFloat(done) / CGFloat(max(total, 1))))
            }
        }
        .frame(height: 2.5)
        .animation(.spring(duration: 0.6, bounce: 0.2), value: done)
    }
}

/// The agent's task list, shown when you hover a pill.
private struct TaskChecklist: View {
    let tasks: [TaskItem]
    let tint: Color
    let onWhite: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(tasks.prefix(8).enumerated()), id: \.offset) { _, t in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: t.isDone ? "checkmark.circle.fill" : (t.isActive ? "circle.dotted.circle" : "circle"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(t.isDone || t.isActive ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
                    Text(t.isActive ? (t.active ?? t.title) : t.title)
                        .font(.system(size: 11, weight: t.isActive ? .semibold : .regular))
                        .foregroundStyle(t.isDone ? AnyShapeStyle(faded) : AnyShapeStyle(text))
                        .strikethrough(t.isDone, color: .secondary)
                        .lineLimit(2)
                }
            }
            if tasks.count > 8 {
                Text("+\(tasks.count - 8) more").font(.system(size: 10.5)).foregroundStyle(faded)
            }
        }
    }

    private var text: Color { onWhite ? .black.opacity(0.8) : .primary }
    private var faded: Color { onWhite ? .black.opacity(0.4) : .secondary }
}

/// How many sub-agents a session has running.
private struct AgentBadge: View {
    let count: Int
    let tint: Color
    let onWhite: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "person.2.fill").font(.system(size: 8.5, weight: .semibold))
            Text("\(count)").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(onWhite ? 0.14 : 0.2), in: Capsule())
        .help(count == 1 ? "1 agent running" : "\(count) agents running")
    }
}

/// The choices Claude offered, shown as small capsules under the question.
private struct OptionChips: View {
    let options: [String]

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Text(option)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.75))
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(Color.black.opacity(0.07), in: Capsule())
            }
        }
    }
}

/// Soft white rings rippling out from a pill that needs you. Drawn into one Canvas over a
/// fixed-size overlay so each frame is a cheap redraw, not a SwiftUI relayout; and never by
/// scaling the pill, which tears its white fill away from the container-drawn glass.
private struct AttentionPulse: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let reach: CGFloat = 13

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                TimelineView(.animation(paused: reduceMotion)) { ctx in
                    let t = reduceMotion ? 0.3 : ctx.date.timeIntervalSinceReferenceDate
                    Canvas { gc, size in
                        let base = CGRect(origin: .zero, size: size).insetBy(dx: Self.reach, dy: Self.reach)
                        for k in 0..<2 {
                            let p = (t / 1.8 + Double(k) / 2).truncatingRemainder(dividingBy: 1)
                            let grow = 1 + 10 * (1 - pow(1 - p, 3))
                            let ring = base.insetBy(dx: -grow, dy: -grow)
                            gc.stroke(Path(roundedRect: ring, cornerRadius: 26 + grow, style: .continuous),
                                      with: .color(.white.opacity(0.75 * pow(1 - p, 1.6))),
                                      lineWidth: 2.2 - 1.4 * p)
                        }
                    }
                }
                .padding(-Self.reach)
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Idle pill

struct IdlePill: View {
    let hooksInstalled: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "asterisk")
                .font(.system(size: 8.5, weight: .heavy))
                .foregroundStyle(Color.claude)
            Text(hooksInstalled ? "No active sessions" : "Hooks not installed")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .glassEffect(.regular.tint(.pillBase).interactive(), in: .capsule)
        .help(hooksInstalled ? "Claude Pill" : "Run scripts/install.sh to connect Claude Code")
    }
}

// MARK: - Status icon

struct StatusIcon: View {
    let session: SessionInfo

    var body: some View {
        switch session.state {
        case .working:
            Loader(seed: Loader.seed(session.id, session.turnStartedAt), tint: session.accent)
        case .compacting:
            Loader(seed: 0, style: .compacting, tint: session.accent)
        case .waiting:
            symbol(waitingSymbol, session.accent)
        case .error:
            symbol("exclamationmark.triangle.fill", Color.errorText)
        case .stalled:
            symbol("pause.circle.fill", Color.gray)
        case .interrupted:
            symbol("stop.circle.fill", Color.gray)
        case .done:
            // Monochrome: the check is cut out of the green disc, so the glass shows through.
            symbol("checkmark.circle.fill", Color.green)
        }
    }

    private var waitingSymbol: String {
        switch session.attention {
        case .permission: "hand.raised.circle.fill"
        case .question: "questionmark.circle.fill"
        case .plan: "list.bullet.circle.fill"
        case .input, nil: "ellipsis.circle.fill"
        }
    }

    private func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 19))
            .foregroundStyle(color)
            .contentTransition(.symbolEffect(.replace))
    }
}

// MARK: - Flow layout

/// Lays children out left to right, wrapping onto new lines.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

// MARK: - Formatting

private func elapsed(since start: Date, now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(start)))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
    return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
}

private func ago(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 10 { return "just now" }
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    return "\(s / 3600)h ago"
}
