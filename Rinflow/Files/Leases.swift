// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The core's on-demand files (`lc_core_open_remote_files`), for worker
/// threads: opening and every read block for up to 15 s, so never on the
/// main thread. RustCore owns the core and invalidates this before it
/// destroys it; an open under way is cut short and waited for, so none
/// outlives the core.
final class LeaseSource: @unchecked Sendable {
    private let condition = NSCondition()
    private var handle: OpaquePointer?
    private var opening = 0

    init(_ handle: OpaquePointer) {
        self.handle = handle
    }

    /// Pins the peer's copy `transfer` for one paste; nil if it is gone.
    func open(peer: String, transfer: UInt32) -> Lease? {
        condition.lock()
        guard let handle else {
            condition.unlock()
            return nil
        }
        opening += 1
        condition.unlock()
        let lease = peer.withCString { lc_core_open_remote_files(handle, $0, transfer) }
        condition.lock()
        opening -= 1
        condition.broadcast()
        condition.unlock()
        return lease.map(Lease.init)
    }

    /// Ends every paste under way and waits for opens still running. Call on
    /// the thread that destroys the core, before it does.
    func invalidate() {
        condition.lock()
        let handle = self.handle
        self.handle = nil
        condition.unlock()
        guard let handle else { return }
        // Opens under way fail at once instead of after their 15 s.
        _ = lc_core_revoke_file_streams(handle)
        condition.lock()
        while opening > 0 { condition.wait() }
        condition.unlock()
    }
}

/// One paste of a peer's copy. Reads may run on several threads at once;
/// `close` waits for none, so call it after the last read returned.
final class Lease: @unchecked Sendable {
    private let lock = NSLock()
    private var pointer: OpaquePointer?

    fileprivate init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        if let pointer { lc_file_lease_close(pointer, nil) }
    }

    /// Up to `buffer.count` bytes of `entry` from `offset`: how many, 0 at
    /// its end; nil if the transfer broke off.
    func read(entry: Int, offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) -> Int? {
        guard let pointer = lock.withLock({ self.pointer }), let base = buffer.baseAddress else { return nil }
        let count = lc_file_lease_read(pointer, UInt32(entry), offset, base.assumingMemoryBound(to: UInt8.self), buffer.count)
        return count < 0 ? nil : Int(count)
    }

    /// "delivered" or "cancelled", for the core's `files_stream_ended`.
    func close(_ reason: String) {
        guard let pointer = lock.withLock({ () -> OpaquePointer? in
            defer { self.pointer = nil }
            return self.pointer
        }) else { return }
        reason.withCString { lc_file_lease_close(pointer, $0) }
    }
}
