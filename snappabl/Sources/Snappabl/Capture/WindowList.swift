import AppKit

struct WindowInfo: Equatable {
    let id: CGWindowID
    /// Global Core Graphics coordinates (top-left origin of the primary display), in points.
    let frame: CGRect
    let owner: String

    static func == (a: WindowInfo, b: WindowInfo) -> Bool { a.id == b.id }
}

enum WindowList {
    /// Normal app windows currently on screen, front to back. One cheap window-server call,
    /// made once when the overlay opens.
    static func onScreen() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int) != pid,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 40, frame.height >= 40 else { return nil }
            return WindowInfo(id: CGWindowID(number), frame: frame,
                              owner: info[kCGWindowOwnerName as String] as? String ?? "Window")
        }
    }

    /// Mouse position in the same global CG space as `WindowInfo.frame`.
    @MainActor
    static func mouseLocation() -> CGPoint {
        let m = NSEvent.mouseLocation
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: m.x, y: primaryTop - m.y)
    }
}
