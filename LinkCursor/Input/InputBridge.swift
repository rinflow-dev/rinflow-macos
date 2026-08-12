import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import CoreGraphics

@MainActor
final class InputBridge {
    var send: ((LcInputEvent) -> Void)?
    var didRequestRelease: (() -> Void)?

    private static let syntheticMarker: Int64 = 0x4C_49_4E_4B_43_55_52

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pressedButtons: UInt32 = 0
    private var pressedModifierUsages: Set<UInt32> = []
    private(set) var isCapturing = false

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func startCapturing() -> Bool {
        guard !isCapturing else { return true }
        guard hasAccessibilityPermission else {
            requestAccessibilityPermission()
            return false
        }

        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel,
            .keyDown, .keyUp, .flagsChanged,
        ]
        let mask = types.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << type.rawValue)
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: linkCursorEventTapCallback,
            userInfo: context
        ) else {
            return false
        }

        pressedButtons = 0
        synchronizeModifierState()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        isCapturing = true
        return true
    }

    func stopCapturing() {
        isCapturing = false
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        pressedButtons = 0
        pressedModifierUsages.removeAll(keepingCapacity: true)
    }

    func inject(_ input: LcInputEvent) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let flags = cgFlags(from: input.modifiers)

        let event: CGEvent?
        switch input.kind {
        case UInt32(LC_INPUT_MOUSE_MOVE):
            let current = CGEvent(source: nil)?.location ?? .zero
            let destination = CGPoint(
                x: current.x + input.delta_x,
                y: current.y + input.delta_y
            )
            event = CGEvent(
                mouseEventSource: source,
                mouseType: dragEventType(for: input.buttons),
                mouseCursorPosition: destination,
                mouseButton: dragButton(for: input.buttons)
            )
        case UInt32(LC_INPUT_MOUSE_BUTTON_DOWN), UInt32(LC_INPUT_MOUSE_BUTTON_UP):
            let down = input.kind == UInt32(LC_INPUT_MOUSE_BUTTON_DOWN)
            let (button, downType, upType) = mouseButton(for: input.code)
            event = CGEvent(
                mouseEventSource: source,
                mouseType: down ? downType : upType,
                mouseCursorPosition: CGEvent(source: nil)?.location ?? .zero,
                mouseButton: button
            )
            event?.setIntegerValueField(
                .mouseEventButtonNumber,
                value: Int64(input.code.saturatingSubtracting(1))
            )
        case UInt32(LC_INPUT_SCROLL):
            let precise = input.flags & UInt32(LC_INPUT_FLAG_PRECISE_SCROLL) != 0
            event = CGEvent(
                scrollWheelEvent2Source: source,
                units: precise ? .pixel : .line,
                wheelCount: 2,
                wheel1: clampedInt32(input.scroll_y),
                wheel2: clampedInt32(input.scroll_x),
                wheel3: 0
            )
        case UInt32(LC_INPUT_KEY_DOWN), UInt32(LC_INPUT_KEY_UP):
            guard let keyCode = HIDKeyMap.macKeyCode(for: input.code) else { return }
            event = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: input.kind == UInt32(LC_INPUT_KEY_DOWN)
            )
            if input.flags & UInt32(LC_INPUT_FLAG_KEY_REPEAT) != 0 {
                event?.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
            }
        default:
            event = nil
        }

        guard let event else { return }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        event.post(tap: .cghidEventTap)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        guard isCapturing else { return Unmanaged.passUnretained(event) }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventKeycode) == 53,
           event.flags.contains(.maskControl),
           event.flags.contains(.maskAlternate)
        {
            // Removing the event tap from inside its callback is fragile, so
            // perform the release on the next main-run-loop turn.
            DispatchQueue.main.async { [weak self] in self?.didRequestRelease?() }
            return nil
        }

        for input in makeInputs(type: type, event: event) {
            send?(input)
        }
        return nil
    }

    private func makeInputs(type: CGEventType, event: CGEvent) -> [LcInputEvent] {
        var input = LcInputEvent()
        input.timestamp_micros = event.timestamp / 1_000
        input.x = event.location.x
        input.y = event.location.y

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            input.kind = UInt32(LC_INPUT_MOUSE_MOVE)
            input.delta_x = Double(event.getIntegerValueField(.mouseEventDeltaX))
            input.delta_y = Double(event.getIntegerValueField(.mouseEventDeltaY))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            input.kind = UInt32(LC_INPUT_MOUSE_BUTTON_DOWN)
            input.code = UInt32(event.getIntegerValueField(.mouseEventButtonNumber) + 1)
            updatePressedButton(code: input.code, isDown: true)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            input.kind = UInt32(LC_INPUT_MOUSE_BUTTON_UP)
            input.code = UInt32(event.getIntegerValueField(.mouseEventButtonNumber) + 1)
            updatePressedButton(code: input.code, isDown: false)
        case .scrollWheel:
            input.kind = UInt32(LC_INPUT_SCROLL)
            input.scroll_x = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            input.scroll_y = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
                input.flags |= UInt32(LC_INPUT_FLAG_PRECISE_SCROLL)
            }
        case .keyDown, .keyUp:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            guard let usage = HIDKeyMap.hidUsage(for: keyCode) else { return [] }
            input.kind = type == .keyDown ? UInt32(LC_INPUT_KEY_DOWN) : UInt32(LC_INPUT_KEY_UP)
            input.code = usage
            input.key_symbol = type == .keyDown ? unicodeScalar(for: event) : 0
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                input.flags |= UInt32(LC_INPUT_FLAG_KEY_REPEAT)
                input.repeat_count = 1
            }
        case .flagsChanged:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            guard let usage = HIDKeyMap.hidUsage(for: keyCode) else { return [] }
            if keyCode == 57 {
                // Caps Lock is a toggle, not a key that remains physically
                // pressed until it is toggled off. Send a complete click.
                input.kind = UInt32(LC_INPUT_KEY_DOWN)
                input.code = usage
                input.modifiers = canonicalModifiers(from: event.flags)
                var release = input
                release.kind = UInt32(LC_INPUT_KEY_UP)
                return [input, release]
            }
            let isDown = CGEventSource.keyState(.combinedSessionState, key: keyCode)
            if isDown {
                pressedModifierUsages.insert(usage)
            } else {
                pressedModifierUsages.remove(usage)
            }
            input.kind = isDown ? UInt32(LC_INPUT_KEY_DOWN) : UInt32(LC_INPUT_KEY_UP)
            input.code = usage
        default:
            return []
        }

        input.buttons = pressedButtons
        input.modifiers = canonicalModifiers(from: event.flags)
        return [input]
    }

    private func synchronizeModifierState() {
        pressedModifierUsages.removeAll(keepingCapacity: true)
        for keyCode: CGKeyCode in [54, 55, 56, 58, 59, 60, 61, 62] {
            guard CGEventSource.keyState(.combinedSessionState, key: keyCode),
                  let usage = HIDKeyMap.hidUsage(for: keyCode)
            else {
                continue
            }
            pressedModifierUsages.insert(usage)
        }
    }

    private func updatePressedButton(code: UInt32, isDown: Bool) {
        guard (1...32).contains(code) else { return }
        let mask = UInt32(1) << (code - 1)
        if isDown {
            pressedButtons |= mask
        } else {
            pressedButtons &= ~mask
        }
    }

    private func unicodeScalar(for event: CGEvent) -> UInt32 {
        var characters = [UniChar](repeating: 0, count: 8)
        var length = 0
        event.keyboardGetUnicodeString(
            maxStringLength: characters.count,
            actualStringLength: &length,
            unicodeString: &characters
        )
        guard length > 0 else { return 0 }
        return String(decoding: characters.prefix(length), as: UTF16.self)
            .unicodeScalars.first?.value ?? 0
    }

    private func canonicalModifiers(from flags: CGEventFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.maskShift) { value |= UInt32(LC_MODIFIER_SHIFT) }
        if flags.contains(.maskControl) { value |= UInt32(LC_MODIFIER_CONTROL) }
        if flags.contains(.maskAlternate) { value |= UInt32(LC_MODIFIER_OPTION) }
        if flags.contains(.maskCommand) { value |= UInt32(LC_MODIFIER_COMMAND) }
        if flags.contains(.maskAlphaShift) { value |= UInt32(LC_MODIFIER_CAPS_LOCK) }

        for usage in pressedModifierUsages {
            switch usage {
            case 0xE1: value |= UInt32(LC_MODIFIER_LEFT_SHIFT)
            case 0xE5: value |= UInt32(LC_MODIFIER_RIGHT_SHIFT)
            case 0xE0: value |= UInt32(LC_MODIFIER_LEFT_CONTROL)
            case 0xE4: value |= UInt32(LC_MODIFIER_RIGHT_CONTROL)
            case 0xE2: value |= UInt32(LC_MODIFIER_LEFT_OPTION)
            case 0xE6: value |= UInt32(LC_MODIFIER_RIGHT_OPTION)
            case 0xE3: value |= UInt32(LC_MODIFIER_LEFT_COMMAND)
            case 0xE7: value |= UInt32(LC_MODIFIER_RIGHT_COMMAND)
            default: break
            }
        }
        return value
    }

    private func cgFlags(from modifiers: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers & UInt32(LC_MODIFIER_SHIFT) != 0 { flags.insert(.maskShift) }
        if modifiers & UInt32(LC_MODIFIER_CONTROL) != 0 { flags.insert(.maskControl) }
        if modifiers & UInt32(LC_MODIFIER_OPTION) != 0 { flags.insert(.maskAlternate) }
        if modifiers & UInt32(LC_MODIFIER_COMMAND) != 0 { flags.insert(.maskCommand) }
        if modifiers & UInt32(LC_MODIFIER_CAPS_LOCK) != 0 { flags.insert(.maskAlphaShift) }
        return flags
    }

    private func dragEventType(for buttons: UInt32) -> CGEventType {
        if buttons & 1 != 0 { return .leftMouseDragged }
        if buttons & 2 != 0 { return .rightMouseDragged }
        if buttons != 0 { return .otherMouseDragged }
        return .mouseMoved
    }

    private func dragButton(for buttons: UInt32) -> CGMouseButton {
        if buttons & 1 != 0 { return .left }
        if buttons & 2 != 0 { return .right }
        return .center
    }

    private func mouseButton(
        for code: UInt32
    ) -> (CGMouseButton, CGEventType, CGEventType) {
        switch code {
        case 2: (.right, .rightMouseDown, .rightMouseUp)
        case 3...32: (.center, .otherMouseDown, .otherMouseUp)
        default: (.left, .leftMouseDown, .leftMouseUp)
        }
    }

    private func clampedInt32(_ value: Double) -> Int32 {
        Int32(max(Double(Int32.min), min(Double(Int32.max), value.rounded())))
    }
}

private func linkCursorEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ context: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let context else { return Unmanaged.passUnretained(event) }
    let contextAddress = UInt(bitPattern: context)
    return MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: contextAddress) else {
            return Unmanaged.passUnretained(event)
        }
        let bridge = Unmanaged<InputBridge>.fromOpaque(pointer).takeUnretainedValue()
        return bridge.handle(type: type, event: event)
    }
}

private extension UInt32 {
    func saturatingSubtracting(_ value: UInt32) -> UInt32 {
        self >= value ? self - value : 0
    }
}
