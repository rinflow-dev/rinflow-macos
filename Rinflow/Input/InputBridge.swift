// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
@preconcurrency import CoreGraphics
import OSLog

/// Captures local input while the pointer is on a peer.
///
/// Edge switching works on portals: the stretches of local display edges
/// that touch a placed peer. Pushing through one parks the Mac cursor and
/// starts a `RemotePointer` in the peer's space; pushing that pointer back
/// out through a portal unparks the cursor at the matching local point, and
/// pushing it into another placed peer that touches this one moves on to
/// that peer (chained placements). The switch shortcuts jump between devices
/// without an edge.
@MainActor
final class InputBridge {
    var send: ((LcInputEvent) -> Void)?
    /// The peer that now receives input, or nil when control came back.
    /// Called synchronously, before the first event for the new target.
    var didChangeTarget: ((String?) -> Void)?
    /// The pointer is about to leave for a peer. Called from inside the
    /// event tap: anything slow (reading the pasteboard) must be deferred.
    var willEnter: (() -> Void)?
    /// The pointer stayed on (or came back to) this Mac because secure
    /// input is on, held by the app named, if known.
    var secureInputRefused: ((String?) -> Void)?
    /// How this Mac's mouse feels on a peer (speeds, scroll direction).
    var inputFor: ((String) -> PeerInput)?
    var togglePointerLock: (() -> Void)?
    var crossingLocked = false
    var fullscreenBlocked = false

    private static let log = Logger(subsystem: "com.rinflow.mac", category: "input")

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pressedButtons: UInt32 = 0
    private var pressedModifierUsages: Set<UInt32> = []
    /// Keys the current peer was told are down.
    private var pressedKeys: Set<UInt32> = []
    /// Keys pressed on a peer the pointer moved on from: their releases go
    /// nowhere.
    private var staleKeys: Set<UInt32> = []
    /// This Mac and every placed peer.
    private var world = World()
    /// Peers with a session: the pointer only goes to these.
    private var connected: Set<String> = []
    /// The edges of this Mac that lead to connected peers.
    private var entryPortals: [Portal] = []
    /// Modifier keys held on this Mac when the capture began: their release
    /// goes to this Mac, which saw them go down, not to the peer.
    private var localModifiers: Set<CGKeyCode> = []
    /// Other keys held on this Mac when the capture began (as on Windows):
    /// their repeats go nowhere and their release goes to this Mac. Read
    /// live at the start, never cached across captures, so a release this
    /// tap missed (secure input, the lock screen) cannot block crossing.
    private var localKeys: Set<CGKeyCode> = []
    private var pointer: RemotePointer?
    /// How the mouse feels on the peer it drives now.
    private var peerInput = PeerInput()
    /// Peers where a game holds the pointer (`peer_pointer_lock`).
    private var heldPointers: Set<String> = []
    /// The switch shortcuts' modifiers, or nil when they are off.
    private var switchModifiers: SwitchModifiers?
    /// The arrow key of a switch shortcut, held: its repeats and release go
    /// nowhere.
    private var switchKeyDown: Int64?
    private var lockKeyDown = false
    /// Where the Mac cursor is parked from while `pointer` is active.
    private var frozenLocation: CGPoint = .zero
    /// The jump that a motion shortly after parking the cursor still
    /// carries (SDL's Cocoa backend compensates the same way). Not every
    /// first motion carries it, so it is only taken out of one that does.
    private var pendingWarp: (jump: CGVector, deadline: DispatchTime)?
    private var hasRequestedAccessibilityPrompt = false
    private var crossingGate = CrossingGate()
    private var switchDelay = 0.15
    private var cornerGuard = true
    /// Checks for secure input while a peer is driven.
    private var secureInputTimer: Timer?
    private var lastSecureInputNotice: TimeInterval = -.infinity
    private var stalls = TapStalls()

    func setCrossingOptions(delay: TimeInterval, cornerGuard: Bool) {
        switchDelay = delay
        self.cornerGuard = cornerGuard
        crossingGate.reset()
    }

    var isCapturing: Bool { pointer != nil }

    func refreshInputSettings() {
        if let pointer { peerInput = inputFor?(pointer.peerID) ?? PeerInput() }
    }

    func stop() {
        crossingGate.reset()
        stopCapturing()
        removeEventTap()
        connected.removeAll()
        entryPortals.removeAll()
        heldPointers.removeAll()
    }

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

    /// The arrangement and the peers with a session. With no edge leading
    /// to a connected peer and no switch shortcut, the event tap is removed.
    /// Returns false when a tap is needed but cannot be installed (no
    /// accessibility permission).
    func setArrangement(_ world: World, connected: Set<String>) -> Bool {
        crossingGate.reset()
        // An active RemotePointer caches portals and display bounds. Do not
        // keep using stale geometry after a monitor or placement changes.
        if self.world != world { stopCapturing() }
        self.world = world
        self.connected = connected
        entryPortals = connected.sorted().flatMap { world.portals(to: $0) }
        if let pointer, !connected.contains(pointer.peerID) || world.peer(pointer.peerID) == nil {
            stopCapturing()
        }
        return updateEventTap()
    }

    /// The switch shortcuts (nil: off), recognised while a peer is driven.
    func setSwitchShortcuts(_ modifiers: SwitchModifiers?) {
        switchModifiers = modifiers
    }

    /// A game on `peerID` started or stopped holding its pointer. While it
    /// holds it, motion goes there whole and no edge leads anywhere; when
    /// it lets go, the peer's cursor is put back where this Mac tracks it.
    func setPointerHeld(_ held: Bool, on peerID: String) {
        if held {
            heldPointers.insert(peerID)
        } else if heldPointers.remove(peerID) != nil, let pointer, pointer.peerID == peerID {
            sendPosition(of: pointer)
        }
    }

    /// Gives control back to the Mac without crossing an edge (release key,
    /// HUD button, peer gone). The cursor reappears just inside the edge it
    /// left through, or where it was for a shortcut.
    func stopCapturing() {
        guard let pointer else { return }
        endCapture(at: pointer.returnPoint(near: frozenLocation))
    }

    /// The core took this Mac's control of the peer away (`control_revoked`).
    /// With `pointerStays` a peer now drives this Mac and places the cursor
    /// itself; otherwise the cursor comes back as after the release key.
    func controlRevoked(pointerStays: Bool) {
        guard let pointer else { return }
        endCapture(at: pointerStays ? nil : pointer.returnPoint(near: frozenLocation))
    }

    /// The switch shortcut toward `side` while this Mac has the pointer:
    /// on to the connected device on that side, if any.
    func jumpFromHere(toward side: Side) {
        guard pointer == nil,
              !crossingLocked,
              NSEvent.pressedMouseButtons == 0,
              case let .peer(peerID)? = world.toward(from: .local, side: side, connected: connected),
              connected.contains(peerID),
              let peer = world.peer(peerID),
              let landing = world.landing(from: .local, to: .peer(peerID)),
              secureInputAllowsCapture(),
              updateEventTap(needed: true)
        else {
            return
        }
        let remote = RemotePointer(
            arrivingAt: landing,
            peer: peer,
            portals: world.portals(to: peerID),
            neighbors: world.neighbors(of: peerID),
            entry: nil
        )
        Self.log.info("driving \(peerID, privacy: .public) by shortcut")
        start(remote, from: Self.cursorLocation)
        // The arrow's release is the shortcut's, not the peer's (nor this
        // Mac's: `start` saw it held).
        switchKeyDown = Self.arrowKeyCode(side)
        localKeys.remove(CGKeyCode(Self.arrowKeyCode(side)))
    }

    /// Installs the tap when an edge leads to a connected peer (or one is
    /// `needed` now), removes it when nothing needs it.
    @discardableResult
    private func updateEventTap(needed: Bool = false) -> Bool {
        if entryPortals.isEmpty, !needed, !isCapturing {
            removeEventTap()
            return true
        }
        return installEventTapIfNeeded()
    }

    private func installEventTapIfNeeded() -> Bool {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return true
        }
        guard hasAccessibilityPermission else { return false }

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
        // At the HID level, where Deskflow taps too: a motion swallowed here
        // never reaches the window server, which would otherwise show the
        // hidden cursor again while it is frozen on a peer. A session tap
        // only sees events the window server has already handled.
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: rinflowEventTapCallback,
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
        guard let peer = world.peer(portal.peerID) else { return }
        let remote = RemotePointer(
            crossing: portal,
            at: location,
            peer: peer,
            portals: world.portals(to: peer.id),
            neighbors: world.neighbors(of: peer.id)
        )
        Self.log.info(
            "enter \(portal.peerID, privacy: .public) via \(portal.side.rawValue, privacy: .public) local=(\(location.x), \(location.y))"
        )
        start(remote, from: location)
    }

    /// Starts driving the pointer's peer: its cursor is placed, this Mac's
    /// is parked and hidden, and the tap takes the keyboard and mouse.
    private func start(_ remote: RemotePointer, from location: CGPoint) {
        willEnter?()
        pointer = remote
        frozenLocation = location
        pressedButtons = 0
        pressedKeys.removeAll()
        staleKeys.removeAll()
        switchKeyDown = nil
        lockKeyDown = false
        synchronizeModifierState()
        localModifiers = Set(Self.modifierKeyCodes.filter { CGEventSource.keyState(.combinedSessionState, key: $0) })
        localKeys = Set((0..<128).map { CGKeyCode($0) }.filter {
            !Self.modifierKeyCodes.contains($0) && $0 != 57 && $0 != 63 // Caps Lock, fn
                && CGEventSource.keyState(.hidSystemState, key: $0)
        })
        peerInput = inputFor?(remote.peerID) ?? PeerInput()
        // Whether a game holds its pointer, the peer says afresh.
        heldPointers.remove(remote.peerID)
        // Parked and hidden from the run loop, not from inside the tap
        // callback, as Deskflow and lan-mouse do.
        Task { @MainActor [weak self] in self?.park(from: location) }
        watchSecureInput()
        didChangeTarget?(remote.peerID)
        Self.log.info("arrive at (\(remote.position.x), \(remote.position.y)) on \(remote.peerID, privacy: .public)")
        // Tells the peer where the pointer arrives; it puts its cursor there.
        sendPosition(of: remote)
    }

    /// Moves on to the placed peer `peerID` (into a neighbour, or by
    /// shortcut), arriving at the local point `location`. False when it is
    /// not connected: the pointer then stays.
    private func moveOn(to peerID: String, at location: CGPoint) -> Bool {
        guard let current = pointer, connected.contains(peerID), let peer = world.peer(peerID) else {
            return false
        }
        let remote = RemotePointer(
            arrivingAt: location,
            peer: peer,
            portals: world.portals(to: peerID),
            neighbors: world.neighbors(of: peerID),
            entry: current.entry
        )
        // The old peer gets a reset from the core: it releases what it holds.
        didChangeTarget?(peerID)
        pointer = remote
        peerInput = inputFor?(peerID) ?? PeerInput()
        heldPointers.remove(peerID)
        pressedButtons = 0
        sendPosition(of: remote)
        // Modifiers held go on to the new peer (Shift through a drag
        // across); other keys were for the old one, so their releases go
        // nowhere.
        let held = pressedKeys
        pressedKeys.removeAll()
        for usage in held {
            if (0xE0...0xE7).contains(usage) {
                pressedKeys.insert(usage)
                var down = LcInputEvent()
                down.kind = UInt32(LC_INPUT_KEY_DOWN)
                down.code = usage
                down.modifiers = currentModifiers
                send?(down)
            } else {
                staleKeys.insert(usage)
            }
        }
        Self.log.info("moved on to \(peerID, privacy: .public)")
        return true
    }

    /// A switch shortcut while a peer is driven: on to the device on that
    /// side of it, or back to this Mac.
    private func jump(toward side: Side) {
        guard !crossingLocked, let current = pointer,
              let next = world.toward(from: .peer(current.peerID), side: side, connected: connected),
              let landing = world.landing(from: .peer(current.peerID), to: next)
        else {
            return
        }
        switch next {
        case .local:
            endCapture(at: landing)
        case let .peer(peerID):
            _ = moveOn(to: peerID, at: landing)
        }
    }

    /// An absolute move to where the pointer is on its peer.
    private func sendPosition(of remote: RemotePointer) {
        var arrival = LcInputEvent()
        arrival.kind = UInt32(LC_INPUT_MOUSE_MOVE)
        arrival.flags = UInt32(LC_INPUT_FLAG_ABSOLUTE_POSITION)
        arrival.x = remote.position.x
        arrival.y = remote.position.y
        send?(arrival)
    }

    /// Parks the cursor in the middle of its display, out of the way of the
    /// Dock, hot corners and full-screen menu bars, and hides it.
    ///
    /// The cursor is moved with a posted event, not a warp, and hidden only
    /// once the window server has handled that move. A warp updates no hover
    /// state: when the pointer left through an edge it crossed the Dock on
    /// (a peer below the main display), the Dock keeps owning the cursor and
    /// keeps it visible, whatever this app hides. Measured: warp then hide
    /// leaves it visible; posted move, 50 ms, then hide hides it.
    private func park(from location: CGPoint) {
        guard pointer != nil else { return }
        let centre = Self.centre(ofDisplayAt: location)
        Self.postMove(to: centre)
        pendingWarp = (
            CGVector(dx: centre.x - location.x, dy: centre.y - location.y),
            .now() + .milliseconds(350)
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self, self.pointer != nil else { return }
            PointerVisibility.hide()
            // Dissociating freezes the cursor while it keeps reporting
            // deltas; it must follow the hide, which re-associates it.
            CGAssociateMouseAndMouseCursorPosition(1)
            CGAssociateMouseAndMouseCursorPosition(0)
        }
    }

    /// Takes the parking jump out of the motion that carries it: one whose
    /// delta is mostly that jump (a hand never moves hundreds of points in
    /// one event).
    private func removeWarpJump(from delta: CGVector) -> CGVector {
        guard let (jump, deadline) = pendingWarp else { return delta }
        let length = jump.dx * jump.dx + jump.dy * jump.dy
        guard DispatchTime.now() < deadline, length > 0 else {
            pendingWarp = nil
            return delta
        }
        let share = (delta.dx * jump.dx + delta.dy * jump.dy) / length
        guard share > 0.5 else { return delta }
        pendingWarp = nil
        Self.log.info("removed warp jump (\(jump.dx), \(jump.dy)) from (\(delta.dx), \(delta.dy))")
        return CGVector(dx: delta.dx - jump.dx, dy: delta.dy - jump.dy)
    }

    /// Ends the capture. `location` is where the cursor comes back; nil
    /// leaves it alone, for a peer that now drives this Mac and places it.
    private func endCapture(at location: CGPoint?) {
        guard pointer != nil else { return }
        pointer = nil
        secureInputTimer?.invalidate()
        secureInputTimer = nil
        pendingWarp = nil
        pressedButtons = 0
        pressedKeys.removeAll()
        staleKeys.removeAll()
        switchKeyDown = nil
        lockKeyDown = false
        localModifiers.removeAll()
        localKeys.removeAll()
        pressedModifierUsages.removeAll(keepingCapacity: true)
        CGAssociateMouseAndMouseCursorPosition(1)
        PointerVisibility.show()
        crossingGate.returned(at: Self.now)
        if let location {
            // A posted move, not a warp, as when parking: the window server
            // then hands the cursor to whatever is under it (the Dock, on a
            // bottom edge) and shows it. After a warp it sometimes stayed
            // hidden. Posted events keep their order, so a park still in
            // flight lands first.
            Self.postMove(to: location)
            Self.log.info("return local=(\(location.x), \(location.y))")
        } else {
            Self.log.info("control taken over; the new controller places the cursor")
        }
        didChangeTarget?(nil)
        updateEventTap()
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        defer { stalls.note(eventTimestamp: event.timestamp, handlingFrom: started, log: Self.log) }
        return dispatch(type: type, event: event)
    }

    private func dispatch(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == SyntheticInput.marker {
            return Unmanaged.passUnretained(event)
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Self.log.error("event tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public))")
            // Events may have escaped to the local app while the tap was
            // disabled. Release the peer instead of resuming stale keys.
            stopCapturing()
            crossingGate.reset()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard var remote = pointer else {
            guard let portal = enteredPortal(type: type, event: event) else {
                return Unmanaged.passUnretained(event)
            }
            guard secureInputAllowsCapture() else {
                crossingGate.reset()
                return Unmanaged.passUnretained(event)
            }
            beginCapture(through: portal, at: liveLocation(of: event))
            // The push that crossed the edge is not replayed on the peer.
            return nil
        }

        if type == .flagsChanged {
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if localModifiers.contains(keyCode), Self.modifierIsDown(keyCode: keyCode, flags: event.flags) == false {
                // Held since before the capture: this Mac gets its release.
                localModifiers.remove(keyCode)
                if let usage = HIDKeyMap.hidUsage(for: keyCode) {
                    pressedModifierUsages.remove(usage)
                }
                return Unmanaged.passUnretained(event)
            }
        }

        if type == .keyDown || type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 37 {
                if lockKeyDown {
                    if type == .keyUp { lockKeyDown = false }
                    return nil
                }
                let held = event.flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand])
                if type == .keyDown, held == [.maskControl, .maskAlternate] {
                    lockKeyDown = true
                    togglePointerLock?()
                    return nil
                }
            }
            if type == .keyDown, keyCode == 53,
               event.flags.contains(.maskControl), event.flags.contains(.maskAlternate)
            {
                Self.log.info("release key")
                stopCapturing()
                return nil
            }
            // The switch shortcuts: on to the device on that side. The peer
            // saw the modifiers, never the arrow.
            if keyCode == switchKeyDown {
                if type == .keyUp { switchKeyDown = nil }
                return nil
            }
            if localKeys.contains(CGKeyCode(keyCode)) {
                // Held before the capture: this Mac gets its release, and
                // its repeats go nowhere.
                guard type == .keyUp else { return nil }
                localKeys.remove(CGKeyCode(keyCode))
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown, let side = Self.arrowSide(keyCode), isSwitchShortcut(event.flags) {
                switchKeyDown = keyCode
                jump(toward: side)
                return nil
            }
        }

        var delta = Self.delta(of: event)
        if Self.isMovement(type) {
            delta = removeWarpJump(from: delta)
            // The pointer speed set for this peer.
            delta.dx *= peerInput.pointerSpeed
            delta.dy *= peerInput.pointerSpeed
            if heldPointers.contains(remote.peerID) {
                // A game there holds its pointer: every bit of motion goes to
                // it (it turns the camera), and no edge leads anywhere.
            } else {
                switch remote.step(by: delta, allowCrossing: !crossingLocked) {
                case .stay:
                    pointer = remote
                case let .home(exit):
                    endCapture(at: exit)
                    return nil
                case let .neighbor(peerID, location):
                    if moveOn(to: peerID, at: location) {
                        return nil
                    }
                    // A neighbour not connected: an edge.
                    pointer = remote
                }
            }
        }

        for input in makeInputs(type: type, event: event, delta: delta, at: remote.position) {
            send?(input)
        }
        return nil
    }

    /// Exactly the switch shortcuts' modifiers are held.
    private func isSwitchShortcut(_ flags: CGEventFlags) -> Bool {
        guard let switchModifiers else { return false }
        let held = flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand])
        return switch switchModifiers {
        case .controlOptionShift: held == [.maskControl, .maskAlternate, .maskShift]
        case .controlOption: held == [.maskControl, .maskAlternate]
        }
    }

    private static let modifierKeyCodes: [CGKeyCode] = [54, 55, 56, 58, 59, 60, 61, 62]

    private static func arrowKeyCode(_ side: Side) -> Int64 {
        switch side {
        case .left: 123
        case .right: 124
        case .bottom: 125
        case .top: 126
        }
    }

    private static func arrowSide(_ keyCode: Int64) -> Side? {
        switch keyCode {
        case 123: .left
        case 124: .right
        case 125: .bottom
        case 126: .top
        default: nil
        }
    }

    /// Moves the cursor with a real (synthetic) mouse-moved event, so the
    /// window server updates hover state along the way, unlike a warp.
    /// Marked, so this tap lets it through.
    private static func postMove(to point: CGPoint) {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let event = CGEvent(
                mouseEventSource: source,
                mouseType: .mouseMoved,
                mouseCursorPosition: point,
                mouseButton: .left
            )
        else {
            return
        }
        event.setIntegerValueField(.eventSourceUserData, value: SyntheticInput.marker)
        event.post(tap: .cghidEventTap)
    }

    private static var cursorLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private static func centre(ofDisplayAt location: CGPoint) -> CGPoint {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(location, 1, &display, &count) == .success, count > 0 else {
            return location
        }
        let bounds = CGDisplayBounds(display)
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Whether the modifier key of a flagsChanged event is down afterwards,
    /// read from the event's own device-dependent flag bits (IOLLEvent.h).
    /// The global key state cannot tell: at the HID tap it still describes
    /// the moment before this event, which turned every press into a release.
    private static func modifierIsDown(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool? {
        let bit: UInt64
        switch keyCode {
        case 59: bit = 0x0000_0001 // left control
        case 56: bit = 0x0000_0002 // left shift
        case 60: bit = 0x0000_0004 // right shift
        case 55: bit = 0x0000_0008 // left command
        case 54: bit = 0x0000_0010 // right command
        case 58: bit = 0x0000_0020 // left option
        case 61: bit = 0x0000_0040 // right option
        case 62: bit = 0x0000_2000 // right control
        default: return nil
        }
        return flags.rawValue & bit != 0
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
        // A local drag must get its release on this Mac. Entering mid-drag
        // would strand it here and send an unmatched release there. (Held
        // keys are handed back on release instead; see `localKeys`.)
        guard type == .mouseMoved, !crossingLocked, !fullscreenBlocked else {
            // Keys (a held key's repeats), modifiers and scrolling leave a
            // push alone, as on Windows; a button or a drag ends it.
            if type != .keyDown, type != .keyUp, type != .flagsChanged, type != .scrollWheel {
                crossingGate.reset()
            }
            return nil
        }
        let portal = portal(at: liveLocation(of: event))
        let amount = portal?.outward(Self.delta(of: event)) ?? 0
        switch crossingGate.push(portal, by: amount, at: Self.now, delay: switchDelay) {
        case .cross:
            return portal
        case .began:
            // A push that went far enough crosses when the delay is up even
            // if the pointer stops against the edge: no motion may follow.
            DispatchQueue.main.asyncAfter(deadline: .now() + switchDelay + 0.01) { [weak self] in
                MainActor.assumeIsolated { self?.finishPush() }
            }
            return nil
        case .none:
            return nil
        }
    }

    /// The portal the pointer at `location` is against, outside the corners.
    private func portal(at location: CGPoint) -> Portal? {
        let inCorner = cornerGuard && world.local.contains { display in
            let nearX = min(abs(location.x - display.x), abs(location.x - display.right)) < 24
            let nearY = min(abs(location.y - display.y), abs(location.y - display.bottom)) < 24
            return nearX && nearY
        }
        return inCorner ? nil : entryPortals.first { $0.touches(location) }
    }

    private func finishPush() {
        guard pointer == nil, !crossingLocked, !fullscreenBlocked,
              NSEvent.pressedMouseButtons == 0,
              let portal = crossingGate.portal,
              crossingGate.isDue(at: Self.now, delay: switchDelay)
        else {
            return
        }
        let location = Self.cursorLocation
        guard self.portal(at: location) == portal, secureInputAllowsCapture() else {
            crossingGate.reset()
            return
        }
        beginCapture(through: portal, at: location)
    }

    // MARK: - Secure input

    /// Secure input (a focused password field, Terminal's Secure Keyboard
    /// Entry) hides keystrokes from every event tap: typed for a peer, they
    /// would land in this Mac's front window. So the pointer does not leave
    /// while it is on, which is checked when crossing (rare, and cheap).
    private func secureInputAllowsCapture() -> Bool {
        guard IsSecureEventInputEnabled() else { return true }
        noticeSecureInput()
        return false
    }

    /// Turned on while a peer is driven (a password prompt here): the
    /// pointer comes back, since the keyboard already stays here.
    private func watchSecureInput() {
        secureInputTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pointer != nil, IsSecureEventInputEnabled() else { return }
                Self.log.info("secure input turned on while driving a peer: coming back")
                self.stopCapturing()
                self.noticeSecureInput()
            }
        }
        // Common modes: it also fires while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        secureInputTimer = timer
    }

    /// Once in a while, not on every push against the edge.
    private func noticeSecureInput() {
        let now = Self.now
        guard now - lastSecureInputNotice >= 3 else { return }
        lastSecureInputNotice = now
        let owner = Self.secureInputOwner
        Self.log.info("secure input is on (\(owner ?? "unknown app", privacy: .public)): the pointer stays")
        secureInputRefused?(owner)
    }

    /// The app holding secure input, from the session's (undocumented, but
    /// long-standing) `kCGSSessionSecureInputPID`; nil when unknown.
    private static var secureInputOwner: String? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, pid > 0
        else {
            return nil
        }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    private static var now: TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// `position` is where the pointer is on the peer (peer space); it goes
    /// into x/y for the peer's diagnostics but only counts with
    /// `LC_INPUT_FLAG_ABSOLUTE_POSITION`.
    private func makeInputs(
        type: CGEventType,
        event: CGEvent,
        delta: CGVector,
        at position: CGPoint
    ) -> [LcInputEvent] {
        var input = LcInputEvent()
        input.timestamp_micros = event.timestamp / 1_000
        input.x = position.x
        input.y = position.y

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            input.kind = UInt32(LC_INPUT_MOUSE_MOVE)
            input.delta_x = delta.dx
            input.delta_y = delta.dy
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            input.kind = UInt32(LC_INPUT_MOUSE_BUTTON_DOWN)
            input.code = UInt32(event.getIntegerValueField(.mouseEventButtonNumber) + 1)
            updatePressedButton(code: input.code, isDown: true)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            input.code = UInt32(event.getIntegerValueField(.mouseEventButtonNumber) + 1)
            // Pressed on a peer the pointer moved on from, which was reset:
            // this peer never saw it go down.
            guard (1...32).contains(input.code), pressedButtons & (1 << (input.code - 1)) != 0 else {
                return []
            }
            input.kind = UInt32(LC_INPUT_MOUSE_BUTTON_UP)
            updatePressedButton(code: input.code, isDown: false)
        case .scrollWheel:
            // The scrolling speed and direction set for this peer.
            let factor = peerInput.scrollSpeed * (peerInput.invertScroll ? -1 : 1)
            input.kind = UInt32(LC_INPUT_SCROLL)
            input.scroll_x = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)) * factor
            input.scroll_y = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) * factor
            if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
                input.flags |= UInt32(LC_INPUT_FLAG_PRECISE_SCROLL)
            }
        case .keyDown, .keyUp:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            guard let usage = HIDKeyMap.hidUsage(for: keyCode) else { return [] }
            if type == .keyUp {
                if staleKeys.remove(usage) != nil { return [] }
                pressedKeys.remove(usage)
            } else {
                // Held on a peer the pointer moved on from: its repeats go
                // nowhere, like its release.
                if staleKeys.contains(usage) { return [] }
                pressedKeys.insert(usage)
            }
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
            guard let isDown = Self.modifierIsDown(keyCode: keyCode, flags: event.flags) else {
                return []
            }
            if isDown {
                pressedModifierUsages.insert(usage)
                pressedKeys.insert(usage)
            } else {
                pressedModifierUsages.remove(usage)
                pressedKeys.remove(usage)
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
        for keyCode in Self.modifierKeyCodes {
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

    /// The modifiers of the keys held, for an event without its own flags.
    private var currentModifiers: UInt32 {
        canonicalModifiers(from: CGEventSource.flagsState(.combinedSessionState))
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
}

/// Measures the event tap, which runs on the main thread with the UI: how
/// long events waited before it saw them, and how long one took to handle.
/// Over budget, a summary is logged at most once a second (`make log`).
private struct TapStalls {
    private static let waitBudget: UInt64 = 30_000_000
    private static let handlingBudget: UInt64 = 4_000_000
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private var count = 0
    private var longestWait: UInt64 = 0
    private var longestHandling: UInt64 = 0
    private var lastLog: UInt64 = 0

    mutating func note(eventTimestamp: CGEventTimestamp, handlingFrom started: UInt64, log: Logger) {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let handling = now &- started
        let wait = Self.waited(since: eventTimestamp, now: started)
        guard wait > Self.waitBudget || handling > Self.handlingBudget else { return }
        count += 1
        longestWait = max(longestWait, wait)
        longestHandling = max(longestHandling, handling)
        guard now &- lastLog >= 1_000_000_000 else { return }
        let (events, waitMs, handlingMs) = (count, longestWait / 1_000_000, longestHandling / 1_000_000)
        log.notice("tap stalls: \(events) events, waited up to \(waitMs) ms, handled in up to \(handlingMs) ms")
        lastLog = now
        count = 0
        longestWait = 0
        longestHandling = 0
    }

    /// An event's timestamp is nanoseconds of uptime on some Macs and mach
    /// ticks on others (Apple silicon): whichever gives a plausible wait.
    private static func waited(since timestamp: UInt64, now: UInt64) -> UInt64 {
        let plausible: ClosedRange<UInt64> = 0...10_000_000_000
        if now >= timestamp, plausible.contains(now - timestamp) { return now - timestamp }
        let ticks = mach_absolute_time()
        guard ticks >= timestamp else { return 0 }
        let elapsed = (ticks - timestamp) * UInt64(timebase.numer) / UInt64(timebase.denom)
        return plausible.contains(elapsed) ? elapsed : 0
    }
}

private func rinflowEventTapCallback(
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
