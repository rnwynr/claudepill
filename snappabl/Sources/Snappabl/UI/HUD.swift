import AppKit
import SwiftUI

struct HUDMessage {
    var title: String
    var subtitle: String?
    var symbol: String = "checkmark"
    var tint: Color = .green
    var thumbnail: NSImage?
    var onClick: (() -> Void)?
}

/// Small glass toast in the bottom-right corner after a capture. Click it to act (e.g. reveal the file).
@MainActor
final class HUD {
    static let shared = HUD()

    private var panel: FloatingPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ message: HUDMessage, duration: Duration = .seconds(2.6)) {
        hideTask?.cancel()
        panel?.orderOut(nil)

        let view = HUDView(message: message) { [weak self] in
            message.onClick?()
            self?.hide()
        }
        let (panel, host) = FloatingPanel.hosting(view)
        let size = host.fittingSize
        let visible = (NSScreen.underMouse ?? NSScreen.screens[0]).visibleFrame
        panel.setFrame(CGRect(x: visible.maxX - size.width, y: visible.minY, width: size.width, height: size.height),
                       display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }
        Task {
            try? await Task.sleep(for: .milliseconds(260))
            panel.orderOut(nil)
        }
    }
}

private struct HUDView: View {
    let message: HUDMessage
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let thumbnail = message.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 44)
                    .clipShape(.rect(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            } else {
                Image(systemName: message.symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(message.tint.gradient, in: .circle)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(message.title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle = message.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: 240, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .contentShape(.rect(cornerRadius: 20))
        .onTapGesture(perform: onTap)
        .fixedSize()
        .padding(16) // room for the glass shadow inside the transparent panel
    }
}

/// Floating glass timer + stop button while recording, plus a dashed outline around a region recording.
/// Both are Snappabl windows, so the capture filter keeps them out of the video.
@MainActor
final class RecordingChrome {
    private var panels: [FloatingPanel] = []

    init(selection: CaptureSelection, startedAt: Date, onStop: @escaping () -> Void) {
        let region = selection.globalRect
        let visible = NSScreen.screens.first { $0.displayID == selection.displayID }?.visibleFrame ?? selection.screenFrame

        // A window recording follows the window, so a fixed outline would be wrong.
        let isRegion = selection.rect != nil && selection.windowID == nil
        if isRegion {
            let outlineFrame = region.insetBy(dx: -3, dy: -3)
            let outline = FloatingPanel(size: outlineFrame.size)
            outline.ignoresMouseEvents = true
            outline.contentView = NSHostingView(rootView:
                Rectangle().strokeBorder(Color.red.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            )
            outline.setFrame(outlineFrame, display: false)
            outline.orderFrontRegardless()
            panels.append(outline)
        }

        let (pill, host) = FloatingPanel.hosting(RecordingPill(startedAt: startedAt, onStop: onStop))
        let size = host.fittingSize
        pill.setFrame(CGRect(origin: Self.pillOrigin(size: size, region: region, visible: visible,
                                                     fullScreen: !isRegion), size: size),
                      display: false)
        pill.orderFrontRegardless()
        panels.append(pill)
    }

    func close() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    private static func pillOrigin(size: CGSize, region: CGRect, visible: CGRect, fullScreen: Bool) -> CGPoint {
        let x = min(max(region.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        if fullScreen { return CGPoint(x: x, y: visible.maxY - size.height) }
        var y = region.minY - size.height                       // below the region
        if y < visible.minY { y = region.maxY }                  // above it
        if y + size.height > visible.maxY { y = region.maxY - size.height } // inside, top edge
        return CGPoint(x: x, y: y)
    }
}

private struct RecordingPill: View {
    let startedAt: Date
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            // Text's timer style ticks once a second on its own — no timers of ours.
            Text(startedAt, style: .timer)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 58, alignment: .leading)
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.red.gradient, in: .circle)
            }
            .buttonStyle(.plain)
            .help("Stop recording")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
        .padding(12)
    }
}
