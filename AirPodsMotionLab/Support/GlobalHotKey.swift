import Carbon.HIToolbox

/// One system-wide shortcut through Carbon's `RegisterEventHotKey`. The system
/// delivers only this exact chord, so no Accessibility permission is needed.
@MainActor
final class GlobalHotKey {
    struct Shortcut {
        let keyCode: UInt32
        let modifiers: UInt32
        let title: String

        static let shieldNow = Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | cmdKey), title: "⌃⌘P")
    }

    let shortcut: Shortcut
    private let action: @MainActor () -> Void
    private let id = EventHotKeyID(signature: 0x4150_4D4C, id: 1) // "APML"
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    var isRegistered: Bool { hotKey != nil }

    /// The owner keeps this object alive until `unregister()`; the Carbon
    /// handler holds it unretained.
    init(_ shortcut: Shortcut, action: @escaping @MainActor () -> Void) {
        self.shortcut = shortcut
        self.action = action
    }

    func register() -> OSStatus {
        guard hotKey == nil else { return noErr }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var pressed = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                               nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                guard status == noErr else { return status }
                // Application-target Carbon events are dispatched on the main thread.
                return MainActor.assumeIsolated {
                    Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().handle(pressed)
                }
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return status }
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr { hotKey = ref }
        return status
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func handle(_ pressed: EventHotKeyID) -> OSStatus {
        guard pressed.signature == id.signature, pressed.id == id.id else { return OSStatus(eventNotHandledErr) }
        action()
        return noErr
    }
}
