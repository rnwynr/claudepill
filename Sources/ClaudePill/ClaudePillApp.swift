import AppKit
import ServiceManagement
import SwiftUI

@main
struct ClaudePillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var capture = CaptureController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            Image(systemName: capture.recorder.isRecording ? "record.circle.fill" : "asterisk")
        }

        Window("Capture Settings", id: CaptureSettingsView.windowID) {
            CaptureSettingsView()
                .environment(capture)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultLaunchBehavior(.suppressed)
        .defaultPosition(.center)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var gallery: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--gallery") {
            let w = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 920, height: 720),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Loader gallery"
            w.contentView = NSHostingView(rootView: LoaderGallery())
            w.makeKeyAndOrderFront(nil)
            gallery = w
        }
        SessionStore.shared.start()
        UsageStore.shared.start()
        NowPlayingStore.shared.start()
        PanelController.shared.show()
        CaptureController.shared.start()
    }

    /// Let an in-progress recording finalize its file before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let recorder = CaptureController.shared.recorder
        guard recorder.isRecording else { return .terminateNow }
        Task {
            await recorder.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

// MARK: - Menu

struct MenuContent: View {
    @ObservedObject private var store = SessionStore.shared
    @ObservedObject private var panel = PanelController.shared
    @ObservedObject private var music = NowPlayingStore.shared
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("pill.liquidMerge") private var liquidMerge = false
    @Environment(\.openWindow) private var openWindow
    private let capture = CaptureController.shared

    var body: some View {
        if !store.hooksInstalled {
            Text("Claude Code hooks aren't installed yet")
            Text("Run scripts/install.sh in the claudepill folder")
            Divider()
        }
        Toggle("Show Floating Pill", isOn: $panel.isShown)
        Toggle("Hide When No Sessions Are Active", isOn: $store.hideWhenIdle)
        Toggle("Show What Spotify or Music Is Playing", isOn: $music.enabled)
        Toggle("Play a Sound When Claude Finishes", isOn: $store.soundOnFinish)
        Toggle("Melt Neighbouring Pills Together", isOn: $liquidMerge)
        Divider()
        captureSection
        Divider()
        Button("Clear Finished Sessions") { store.clearFinished() }
        Button("Move Pill Back to Top Right") { panel.resetPosition() }
        Divider()
        Toggle("Open at Login", isOn: $openAtLogin)
            .onChange(of: openAtLogin) { _, on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    openAtLogin = SMAppService.mainApp.status == .enabled
                }
            }
        Divider()
        Button("Quit Claude Pill") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private var captureSection: some View {
        ForEach(CaptureAction.allCases) { action in
            let live = action == .record && capture.recorder.isRecording
            let shortcut = capture.prefs.shortcuts[action].map { "   \($0.displayString)" } ?? ""
            let taken = capture.hotkeyConflicts.contains(action) ? " (shortcut taken)" : ""
            Button {
                // Let the menu close before the selection overlay covers the screen.
                Task {
                    if !live { try? await Task.sleep(for: .milliseconds(180)) }
                    capture.perform(action)
                }
            } label: {
                Label((live ? "Stop Recording" : action.title) + shortcut + taken,
                      systemImage: live ? "stop.fill" : action.symbol)
            }
        }
        Button("Open Captures Folder") { capture.openSaveFolder() }
        Button("Capture Settings…") {
            openWindow(id: CaptureSettingsView.windowID)
            NSApp.activate()
        }
    }
}

// MARK: - Floating panel

private final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 90),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // One step above regular floating windows, so other apps' invisible floating
        // overlays (ChatGPT keeps one on the right edge) can't sit on top of the pill.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }

    /// The window is a tall, mostly transparent sheet that may reach past the screen
    /// edges; don't let AppKit pull it back below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: ObservableObject {
    static let shared = PanelController()

    @Published var isShown: Bool {
        didSet {
            UserDefaults.standard.set(isShown, forKey: "pill.shown")
            updateVisibility()
        }
    }

    /// True when the stack hangs from its bottom edge and grows upward (lower half of the screen).
    @Published private(set) var anchorBottom: Bool
    /// The pill under the pointer. Worked out from the pointer position rather than from
    /// enter/exit events, which never arrive if the window starts listening after the
    /// pointer is already inside a pill.
    @Published private(set) var hoveredId: String?
    /// The usage panel opens and closes by clicking the handle, and closes on a click elsewhere.
    @Published private(set) var usageOpen = UserDefaults.standard.bool(forKey: "pill.pinUsage")
    private var outsideClicks: Any?

    func toggleUsage() { setUsage(!usageOpen) }

    func setUsage(_ open: Bool) {
        guard open != usageOpen else { return }
        withAnimation(.spring(duration: 0.4, bounce: 0.18)) { usageOpen = open }
        if !open { pillFrames["usage"] = nil } // let clicks through right away, not after the animation
        if open {
            UsageStore.shared.refreshIfStale()
            // Clicks in other apps never reach this window, so watch for them globally.
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
                Task { @MainActor in PanelController.shared.setUsage(false) }
            }
        } else if let m = outsideClicks {
            NSEvent.removeMonitor(m)
            outsideClicks = nil
        }
    }

    /// Pill frames in window coordinates (top-left origin), reported by the views.
    var pillFrames: [String: CGRect] = [:]

    private let panel = FloatingPanel()
    /// Size of the stack itself; the window is fixed and larger than this.
    private var size = CGSize(width: 368, height: 80)
    /// The window's top-left corner, or its bottom-left corner when `anchorBottom` is set.
    private var anchor: CGPoint
    private var drag: (mouse: CGPoint, origin: CGPoint)?
    private var observers: [Any] = []
    private var mouseTimer: Timer?

    /// The window never resizes: growing it in step with SwiftUI made pills jump under the
    /// pointer. It is tall enough for a full, expanded stack and lets clicks through
    /// everywhere except over the pills.
    private static let windowSize = CGSize(width: 368, height: 1200)
    /// Transparent padding between the window edge and the glass.
    private static let margin: CGFloat = 14

    private static let anchorKey = "pill.anchor"

    private init() {
        isShown = UserDefaults.standard.object(forKey: "pill.shown") as? Bool ?? true
        if let saved = UserDefaults.standard.array(forKey: Self.anchorKey) as? [Double], saved.count == 3 {
            anchor = CGPoint(x: saved[0], y: saved[1])
            anchorBottom = saved[2] != 0
        } else {
            anchor = Self.defaultTopLeft()
            anchorBottom = false
        }

        let host = NSHostingView(rootView: PillStack(panel: self, onSize: { [weak self] size in
            self?.contentSizeChanged(size)
        }))
        host.sizingOptions = []
        // Keep the hosting view out of the window's content-size machinery: as the
        // window's own content view it re-enters AppKit's constraint pass forever.
        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.clampToScreen(animate: true) }
        })
        observers.append(SessionStore.shared.$visible.sink { [weak self] sessions in
            // Keep frames for live pills, plus the idle pill or the overflow chip when shown.
            var ids = Set(sessions.map(\.id)).union(["handle", "usage", "music", "disc"])
            DispatchQueue.main.async {
                if sessions.isEmpty, !SessionStore.shared.hooksInstalled { ids.insert("idle") }
                if !(self?.usageOpen ?? false) { ids.remove("usage") }
                if SessionStore.shared.overflow > 0 { ids.insert("overflow") }
                self?.pillFrames = self?.pillFrames.filter { ids.contains($0.key) } ?? [:]
                self?.updateVisibility()
            }
        })
        observers.append(NowPlayingStore.shared.$current.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateVisibility() }
        })
        observers.append(SessionStore.shared.$hideWhenIdle.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateVisibility() }
        })
        // Notices and a running recording bring the island back even when nothing else shows.
        observers.append(Island.shared.$notices.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateVisibility() }
        })
        observers.append(Island.shared.$recordingSince.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateVisibility() }
        })

        // Let the mouse through the window's empty area and track hover. Checked 30 times a
        // second because an ignoring window gets no events to tell it the pointer came back.
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.trackMouse() }
        }
    }

    /// Where the stack sits inside the window, in window coordinates (top-left origin).
    private var stackRect: CGRect {
        let h = Self.windowSize.height
        return CGRect(x: 0, y: anchorBottom ? h - size.height : 0, width: size.width, height: size.height)
    }

    private func trackMouse() {
        let f = panel.frame
        let mouse = NSEvent.mouseLocation
        let local = CGPoint(x: mouse.x - f.minX, y: f.maxY - mouse.y)
        // The glass the views reported, plus a few points of slack; the stack's box until they have.
        let glass = pillFrames.values.reduce(CGRect.null) { $0.union($1) }
        let target = glass.isNull ? stackRect.insetBy(dx: Self.margin, dy: Self.margin) : glass
        let inside = panel.isVisible && target.insetBy(dx: -4, dy: -4).contains(local)

        let ignore = drag == nil && !inside
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }

        let chrome: Set<String> = ["idle", "overflow", "handle", "usage", "disc"]
        let hovered = (drag == nil && inside)
            ? pillFrames.first { !chrome.contains($0.key) && $0.value.contains(local) }?.key : nil
        if hovered != hoveredId {
            withAnimation(.spring(duration: 0.38, bounce: 0.22)) { hoveredId = hovered }
        }

    }

    func show() {
        layout()
        clampToScreen(animate: false)
        updateVisibility()
    }

    func updateVisibility() {
        let store = SessionStore.shared
        let island = Island.shared
        let idle = store.visible.isEmpty && NowPlayingStore.shared.current == nil
            && island.notices.isEmpty && island.recordingSince == nil
        let wanted = isShown && !(store.hideWhenIdle && idle)
        if wanted, !panel.isVisible { panel.orderFrontRegardless() }
        if !wanted, panel.isVisible { panel.orderOut(nil) }
    }

    func resetPosition() {
        anchor = Self.defaultTopLeft()
        anchorBottom = false
        save()
        layout(animate: true)
    }

    // MARK: Sizing

    fileprivate func contentSizeChanged(_ newSize: CGSize) {
        // Resizing the window inside SwiftUI's layout pass loops AppKit's constraint
        // solver, so apply the new size once the current pass has finished.
        let rounded = CGSize(width: newSize.width.rounded(.up), height: newSize.height.rounded(.up))
        DispatchQueue.main.async { [weak self] in
            guard let self, rounded.width > 0, rounded.height > 0, rounded != self.size else { return }
            self.size = rounded
        }
    }

    private func layout(animate: Bool = false) {
        let w = Self.windowSize
        let y = anchorBottom ? anchor.y : anchor.y - w.height
        panel.setFrame(NSRect(x: anchor.x, y: y, width: w.width, height: w.height), display: true, animate: animate)
    }

    // MARK: Dragging

    func dragChanged() {
        let mouse = NSEvent.mouseLocation
        if drag == nil { drag = (mouse, panel.frame.origin) }
        guard let d = drag else { return }
        var origin = CGPoint(x: d.origin.x + mouse.x - d.mouse.x, y: d.origin.y + mouse.y - d.mouse.y)
        // Magnetic snap points while dragging, so you can feel the pill click into place.
        let offset = snapOffset(for: NSRect(origin: origin, size: Self.windowSize), reach: 48)
        origin.x += offset.dx
        origin.y += offset.dy
        let snapped = offset != .zero
        if snapped && !dragSnapped { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        dragSnapped = snapped
        panel.setFrameOrigin(origin)
    }

    private var dragSnapped = false

    /// How far a window frame is from the nearest snap point, if it's within `reach`: the
    /// screen's left edge, middle or right edge, against its top or bottom edge.
    private func snapOffset(for f: NSRect, reach: CGFloat) -> CGVector {
        let m = Self.margin, gap: CGFloat = 10
        let glassLeft = f.minX + m
        let glassTop = (anchorBottom ? f.minY + size.height : f.maxY) - m
        let glassBottom = glassTop - (size.height - 2 * m)
        let probe = CGPoint(x: glassLeft + pillWidth / 2, y: glassTop - 20)
        guard let visible = (NSScreen.screens.first { $0.frame.contains(probe) } ?? NSScreen.main)?.visibleFrame
        else { return .zero }
        var v = CGVector.zero
        let columns = [visible.minX + gap, visible.midX - pillWidth / 2, visible.maxX - gap - pillWidth]
        if let x = columns.min(by: { abs($0 - glassLeft) < abs($1 - glassLeft) }), abs(x - glassLeft) < reach {
            v.dx = x - glassLeft
        }
        let top = visible.maxY - gap, bottom = visible.minY + gap
        if abs(glassTop - top) < reach { v.dy = top - glassTop }
        else if abs(glassBottom - bottom) < reach { v.dy = bottom - glassBottom }
        return v
    }

    func dragEnded() {
        dragChanged() // a quick flick can end before the last move was applied
        drag = nil
        // Where the stack ended up on screen.
        let f = panel.frame
        // Measured before the anchor edge flips, while the frame still matches what's on screen.
        let o = snapOffset(for: f, reach: 160)
        let stackTop = anchorBottom ? f.minY + size.height : f.maxY
        let stackBottom = stackTop - size.height
        let center = CGPoint(x: f.minX + size.width / 2, y: (stackTop + stackBottom) / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        let midY = screen?.visibleFrame.midY ?? center.y

        // Dropped in the lower half: hang from the bottom edge and grow upward.
        anchorBottom = center.y < midY
        anchor = CGPoint(x: f.minX, y: anchorBottom ? stackBottom : stackTop)
        // Dropped near a snap point but not on it: finish the pull.
        if o != .zero {
            anchor.x += o.dx
            anchor.y += o.dy
            if !dragSnapped { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        dragSnapped = false
        clampToScreen(animate: true)
    }

    fileprivate func clampToScreen(animate: Bool) {
        let pillHeight = min(size.height, 80)
        let probeY = anchorBottom ? anchor.y + pillHeight / 2 : anchor.y - pillHeight / 2
        let probe = CGPoint(x: anchor.x + size.width / 2, y: probeY)
        let screen = NSScreen.screens.first { $0.frame.contains(probe) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let m = Self.margin // the transparent margin around the glass may hang off the edge
        anchor.x = min(max(anchor.x, visible.minX - m), visible.maxX - Self.windowSize.width + m)
        if anchorBottom {
            anchor.y = min(max(anchor.y, visible.minY - m), visible.maxY - pillHeight + m)
        } else {
            anchor.y = min(max(anchor.y, visible.minY + pillHeight - m), visible.maxY + m)
        }
        save()
        layout(animate: animate)
    }

    private func save() {
        UserDefaults.standard.set([Double(anchor.x), Double(anchor.y), anchorBottom ? 1 : 0], forKey: Self.anchorKey)
    }

    private static func defaultTopLeft() -> CGPoint {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: visible.maxX - windowSize.width + margin - 10, y: visible.maxY + margin - 10)
    }
}
