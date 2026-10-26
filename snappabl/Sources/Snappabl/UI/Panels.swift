import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Lets clicks land on our panels even while Snappabl isn't the active app.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Transparent, non-activating panel that floats above everything and follows you across Spaces.
/// Used for the HUD, the recording pill and the region outline.
final class FloatingPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func hosting<V: View>(_ view: V) -> (FloatingPanel, FirstMouseHostingView<V>) {
        let host = FirstMouseHostingView(rootView: view)
        host.safeAreaRegions = []
        let panel = FloatingPanel(size: host.fittingSize)
        panel.contentView = host
        return (panel, host)
    }
}

/// Full-screen panel for area selection. Non-activating, so the app you're capturing keeps focus,
/// but it can still become key to receive Esc.
final class OverlayPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onFlagsChanged: ((NSEvent.ModifierFlags) -> Void)?
    var onSpace: ((Bool) -> Void)?
    var onMouseMoved: (() -> Void)?

    private let tracker = MouseMoveTracker()

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        acceptsMouseMovedEvents = true
        // Set explicitly: a clear window otherwise lets clicks pass through its transparent pixels.
        ignoresMouseEvents = false
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }

    /// Installs the content view plus an always-active tracking area, so hover works
    /// even though Snappabl stays in the background while you select.
    func setContent(_ view: NSView) {
        contentView = view
        tracker.onMove = { [weak self] in self?.onMouseMoved?() }
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                            owner: tracker, userInfo: nil))
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown where event.keyCode == UInt16(kVK_Escape), .rightMouseDown:
            onCancel?()
        case .keyDown where event.keyCode == UInt16(kVK_Space):
            if !event.isARepeat { onSpace?(true) }
        case .keyUp where event.keyCode == UInt16(kVK_Space):
            onSpace?(false)
        case .flagsChanged:
            onFlagsChanged?(event.modifierFlags)
        default:
            super.sendEvent(event)
        }
    }
}

private final class MouseMoveTracker: NSResponder {
    var onMove: (() -> Void)?
    override func mouseMoved(with event: NSEvent) { onMove?() }
}
