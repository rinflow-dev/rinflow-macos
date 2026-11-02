// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
@preconcurrency import CoreGraphics
import IOKit.pwr_mgt
import OSLog

/// Presence: this Mac stays awake while another of the user's devices is in
/// use, and devices lock together (the core's "Presence" section; Windows:
/// `agent/src/presence.rs`).
///
/// - Activity: every 5 s, if this Mac's keyboard or mouse was used in the
///   last 10 s, peers are told (`reportActivity`).
/// - Staying awake (setting `keepAwake`): while a peer reports activity
///   (`peerActive`), a power assertion keeps the display on, and every 30 s
///   `IOPMAssertionDeclareUserActivity` resets the idle timer that the
///   screen saver and the idle lock go by. That is not an input event, so it
///   never counts as activity here. A minute after the last report it lets go.
/// - Locking together (setting `lockSync`): when this Mac locks, peers are
///   told (`lockPeers`); a peer's `lockRequested` locks this Mac.
@MainActor
final class Presence {
    /// Someone uses this Mac: tell the peers.
    var reportActivity: (() -> Void)?
    /// This Mac was locked by its user: lock the peers that want to.
    var lockPeers: (() -> Void)?
    var keepAwake = true {
        didSet { if !keepAwake { letSleep() } }
    }
    var lockSync = false

    private static let log = Logger(subsystem: "com.linkcursor.mac", category: "presence")
    /// Input this recent counts as someone using this Mac.
    private static let activeWithin: TimeInterval = 10
    /// How long a peer's report keeps this Mac awake.
    private static let awakeFor: TimeInterval = 60
    /// How often the idle timer is reset meanwhile.
    private static let nudgeEvery: TimeInterval = 30
    /// A lock this soon after a peer's request was that request: not passed on.
    private static let requestedLock: TimeInterval = 5

    private var timer: Timer?
    private var awakeUntil: Date?
    private var assertion: IOPMAssertionID?
    private var lastNudge: Date?
    private var lockRequestedAt: Date?
    private var lockObserver: NSObjectProtocol?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let lockObserver {
            DistributedNotificationCenter.default().removeObserver(lockObserver)
            self.lockObserver = nil
        }
        letSleep()
    }

    /// `peer_active`: another device is in use.
    func peerActive() {
        guard keepAwake else { return }
        awakeUntil = Date().addingTimeInterval(Self.awakeFor)
        stayAwake()
    }

    /// `lock_requested`: a peer was locked and wants this Mac locked too.
    func lockRequested() {
        guard lockSync else { return }
        lockRequestedAt = Date()
        Self.log.info("locking: a peer was locked")
        Self.lockScreen()
    }

    private func tick() {
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~0)!
        )
        if idle < Self.activeWithin {
            reportActivity?()
        }
        if let awakeUntil, Date() < awakeUntil, keepAwake {
            stayAwake()
        } else {
            letSleep()
        }
    }

    private func stayAwake() {
        if assertion == nil {
            var id = IOPMAssertionID(0)
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "LinkCursor: another device is in use" as CFString,
                &id
            )
            if status == kIOReturnSuccess {
                assertion = id
            }
        }
        // The screen saver and the idle lock go by the idle timer, which the
        // display assertion alone does not reset.
        if lastNudge.map({ Date().timeIntervalSince($0) >= Self.nudgeEvery }) ?? true {
            var id = IOPMAssertionID(0)
            IOPMAssertionDeclareUserActivity(
                "LinkCursor: another device is in use" as CFString,
                kIOPMUserActiveLocal,
                &id
            )
            lastNudge = Date()
        }
    }

    private func letSleep() {
        awakeUntil = nil
        lastNudge = nil
        if let assertion {
            IOPMAssertionRelease(assertion)
            self.assertion = nil
        }
    }

    private func screenLocked() {
        guard lockSync else { return }
        if let lockRequestedAt, Date().timeIntervalSince(lockRequestedAt) < Self.requestedLock {
            return
        }
        Self.log.info("locked here: locking the peers")
        lockPeers?()
    }

    /// Locks this Mac at once, as ⌃⌘Q does (`SACLockScreenImmediate` in the
    /// private login framework, looked up at run time).
    private static func lockScreen() {
        typealias Lock = @convention(c) () -> Int32
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let library = dlopen(path, RTLD_LAZY) else { return }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "SACLockScreenImmediate")
        else {
            log.error("cannot lock the screen: SACLockScreenImmediate not found")
            return
        }
        _ = unsafeBitCast(symbol, to: Lock.self)()
    }
}
