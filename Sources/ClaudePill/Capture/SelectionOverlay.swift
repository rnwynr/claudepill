import AppKit
import SwiftUI

/// Covers every screen with a clear overlay that lets the user drag out an area, click for the whole screen,
/// or hold ⌘ and click a window. Windows exist only while selecting and are torn down right after.
///
/// While dragging: ⇧ square · ⌥ grow from center · Space move the selection.
@MainActor
final class SelectionOverlay {
    private var panels: [OverlayPanel] = []
    private var continuation: CheckedContinuation<CaptureSelection?, Never>?
    private let state = SelectionState(windows: WindowList.onScreen())

    static func present(for action: CaptureAction) async -> CaptureSelection? {
        let overlay = SelectionOverlay()
        return await overlay.run(action)
    }

    private func run(_ action: CaptureAction) async -> CaptureSelection? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            showPanels(for: action)
        }
    }

    private func showPanels(for action: CaptureAction) {
        let keyScreen = NSScreen.underMouse
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            let frame = screen.frame
            let displayOrigin = CGDisplayBounds(displayID).origin

            let panel = OverlayPanel(frame: frame)
            panel.onCancel = { [weak self] in self?.finish(nil) }
            panel.onFlagsChanged = { [weak self] flags in self?.state.updateModifiers(flags) }
            panel.onSpace = { [weak self] down in self?.state.space = down }
            panel.onMouseMoved = { [weak self] in self?.state.refreshHover() }

            let view = SelectionView(action: action, state: state, displayOrigin: displayOrigin) { [weak self] result in
                switch result {
                case .area(let rect):
                    self?.finish(CaptureSelection(displayID: displayID, screenFrame: frame, rect: rect))
                case .window(let window):
                    let local = window.frame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
                    self?.finish(CaptureSelection(displayID: displayID, screenFrame: frame, rect: local,
                                                  windowID: window.id))
                }
            }
            let host = FirstMouseHostingView(rootView: view)
            host.safeAreaRegions = []
            panel.setContent(host)
            panels.append(panel)

            if screen == keyScreen {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }
        }
        if panels.isEmpty { finish(nil) }
    }

    private func finish(_ selection: CaptureSelection?) {
        guard let continuation else { return }
        self.continuation = nil
        let closing = panels
        panels.removeAll()
        closing.forEach { $0.orderOut(nil) }
        // We're usually inside one of these panels' event dispatch; free them on the next turn.
        DispatchQueue.main.async { withExtendedLifetime(closing) {} }
        continuation.resume(returning: selection)
    }
}

// MARK: - State shared by all screens' overlays

@MainActor
@Observable
final class SelectionState {
    private(set) var shift = false
    private(set) var option = false
    private(set) var command = false
    var space = false
    var isDragging = false { didSet { refreshHover() } }
    private(set) var hoveredWindow: WindowInfo?

    @ObservationIgnored let windows: [WindowInfo]
    /// Modifiers already down when the overlay opened (usually part of the shortcut, e.g. ⌥⇧).
    /// They're ignored until released, or every selection would start squared and centered.
    @ObservationIgnored private var suppressed: NSEvent.ModifierFlags

    private static let tracked: NSEvent.ModifierFlags = [.shift, .option, .command]

    init(windows: [WindowInfo]) {
        self.windows = windows
        suppressed = NSEvent.modifierFlags.intersection(Self.tracked)
    }

    /// ⌘ held and not mid-drag: hover highlights a window, click captures it.
    var windowMode: Bool { command && !isDragging }

    func updateModifiers(_ flags: NSEvent.ModifierFlags) {
        let down = flags.intersection(Self.tracked)
        suppressed.formIntersection(down)
        let active = down.subtracting(suppressed)
        // Only assign on change so SwiftUI doesn't redraw for nothing.
        if shift != active.contains(.shift) { shift.toggle() }
        if option != active.contains(.option) { option.toggle() }
        if command != active.contains(.command) { command.toggle() }
        refreshHover()
    }

    func refreshHover() {
        var hit: WindowInfo?
        if windowMode {
            let mouse = WindowList.mouseLocation()
            hit = windows.first { $0.frame.contains(mouse) }
        }
        if hit != hoveredWindow { hoveredWindow = hit }
    }
}

enum SelectionResult {
    case area(CGRect?)
    case window(WindowInfo)
}

// MARK: - View

private struct SelectionView: View {
    let action: CaptureAction
    let state: SelectionState
    /// This display's top-left in global CG coordinates, to map window frames into local space.
    let displayOrigin: CGPoint
    let onFinish: (SelectionResult) -> Void

    @State private var origin: CGPoint?
    @State private var point: CGPoint = .zero
    @State private var lastLocation: CGPoint = .zero

    private var isRecording: Bool { action == .record }
    private var accent: Color { isRecording ? .red : .white }

    /// Applies ⇧ (square) and ⌥ (from center) to the raw drag.
    private func selection(in bounds: CGRect) -> CGRect? {
        guard let origin else { return nil }
        var dx = point.x - origin.x
        var dy = point.y - origin.y
        if state.shift {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        let rect = state.option
            ? CGRect(x: origin.x - abs(dx), y: origin.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2)
            : CGRect(x: min(origin.x, origin.x + dx), y: min(origin.y, origin.y + dy), width: abs(dx), height: abs(dy))
        let clipped = rect.intersection(bounds)
        return clipped.isNull ? .zero : clipped
    }

    private var hoveredRect: CGRect? {
        guard state.windowMode, let window = state.hoveredWindow else { return nil }
        return window.frame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
    }

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            let area = selection(in: bounds)
            let windowRect = hoveredRect

            ZStack {
                // Redraws only on drag, modifier or hovered-window changes; an idle overlay costs nothing.
                Canvas { ctx, size in
                    // No dimming. This near-invisible fill only exists so the window server still
                    // routes clicks to us: fully transparent pixels let mouse events fall through.
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.004)))

                    if let r = area, r.width > 0 || r.height > 0 {
                        // Dark outer + light inner line, so the border reads on any background.
                        ctx.stroke(Path(r.insetBy(dx: -1.5, dy: -1.5)), with: .color(.black.opacity(0.55)), lineWidth: 1)
                        ctx.stroke(Path(r.insetBy(dx: -0.5, dy: -0.5)), with: .color(accent.opacity(0.95)), lineWidth: 1)
                    } else if let r = windowRect {
                        let tint: Color = isRecording ? .red : .accentColor
                        ctx.fill(Path(r), with: .color(tint.opacity(0.14)))
                        ctx.stroke(Path(r.insetBy(dx: 1, dy: 1)), with: .color(tint.opacity(0.9)), lineWidth: 2)
                    }
                }

                if let r = area, r.width >= 1 || r.height >= 1 {
                    SizeBadge(text: "\(Int(r.width)) × \(Int(r.height))")
                        .position(badgePosition(for: r, in: bounds))
                } else if let r = windowRect, let window = state.hoveredWindow {
                    SizeBadge(text: "\(window.owner)  ·  \(Int(window.frame.width)) × \(Int(window.frame.height))",
                              symbol: "macwindow")
                        .position(x: min(max(r.midX, 120), bounds.maxX - 120),
                                  y: min(max(r.midY, 20), bounds.maxY - 20))
                }

                HintBar(action: action, state: state, isDragging: origin != nil)
                    .position(x: bounds.midX, y: 92)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: bounds))
        }
        .ignoresSafeArea()
        .pointerStyle(.rectSelection)
        .environment(\.colorScheme, .dark)
    }

    private func dragGesture(in bounds: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let location = clamp(value.location, to: bounds)
                guard let current = origin else {
                    // In window mode, wait for real movement before treating it as an area drag.
                    let moved = hypot(value.translation.width, value.translation.height)
                    if state.windowMode && moved < 4 { return }
                    origin = clamp(value.startLocation, to: bounds)
                    point = location
                    lastLocation = location
                    state.isDragging = true
                    return
                }
                if state.space {
                    // Space: move the whole selection instead of resizing it.
                    origin = CGPoint(x: current.x + location.x - lastLocation.x,
                                     y: current.y + location.y - lastLocation.y)
                }
                point = location
                lastLocation = location
            }
            .onEnded { _ in
                defer {
                    origin = nil
                    state.isDragging = false
                }
                guard origin != nil else {
                    // A click that never became a drag.
                    if state.windowMode {
                        if let window = state.hoveredWindow { onFinish(.window(window)) }
                    } else {
                        onFinish(.area(nil))
                    }
                    return
                }
                guard let r = selection(in: bounds), r.width >= 4 || r.height >= 4 else {
                    onFinish(.area(nil))
                    return
                }
                onFinish(.area(r.integral.intersection(bounds)))
            }
    }

    private func clamp(_ p: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    private func badgePosition(for r: CGRect, in bounds: CGRect) -> CGPoint {
        let below = r.maxY + 22
        let y = below < bounds.maxY - 16 ? below : max(r.minY - 22, 16)
        let x = min(max(r.midX, 60), bounds.maxX - 60)
        return CGPoint(x: x, y: y)
    }
}

private struct SizeBadge: View {
    let text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol) }
            Text(text).monospacedDigit()
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
    }
}

private struct HintBar: View {
    let action: CaptureAction
    let state: SelectionState
    let isDragging: Bool

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                HStack(spacing: 14) {
                    Label(action.title, systemImage: action.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(action == .record ? Color.red : Color.primary)
                    Divider().frame(height: 14)
                    hint("Drag", action == .record ? "record area" : "capture area")
                    hint("Click", "full screen")
                    hint("esc", "cancel")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)

                HStack(spacing: 6) {
                    ModifierChip(key: "⇧", text: "Square", active: state.shift)
                    ModifierChip(key: "⌥", text: "From center", active: state.option)
                    ModifierChip(key: "⌘", text: "Window", active: state.windowMode)
                    ModifierChip(key: "Space", text: "Move", active: state.space && isDragging)
                }
            }
        }
        .fixedSize()
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(key: key, active: false)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }
}

/// Lights up while its modifier is held.
private struct ModifierChip: View {
    let key: String
    let text: String
    let active: Bool

    var body: some View {
        HStack(spacing: 5) {
            KeyCap(key: key, active: active)
            Text(text)
                .foregroundStyle(active ? Color.primary : Color.secondary)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .glassEffect(active ? .regular.tint(.accentColor.opacity(0.45)) : .regular, in: .capsule)
        .animation(.snappy(duration: 0.15), value: active)
    }
}

private struct KeyCap: View {
    let key: String
    let active: Bool

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(active ? 0.35 : 0.16), in: .rect(cornerRadius: 5))
    }
}
