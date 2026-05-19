import AppKit
import Carbon.HIToolbox

/// Thin wrapper over Carbon's RegisterEventHotKey for one global shortcut.
/// Carbon's hot-key APIs are not deprecated — they're the documented way to
/// get a global key combo without the Accessibility entitlement.
@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    private var hotKeyRef: EventHotKeyRef?
    private var handler: (() -> Void)?
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    /// Register the ⌃⌥R combo. Returns false if Carbon registration failed
    /// (usually because another app already owns the same combo system-wide).
    @discardableResult
    func registerCtrlOptR(handler: @escaping () -> Void) -> Bool {
        unregister()
        self.handler = handler

        // 'REC ' four-char-code as a signature so we can identify our event.
        let signature: OSType = 0x52454320 // 'R' 'E' 'C' ' '
        var hotKeyID = EventHotKeyID(signature: signature, id: 1)

        let mods = UInt32(controlKey | optionKey)
        let key = UInt32(kVK_ANSI_R)
        let status = RegisterEventHotKey(
            key, mods, hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else { return false }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                let me = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                var receivedID = EventHotKeyID()
                let st = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &receivedID
                )
                guard st == noErr, receivedID.signature == 0x52454320 else {
                    return OSStatus(eventNotHandledErr)
                }
                DispatchQueue.main.async { me.handler?() }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        handler = nil
    }
}
