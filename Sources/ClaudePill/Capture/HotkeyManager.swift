import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon's `RegisterEventHotKey`.
///
/// Why Carbon and not `NSEvent.addGlobalMonitorForEvents`: the system only wakes us when one
/// of *our* combos is pressed (zero CPU otherwise), it needs no Accessibility permission,
/// and it swallows the keystroke so it doesn't leak into the frontmost app.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onTrigger: ((CaptureAction) -> Void)?

    private static let signature: OSType = 0x534E_4150 // 'SNAP'
    private var refs: [CaptureAction: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    /// Replaces all registrations. Returns the actions whose combo is already taken by another app.
    @discardableResult
    func register(_ shortcuts: [CaptureAction: Shortcut]) -> Set<CaptureAction> {
        unregisterAll()
        var failed = Set<CaptureAction>()
        for (action, shortcut) in shortcuts {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.hotkeyID)
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[action] = ref
            } else {
                failed.insert(action)
            }
        }
        return failed
    }

    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    fileprivate func handle(_ id: EventHotKeyID) {
        guard id.signature == Self.signature,
              let action = CaptureAction.allCases.first(where: { $0.hotkeyID == id.id }) else { return }
        onTrigger?(action)
    }
}

/// Carbon delivers hot key events on the main thread's event loop.
private func hotKeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { manager.handle(id) }
    return noErr
}
