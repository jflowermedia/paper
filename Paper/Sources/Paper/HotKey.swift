import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Uses Carbon's RegisterEventHotKey, which,
/// unlike an NSEvent monitor, needs no Accessibility permission.
final class HotKey {
    /// ⌃⌥⇧⌘, the "Hyper"/super key.
    static let hyper = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// Returns nil if the shortcut couldn't be registered (e.g. another app owns it).
    init?(keyCode: Int, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installed == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x5041_5052), id: 1)  // 'PAPR'
        guard RegisterEventHotKey(UInt32(keyCode), modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
        else {
            RemoveEventHandler(handlerRef)
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
