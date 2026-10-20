import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import CoreGraphics
import OSLog

/// Captures local input while the pointer is on a peer, and plays input a
/// peer sends to this Mac.
///
/// Edge switching works on portals: the stretches of local display edges
/// that touch a placed peer. Pushing through one freezes the Mac cursor and
/// starts a `RemotePointer` in the peer's space; pushing that pointer back
/// out through a portal unfreezes the cursor at the matching local point.
@MainActor
final class InputBridge {
    var send: ((LcInputEvent) -> Void)?
    /// The peer that now receives input, or nil when control came back.
    /// Called synchronously, before the first event for the new target.
    var didChangeTarget: ((String?) -> Void)?

    private static let syntheticMarker: Int64 = 0x4C_49_4E_4B_43_55_52
    private static let log = Logger(subsystem: "com.linkcursor.mac", category: "input")

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pressedButtons: UInt32 = 0
    private var pressedModifierUsages: Set<UInt32> = []
    private var portals: [Portal] = []
    private var peerDisplays: [String: [Display]] = [:]
    private var pointer: RemotePointer?
    /// Where the Mac cursor is frozen while `pointer` is active.
    private var frozenLocation: CGPoint = .zero
    /// Sub-unit scroll carried to the next played event.
    private var scrollRest = CGVector.zero
    private var hasRequestedAccessibilityPrompt = false

    var isCapturing: Bool { pointer != nil }

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        guard !hasAccessibilityPermission else { return }
        guard !hasRequestedAccessibilityPrompt else {
            if let settingsURL = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ) {
                NSWorkspace.shared.open(settingsURL)
            }
            return
        }

        hasRequestedAccessibilityPrompt = true
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// The edges that lead to connected, placed peers. With none, the event
    /// tap is removed. Returns false when a tap is needed but cannot be
    /// installed (no accessibility permission).
    func setPortals(_ portals: [Portal], peerDisplays: [String: [Display]]) -> Bool {
        self.portals = portals
        self.peerDisplays = peerDisplays
        if let pointer, !portals.contains(where: { $0.peerID == pointer.peerID }) {
            stopCapturing()
        }
        if portals.isEmpty {
            if !isCapturing {
                removeEventTap()
            }
            return true
        }
        return installEventTapIfNeeded(promptForPermission: false)
    }

    /// Gives control back to the Mac without crossing an edge (release key,
    /// HUD button, peer gone). The cursor reappears just inside the edge it
    /// left through.
    func stopCapturing() {
        guard let pointer else { return }
        endCapture(at: pointer.entry.localInside(near: frozenLocation))
    }

    private func installEventTapIfNeeded(promptForPermission: Bool) -> Bool {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return true
        }
        guard hasAccessibilityPermission else {
            if promptForPermission {
                requestAccessibilityPermission()
            }
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

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    private func removeEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func beginCapture(through portal: Portal, at location: CGPoint) {
        let peerPortals = portals.filter { $0.peerID == portal.peerID }
        let remote = RemotePointer(
            entering: portal,
            at: location,
            portals: peerPortals,
            displays: peerDisplays[portal.peerID] ?? []
        )
        pointer = remote
        frozenLocation = location
        pressedButtons = 0
        synchronizeModifierState()
        // The cursor stays put and keeps reporting deltas.
        CGAssociateMouseAndMouseCursorPosition(0)
        PointerVisibility.hide()
        didChangeTarget?(portal.peerID)

        Self.log.info(
            "enter \(portal.peerID, privacy: .public) via \(portal.side.rawValue, privacy: .public) local=(\(location.x), \(location.y)) remote=(\(remote.position.x), \(remote.position.y))"
        )

        // Tells the peer where the pointer arrives. A peer that does not
        // honour absolute positions treats it as a zero move.
        var arrival = LcInputEvent()
        arrival.kind = UInt32(LC_INPUT_MOUSE_MOVE)
        arrival.flags = UInt32(LC_INPUT_FLAG_ABSOLUTE_POSITION)
        arrival.x = remote.position.x
        arrival.y = remote.position.y
        send?(arrival)
    }

    private func endCapture(at location: CGPoint) {
        guard pointer != nil else { return }
        pointer = nil
        pressedButtons = 0
        pressedModifierUsages.removeAll(keepingCapacity: true)
        CGWarpMouseCursorPosition(location)
        // Re-associating right after the warp also cancels the short
        // suppression of local mouse events that a warp starts.
        CGAssociateMouseAndMouseCursorPosition(1)
        PointerVisibility.show()
        didChangeTarget?(nil)
        Self.log.info("return local=(\(location.x), \(location.y))")
        if portals.isEmpty {
            removeEventTap()
        }
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
            // Wire: points; a notched wheel sends 10 points per line.
            let precise = input.flags & UInt32(LC_INPUT_FLAG_PRECISE_SCROLL) != 0
            let pointsPerUnit = precise ? 1.0 : 10.0
            let wantedX = scrollRest.dx + input.scroll_x / pointsPerUnit
            let wantedY = scrollRest.dy + input.scroll_y / pointsPerUnit
            let stepX = wantedX.rounded(.towardZero)
            let stepY = wantedY.rounded(.towardZero)
            scrollRest = CGVector(dx: wantedX - stepX, dy: wantedY - stepY)
            guard stepX != 0 || stepY != 0 else { return }
            event = CGEvent(
                scrollWheelEvent2Source: source,
                units: precise ? .pixel : .line,
                wheelCount: 2,
                wheel1: clampedInt32(stepY),
                wheel2: clampedInt32(stepX),
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

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard var remote = pointer else {
            guard let portal = enteredPortal(type: type, event: event) else {
                return Unmanaged.passUnretained(event)
            }
            beginCapture(through: portal, at: liveLocation(of: event))
            // The push that crossed the edge is not replayed on the peer.
            return nil
        }

        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventKeycode) == 53,
           event.flags.contains(.maskControl),
           event.flags.contains(.maskAlternate)
        {
            Self.log.info("release key")
            stopCapturing()
            return nil
        }

        if Self.isMovement(type) {
            if let exit = remote.move(by: Self.delta(of: event)) {
                endCapture(at: exit)
                return nil
            }
            pointer = remote
        }

        for input in makeInputs(type: type, event: event, at: remote.position) {
            send?(input)
        }
        return nil
    }

    private static func isMovement(_ type: CGEventType) -> Bool {
        type == .mouseMoved || type == .leftMouseDragged ||
            type == .rightMouseDragged || type == .otherMouseDragged
    }

    /// Pointer motion in points, with the fractions a trackpad produces.
    private static func delta(of event: CGEvent) -> CGVector {
        CGVector(
            dx: event.getDoubleValueField(.mouseEventDeltaX),
            dy: event.getDoubleValueField(.mouseEventDeltaY)
        )
    }

    /// Mouse events can sit in the queue briefly. Deskflow uses the live
    /// cursor position for the local screen for the same reason.
    private func liveLocation(of event: CGEvent) -> CGPoint {
        CGEvent(source: nil)?.location ?? event.location
    }

    private func enteredPortal(type: CGEventType, event: CGEvent) -> Portal? {
        guard Self.isMovement(type) else { return nil }
        let location = liveLocation(of: event)
        let delta = Self.delta(of: event)
        return portals.first { $0.isEntered(at: location, delta: delta) }
    }

    /// `position` is where the pointer is on the peer (peer space); it goes
    /// into x/y for the peer's diagnostics but only counts with
    /// `LC_INPUT_FLAG_ABSOLUTE_POSITION`.
    private func makeInputs(type: CGEventType, event: CGEvent, at position: CGPoint) -> [LcInputEvent] {
        var input = LcInputEvent()
        input.timestamp_micros = event.timestamp / 1_000
        input.x = position.x
        input.y = position.y

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let delta = Self.delta(of: event)
            input.kind = UInt32(LC_INPUT_MOUSE_MOVE)
            input.delta_x = delta.dx
            input.delta_y = delta.dy
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

/// Hides the Mac pointer while it is on a peer.
///
/// `CGDisplayHideCursor` only works for the frontmost app unless the
/// WindowServer connection has the private property "SetsCursorInBackground"
/// (Deskflow does the same). Looked up at run time: if it ever disappears the
/// pointer merely stays visible. Hide and show are counted by the system, so
/// they are kept strictly paired.
@MainActor
private enum PointerVisibility {
    private static var hidden = false
    private static var backgroundAllowed = false

    static func hide() {
        guard !hidden else { return }
        allowInBackground()
        hidden = CGDisplayHideCursor(CGMainDisplayID()) == .success
    }

    static func show() {
        guard hidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        hidden = false
    }

    private static func allowInBackground() {
        guard !backgroundAllowed else { return }
        typealias Connection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let everywhere = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard
            let connection = dlsym(everywhere, "_CGSDefaultConnection"),
            let setProperty = dlsym(everywhere, "CGSSetConnectionProperty")
        else {
            return
        }
        let id = unsafeBitCast(connection, to: Connection.self)()
        backgroundAllowed = unsafeBitCast(setProperty, to: SetProperty.self)(
            id, id, "SetsCursorInBackground" as CFString, kCFBooleanTrue
        ) == 0
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
