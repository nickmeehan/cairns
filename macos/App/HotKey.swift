import Carbon.HIToolbox

/// ponytail: fixed ⌘⇧N; user-configurable recording when someone asks.
/// Carbon RegisterEventHotKey needs no accessibility permission (a CGEvent tap
/// would) — ~40 hand-rolled lines beat a keyboard-shortcut dependency.
@MainActor
final class HotKey {
    // C-interop pointers; touched from the C callback and deinit, so unisolated.
    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: UInt32 = UInt32(kVK_ANSI_N),
         modifiers: UInt32 = UInt32(cmdKey | shiftKey),
         action: @escaping () -> Void)
    {
        self.action = action
        register(keyCode: keyCode, modifiers: modifiers)
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x4341_524E), id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
