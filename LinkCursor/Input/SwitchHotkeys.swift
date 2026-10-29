import Carbon.HIToolbox
import OSLog

/// The switch shortcuts while this Mac has the pointer: ⌃⌥⇧ (or ⌃⌥) with an
/// arrow key, registered as system hot keys. While a peer is driven the event
/// tap takes all keys, so `InputBridge` recognises them itself then.
@MainActor
final class SwitchHotkeys {
    /// An arrow key with the modifiers went down.
    var pressed: ((Side) -> Void)?

    private static let log = Logger(subsystem: "com.linkcursor.mac", category: "hotkeys")
    /// "LCHK"
    private nonisolated static let signature: OSType = 0x4C43_484B
    private static let arrows: [(key: Int, side: Side)] = [
        (kVK_LeftArrow, .left), (kVK_RightArrow, .right), (kVK_DownArrow, .bottom), (kVK_UpArrow, .top),
    ]

    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    /// Registers the shortcuts with `modifiers`, or none with nil. False when
    /// another program holds one of the combinations.
    @discardableResult
    func register(_ modifiers: SwitchModifiers?) -> Bool {
        unregister()
        guard let modifiers else { return true }
        installHandler()
        var carbonModifiers = UInt32(controlKey | optionKey)
        if modifiers == .controlOptionShift {
            carbonModifiers |= UInt32(shiftKey)
        }
        var registered = true
        for (index, arrow) in Self.arrows.enumerated() {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index))
            let status = RegisterEventHotKey(
                UInt32(arrow.key), carbonModifiers, id, GetEventDispatcherTarget(), 0, &reference
            )
            if status == noErr, let reference {
                hotKeys.append(reference)
            } else {
                Self.log.error("cannot register switch shortcut \(index): \(status)")
                registered = false
            }
        }
        return registered
    }

    private func unregister() {
        for reference in hotKeys {
            UnregisterEventHotKey(reference)
        }
        hotKeys.removeAll()
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), switchHotkeyHandler, 1, &type, context, &handler)
    }

    fileprivate func fire(_ id: UInt32) {
        guard Int(id) < Self.arrows.count else { return }
        pressed?(Self.arrows[Int(id)].side)
    }

    fileprivate nonisolated static func id(of event: EventRef?) -> UInt32? {
        guard let event else { return nil }
        var hotKey = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKey
        )
        guard status == noErr, hotKey.signature == signature else { return nil }
        return hotKey.id
    }
}

private func switchHotkeyHandler(
    _ call: EventHandlerCallRef?,
    _ event: EventRef?,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let context, let id = SwitchHotkeys.id(of: event) else {
        return OSStatus(eventNotHandledErr)
    }
    let address = UInt(bitPattern: context)
    // Carbon dispatches on the main thread's run loop.
    MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        Unmanaged<SwitchHotkeys>.fromOpaque(pointer).takeUnretainedValue().fire(id)
    }
    return noErr
}
