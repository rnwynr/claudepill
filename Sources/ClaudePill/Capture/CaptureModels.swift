import AppKit
import ScreenCaptureKit

enum CaptureAction: String, CaseIterable, Identifiable, Codable {
    case screenshotToClipboard
    case screenshotToFile
    case record

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshotToClipboard: "Copy Screenshot"
        case .screenshotToFile: "Save Screenshot"
        case .record: "Record Screen"
        }
    }

    var subtitle: String {
        switch self {
        case .screenshotToClipboard: "Capture straight to the clipboard"
        case .screenshotToFile: "Capture to your screenshots folder"
        case .record: "Record an area or the full screen"
        }
    }

    /// "copy", for the one-line hint in the island.
    var verb: String {
        switch self {
        case .screenshotToClipboard: "copy"
        case .screenshotToFile: "save"
        case .record: "record"
        }
    }

    var symbol: String {
        switch self {
        case .screenshotToClipboard: "doc.on.clipboard"
        case .screenshotToFile: "square.and.arrow.down"
        case .record: "record.circle"
        }
    }

    /// Carbon hot key id. Must be non-zero and unique per action.
    var hotkeyID: UInt32 {
        UInt32(CaptureAction.allCases.firstIndex(of: self)! + 1)
    }
}

/// What the user picked in the selection overlay.
struct CaptureSelection {
    let displayID: CGDirectDisplayID
    /// The screen's frame in global AppKit coordinates (bottom-left origin).
    let screenFrame: CGRect
    /// Display-local rect in points with a top-left origin, which is what
    /// `SCStreamConfiguration.sourceRect` expects. `nil` means the whole display.
    let rect: CGRect?
    /// Set when a single window was picked (⌘-click). Captures just that window.
    var windowID: CGWindowID? = nil

    /// `rect` converted to global AppKit coordinates, for placing windows around it.
    var globalRect: CGRect {
        guard let rect else { return screenFrame }
        return CGRect(x: screenFrame.minX + rect.minX,
                      y: screenFrame.maxY - rect.maxY,
                      width: rect.width,
                      height: rect.height)
    }
}

enum CaptureError: LocalizedError {
    case displayUnavailable
    case windowUnavailable
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .displayUnavailable: "That display is no longer available."
        case .windowUnavailable: "That window closed before it could be captured."
        case .encodingFailed: "Couldn't encode the image."
        }
    }
}

/// What to capture and at what size, shared by screenshots and recordings.
struct CaptureTarget {
    let filter: SCContentFilter
    /// Region within the display, or nil for the whole display / a single window.
    let sourceRect: CGRect?
    /// Output size in native pixels (points × the display's backing scale).
    let pixelSize: CGSize

    func apply(to config: SCStreamConfiguration) {
        if let sourceRect { config.sourceRect = sourceRect }
        config.width = max(1, Int(pixelSize.width.rounded()))
        config.height = max(1, Int(pixelSize.height.rounded()))
        config.captureResolution = .best
    }

    static func make(for selection: CaptureSelection, content: SCShareableContent) throws -> CaptureTarget {
        if let windowID = selection.windowID {
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw CaptureError.windowUnavailable
            }
            // Only this window, rendered on its own: nothing overlapping it, transparent corners.
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            return CaptureTarget(filter: filter, sourceRect: nil,
                                 pixelSize: CGSize(width: window.frame.width * scale, height: window.frame.height * scale))
        }

        guard let display = content.displays.first(where: { $0.displayID == selection.displayID }) else {
            throw CaptureError.displayUnavailable
        }
        // Hide every window the app owns: the pills and island, the overlay, recording controls.
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let area = selection.rect ?? CGRect(x: 0, y: 0, width: display.width, height: display.height)
        return CaptureTarget(filter: filter, sourceRect: selection.rect,
                             pixelSize: CGSize(width: area.width * scale, height: area.height * scale))
    }
}

enum FileNaming {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    /// "Screenshot 2026-10-26 at 14.03.22.png", with " (2)" etc. on collision.
    static func nextURL(in folder: URL, prefix: String, ext: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = "\(prefix) \(formatter.string(from: Date()))"
        var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return url
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static var underMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main
    }
}
