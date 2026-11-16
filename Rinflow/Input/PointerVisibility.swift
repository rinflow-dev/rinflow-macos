// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
@preconcurrency import CoreGraphics
import OSLog

/// Hides the Mac pointer while it is on a peer.
///
/// `CGDisplayHideCursor` only works for the frontmost app unless the
/// WindowServer connection has the private property "SetsCursorInBackground"
/// (Deskflow does the same). Looked up at run time: if it ever disappears the
/// pointer merely stays visible. Hide and show are counted by the system, so
/// they are kept strictly paired.
@MainActor
enum PointerVisibility {
    private static var hidden = false
    private static let log = Logger(subsystem: "com.rinflow.mac", category: "cursor")

    /// Same sequence as Deskflow's OSXScreen::hideCursor, including the
    /// re-association that it found fixes the cursor "randomly not hiding".
    static func hide() {
        guard !hidden else { return }
        let allowed = allowInBackground()
        let result = CGDisplayHideCursor(CGMainDisplayID())
        CGAssociateMouseAndMouseCursorPosition(1)
        hidden = result == .success
        log.info("hide result=\(result.rawValue) background=\(allowed)")
    }

    static func show() {
        guard hidden else { return }
        _ = allowInBackground()
        let result = CGDisplayShowCursor(CGMainDisplayID())
        CGAssociateMouseAndMouseCursorPosition(1)
        hidden = false
        log.info("show result=\(result.rawValue)")
    }

    /// Moves the cursor with a real (synthetic) mouse-moved event, so the
    /// window server updates hover state along the way, unlike a warp.
    /// Marked, so neither the event tap nor `CursorHider` takes it for this
    /// Mac's own mouse.
    ///
    /// What lies under the cursor can keep it visible whatever this app
    /// hides: the Dock does, once the pointer has crossed it (a peer below
    /// the main display). So a hide goes after a posted move off the edge,
    /// once the window server has handled it. Measured: warp then hide
    /// leaves it visible; posted move, `settle`, then hide hides it.
    static func postMove(to point: CGPoint) {
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

    /// How long the window server takes to handle a posted move.
    static let settle = DispatchTimeInterval.milliseconds(50)

    static func centre(ofDisplayAt location: CGPoint) -> CGPoint {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(location, 1, &display, &count) == .success, count > 0 else {
            return location
        }
        let bounds = CGDisplayBounds(display)
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Set before every hide and show, as Deskflow does.
    private static func allowInBackground() -> Bool {
        guard let connection, let setProperty else { return false }
        let id = connection()
        return setProperty(id, id, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }

    private typealias Connection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private static let connection = symbol("_CGSDefaultConnection", as: Connection.self)
    private static let setProperty = symbol("CGSSetConnectionProperty", as: SetProperty.self)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        // RTLD_DEFAULT
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
}

/// Hides the cursor once a peer's pointer left this Mac, until this Mac's
/// own mouse or trackpad moves (setting `hide_cursor_on_leave`): the cursor
/// shows only on the device the pointer is on, as with Universal Control,
/// Deskflow and Mouse Without Borders.
///
/// The pointer left through an edge, where the Dock, a hot corner or a
/// full-screen menu bar may be, and the Dock keeps the cursor visible. So
/// the cursor waits hidden in the middle of its display, as while this Mac
/// drives a peer (`InputBridge.park`), and comes back there. A peer that
/// drives this Mac again places it itself.
///
/// `NSCursor.setHiddenUntilMouseMoves` only works while this app is in
/// front, so the hide uses `PointerVisibility` (which works in the
/// background) and a global event monitor brings the cursor back.
@MainActor
final class CursorHider {
    private var monitor: Any?
    private var localMonitor: Any?

    var isHiding: Bool { monitor != nil }

    func hideUntilLocalMotion() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
        ]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != SyntheticInput.marker else { return }
            MainActor.assumeIsolated { self?.reveal() }
        }
        // Global monitors exclude this app's own windows.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != SyntheticInput.marker {
                MainActor.assumeIsolated { self?.reveal() }
            }
            return event
        }
        guard monitor != nil, localMonitor != nil else {
            reveal()
            return
        }
        let location = CGEvent(source: nil)?.location ?? .zero
        PointerVisibility.postMove(to: PointerVisibility.centre(ofDisplayAt: location))
        DispatchQueue.main.asyncAfter(deadline: .now() + PointerVisibility.settle) { [weak self] in
            // Shown meanwhile: a hide now would outlast it.
            guard self?.isHiding == true else { return }
            PointerVisibility.hide()
        }
    }

    /// Shows the cursor again: local motion, a peer drives this Mac again,
    /// or this Mac's pointer leaves for a peer (that capture hides it).
    func reveal() {
        guard monitor != nil || localMonitor != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        self.monitor = nil
        self.localMonitor = nil
        PointerVisibility.show()
    }
}
