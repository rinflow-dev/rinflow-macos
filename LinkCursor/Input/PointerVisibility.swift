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
    private static let log = Logger(subsystem: "com.linkcursor.mac", category: "cursor")

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

/// Hides the cursor where a peer's pointer left this Mac, until this Mac's
/// own mouse or trackpad moves (setting `hide_cursor_on_leave`): the cursor
/// shows only on the device the pointer is on, as with Universal Control,
/// Deskflow and Mouse Without Borders.
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
        PointerVisibility.hide()
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
