// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
@preconcurrency import CoreGraphics
import OSLog

/// Marks the events this app posts, so its own event tap lets them through.
enum SyntheticInput {
    static let marker: Int64 = 0x4C_49_4E_4B_43_55_52
}

/// Plays the input of a peer that drives this Mac.
///
/// Pointer lock: a game (or a pointer-lock web page) dissociates the cursor
/// from the mouse, or warps it back to the middle, and reads only relative
/// motion. Placing the cursor then does nothing for it, and the driving peer
/// must stop crossing at edges that no longer mean anything. So when relative
/// moves keep not landing where they were sent, this Mac reports the lock
/// (`pointerLockChanged`, the core's `lc_core_set_pointer_locked`), and as
/// soon as one lands again, the release. Every move carries its deltas,
/// which is what games read.
///
/// Whether the cursor is hidden would be a second sign, but
/// `CGCursorIsVisible` (and SkyLight's `SLSCursorIsVisible`) report 0 at all
/// times on current macOS, so only the motion counts.
@MainActor
final class InputPlayer {
    /// A game here started (true) or stopped holding the pointer.
    var pointerLockChanged: ((Bool) -> Void)?

    private static let log = Logger(subsystem: "com.linkcursor.mac", category: "play")
    /// Moves in a row that must miss before the pointer counts as held.
    private static let missesToLock = 3

    /// Sub-unit scroll carried to the next played event.
    private var scrollRest = CGVector.zero
    private var lastScrollWasPrecise: Bool?
    private var pointerLocked = false
    /// The last relative move played that should have moved the cursor:
    /// where it was sent, and when.
    private var lastMove: (to: CGPoint, at: DispatchTime)?
    /// CGEventPost is asynchronous. Events in the same burst must build on
    /// the last posted position, not all on the still-old system cursor.
    private var pendingPosition: (to: CGPoint, at: DispatchTime)?
    private var misses = 0
    private var heldKeys: Set<UInt32> = []
    private var heldButtons: Set<UInt32> = []
    private var clicks = ClickTracker()
    private let post: (CGEvent) -> Void
    private let cursorPosition: () -> CGPoint
    private let now: () -> DispatchTime

    init(cursorPosition: @escaping () -> CGPoint = { CGEvent(source: nil)?.location ?? .zero },
         now: @escaping () -> DispatchTime = { .now() },
         post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.post = post
        self.cursorPosition = cursorPosition
        self.now = now
    }

    /// Also used on quit, when the core's final callbacks will be discarded.
    func releaseAll() {
        for code in heldKeys {
            var release = LcInputEvent()
            release.kind = UInt32(LC_INPUT_KEY_UP)
            release.code = code
            play(release)
        }
        for code in heldButtons {
            var release = LcInputEvent()
            release.kind = UInt32(LC_INPUT_MOUSE_BUTTON_UP)
            release.code = code
            play(release)
        }
        setDriven(false)
    }

    /// A peer drives this Mac (true) or none does any more.
    func setDriven(_ driven: Bool) {
        guard !driven else { return }
        lastMove = nil
        pendingPosition = nil
        misses = 0
        scrollRest = .zero
        lastScrollWasPrecise = nil
        clicks = ClickTracker()
        setPointerLocked(false)
    }

    func play(_ input: LcInputEvent) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let event: CGEvent?
        switch input.kind {
        case UInt32(LC_INPUT_MOUSE_MOVE):
            event = move(input, source: source)
        case UInt32(LC_INPUT_MOUSE_BUTTON_DOWN), UInt32(LC_INPUT_MOUSE_BUTTON_UP):
            let down = input.kind == UInt32(LC_INPUT_MOUSE_BUTTON_DOWN)
            guard (1...32).contains(input.code) else { return }
            let position = positionForNextEvent()
            let (button, downType, upType) = Self.mouseButton(for: input.code)
            event = CGEvent(
                mouseEventSource: source,
                mouseType: down ? downType : upType,
                mouseCursorPosition: position,
                mouseButton: button
            )
            event?.setIntegerValueField(
                .mouseEventButtonNumber,
                value: Int64(max(input.code, 1) - 1)
            )
            event?.setIntegerValueField(.mouseEventClickState, value: clicks.click(
                button: input.code, down: down, at: position,
                time: ProcessInfo.processInfo.systemUptime, interval: NSEvent.doubleClickInterval
            ))
        case UInt32(LC_INPUT_SCROLL):
            // Wire: points; a notched wheel sends 10 points per line.
            let precise = input.flags & UInt32(LC_INPUT_FLAG_PRECISE_SCROLL) != 0
            if lastScrollWasPrecise != precise { scrollRest = .zero }
            lastScrollWasPrecise = precise
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
                wheel1: Self.clampedInt32(stepY),
                wheel2: Self.clampedInt32(stepX),
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
        switch input.kind {
        case UInt32(LC_INPUT_KEY_DOWN): heldKeys.insert(input.code)
        case UInt32(LC_INPUT_KEY_UP): heldKeys.remove(input.code)
        case UInt32(LC_INPUT_MOUSE_BUTTON_DOWN): heldButtons.insert(input.code)
        case UInt32(LC_INPUT_MOUSE_BUTTON_UP): heldButtons.remove(input.code)
        default: break
        }
        event.flags = Self.cgFlags(from: input.modifiers)
        event.setIntegerValueField(.eventSourceUserData, value: SyntheticInput.marker)
        post(event)
    }

    private func move(_ input: LcInputEvent, source: CGEventSource) -> CGEvent? {
        let current = positionForNextEvent()
        let destination: CGPoint
        if input.flags & UInt32(LC_INPUT_FLAG_ABSOLUTE_POSITION) != 0 {
            // Where the pointer arrives from the peer, or where the peer put
            // it back after a game let go: a point in this Mac's global
            // display space (points, y down).
            destination = CGPoint(x: input.x, y: input.y)
            lastMove = nil
        } else {
            checkLock(at: cursorPosition())
            destination = CGPoint(x: current.x + input.delta_x, y: current.y + input.delta_y)
            // Only a move that should get somewhere tells: one pushing
            // against a screen edge stays put anyway.
            lastMove = Self.isOnDisplay(destination) && hypot(input.delta_x, input.delta_y) >= 1
                ? (destination, now())
                : nil
        }
        pendingPosition = Self.isOnDisplay(destination) ? (destination, now()) : nil
        let event = CGEvent(
            mouseEventSource: source,
            mouseType: Self.dragEventType(for: input.buttons),
            mouseCursorPosition: destination,
            mouseButton: Self.dragButton(for: input.buttons)
        )
        // What games read while they hold the pointer.
        event?.setDoubleValueField(.mouseEventDeltaX, value: destination.x - current.x)
        event?.setDoubleValueField(.mouseEventDeltaY, value: destination.y - current.y)
        if input.buttons != 0 {
            event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(input.buttons.trailingZeroBitCount))
        }
        return event
    }

    /// Before a relative move: did the last one land? Judged only once the
    /// window server has had time to play it, never within a burst of moves
    /// delivered together.
    private func checkLock(at current: CGPoint) {
        guard let last = lastMove else { return }
        let elapsed = now().uptimeNanoseconds - last.at.uptimeNanoseconds
        guard elapsed >= 8_000_000 else { return }
        lastMove = nil
        guard elapsed <= 250_000_000 else { return }
        if hypot(current.x - last.to.x, current.y - last.to.y) <= 0.5 {
            misses = 0
            setPointerLocked(false)
        } else {
            misses += 1
            if misses >= Self.missesToLock {
                setPointerLocked(true)
            }
        }
    }

    private func setPointerLocked(_ locked: Bool) {
        guard pointerLocked != locked else { return }
        pointerLocked = locked
        Self.log.info("pointer \(locked ? "held by a game" : "released", privacy: .public)")
        pointerLockChanged?(locked)
    }

    private func positionForNextEvent() -> CGPoint {
        if let pendingPosition,
           now().uptimeNanoseconds - pendingPosition.at.uptimeNanoseconds < 8_000_000 {
            return pendingPosition.to
        }
        return cursorPosition()
    }

    private static func isOnDisplay(_ point: CGPoint) -> Bool {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        return CGGetDisplaysWithPoint(point, 1, &display, &count) == .success && count > 0
    }

    static func cgFlags(from modifiers: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers & UInt32(LC_MODIFIER_SHIFT) != 0 { flags.insert(.maskShift) }
        if modifiers & UInt32(LC_MODIFIER_CONTROL) != 0 { flags.insert(.maskControl) }
        if modifiers & UInt32(LC_MODIFIER_OPTION) != 0 { flags.insert(.maskAlternate) }
        if modifiers & UInt32(LC_MODIFIER_COMMAND) != 0 { flags.insert(.maskCommand) }
        if modifiers & UInt32(LC_MODIFIER_CAPS_LOCK) != 0 { flags.insert(.maskAlphaShift) }
        return flags
    }

    private static func dragEventType(for buttons: UInt32) -> CGEventType {
        if buttons & 1 != 0 { return .leftMouseDragged }
        if buttons & 2 != 0 { return .rightMouseDragged }
        if buttons != 0 { return .otherMouseDragged }
        return .mouseMoved
    }

    private static func dragButton(for buttons: UInt32) -> CGMouseButton {
        if buttons & 1 != 0 { return .left }
        if buttons & 2 != 0 { return .right }
        return .center
    }

    private static func mouseButton(for code: UInt32) -> (CGMouseButton, CGEventType, CGEventType) {
        switch code {
        case 2: (.right, .rightMouseDown, .rightMouseUp)
        case 3...32: (.center, .otherMouseDown, .otherMouseUp)
        default: (.left, .leftMouseDown, .leftMouseUp)
        }
    }

    private static func clampedInt32(_ value: Double) -> Int32 {
        Int32(max(Double(Int32.min), min(Double(Int32.max), value.rounded())))
    }
}
