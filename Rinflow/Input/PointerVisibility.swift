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

    /// Hides again what is hidden, for when what owns the cursor changed
    /// (`CursorCover`): the window server may have ignored the first hide.
    static func renew() {
        guard hidden else { return }
        show()
        hide()
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

    static func symbol<T>(_ name: String, as type: T.Type) -> T? {
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
/// The pointer left through an edge, often over the Dock, and the Dock keeps
/// the cursor visible whatever this app hides. So a `CursorCover` goes under
/// the cursor first and takes it from the Dock, as the Windows agent's
/// hider window does (oink does the same on macOS).
///
/// `NSCursor.setHiddenUntilMouseMoves` only works while this app is in
/// front, so the hide uses `PointerVisibility` (which works in the
/// background) and a global event monitor brings the cursor back.
@MainActor
final class CursorHider {
    private var monitor: Any?
    private var localMonitor: Any?
    private var cover: CursorCover?

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
        // Global monitors exclude this app's own windows, the cover too.
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
        cover = CursorCover()
    }

    /// Shows the cursor again: local motion, a peer drives this Mac again,
    /// or this Mac's pointer leaves for a peer (that capture hides it).
    func reveal() {
        guard monitor != nil || localMonitor != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        self.monitor = nil
        self.localMonitor = nil
        cover?.remove()
        cover = nil
        PointerVisibility.show()
    }
}

/// A speck of a window under the cursor, above the Dock, whose cursor is
/// transparent. Once the window server routes the pointer to it (a posted
/// move where the cursor already is), the Dock no longer owns the cursor:
/// the hide, renewed then, holds, and the glyph is blank should it not.
/// Almost transparent rather than clear: clear windows let the pointer
/// through. It never takes focus.
@MainActor
private final class CursorCover {
    private let panel: NSPanel

    init() {
        let at = NSEvent.mouseLocation
        let size = 16.0
        panel = CoverPanel(
            contentRect: NSRect(x: at.x - size / 2, y: at.y - size / 2, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = NSColor(white: 0, alpha: 0.01)
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = CoverView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        // A background app's window sets the cursor only with this tag.
        if let connection = Self.connection, let setTags = Self.setTags {
            let tags: [UInt32] = [1 << 5, 0] // kCGSSetsCursorInBackgroundTagBit
            let result = setTags(connection(), UInt32(panel.windowNumber), tags, 64)
            Self.log.info("cover tags result=\(result)")
        }
        panel.orderFrontRegardless()
        take(since: .now())
    }

    func remove() {
        panel.orderOut(nil)
        // Left on our blank glyph, the cursor would stay invisible until an
        // app under it sets its own.
        if NSCursor.current === CoverView.blank {
            NSCursor.arrow.set()
        }
    }

    /// Once the window server puts the cover under the cursor, a posted move
    /// there makes it the cursor's owner; then the hide is renewed.
    private func take(since start: DispatchTime) {
        guard panel.isVisible else { return }
        let hit = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        guard hit == panel.windowNumber else {
            // Never under it (the cursor moved meanwhile): hidden as it is.
            guard DispatchTime.now() < start + .milliseconds(250) else {
                Self.log.info("cover never under the cursor (hit \(hit))")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(2)) { [weak self] in
                self?.take(since: start)
            }
            return
        }
        Self.log.info("cover under the cursor after \((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000) ms")
        PointerVisibility.postMove(to: CGEvent(source: nil)?.location ?? .zero)
        DispatchQueue.main.asyncAfter(deadline: .now() + PointerVisibility.settle) { [weak self] in
            guard let self, self.panel.isVisible else { return }
            CoverView.blank.set()
            PointerVisibility.renew()
        }
    }

    private static let log = Logger(subsystem: "com.rinflow.mac", category: "cursor")
    private typealias Connection = @convention(c) () -> Int32
    private typealias SetTags = @convention(c) (Int32, UInt32, UnsafePointer<UInt32>, Int) -> Int32
    private static let connection = PointerVisibility.symbol("_CGSDefaultConnection", as: Connection.self)
    private static let setTags = PointerVisibility.symbol("CGSSetWindowTags", as: SetTags.self)
}

private final class CoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CoverView: NSView {
    static let blank = NSCursor(
        image: NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in true },
        hotSpot: .zero
    )

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() { addCursorRect(bounds, cursor: Self.blank) }
    override func cursorUpdate(with event: NSEvent) { Self.blank.set() }
    override func mouseEntered(with event: NSEvent) { Self.blank.set() }
    override func mouseMoved(with event: NSEvent) { Self.blank.set() }
}
