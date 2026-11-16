// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Darwin
import Foundation
import OSLog
import Security

/// Serves the File Provider extension the bytes of a peer's files, on the
/// Unix socket in the App Group container (Shared/FetchWire.swift). Only
/// Rinflow's own extension, by its signature, gets an answer.
///
/// The files of one clip share one lease: the core counts it as one paste,
/// with one progress, as Explorer's on Windows. It opens with the first
/// file and closes 10 s after the last one, or when the clip is retired.
final class FileServer: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var source: LeaseSource?
    private var clips: [String: Served] = [:]
    private static let log = Logger(subsystem: "com.rinflow.mac", category: "files")
    private static let extensionRequirement = #"identifier "com.rinflow.mac.files" and anchor apple generic and certificate leaf[subject.OU] = "998ZTJV2HQ""#

    init(socket: URL) {
        path = socket.path
    }

    // MARK: Clips

    /// The core to read from; nil while it is stopped.
    func setSource(_ source: LeaseSource?) {
        lock.withLock { self.source = source }
    }

    func serve(_ clip: Clip) {
        lock.withLock { clips[clip.id] = Served(clip) }
    }

    /// Stops serving a clip once no file of it is being read, then calls
    /// `done` (on some thread): a paste under way finishes first.
    func retire(_ id: String, done: @escaping @Sendable () -> Void) {
        let served = lock.withLock { clips[id] }
        guard let served else { return done() }
        served.retire { [weak self] in
            self?.lock.withLock { _ = self?.clips.removeValue(forKey: id) }
            done()
        }
    }

    // MARK: Socket

    func start() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return Self.log.error("files socket: \(errno)") }
        unlink(path)
        do {
            var address = try SocketStream.unixAddress(path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, listen(fd, 16) == 0 else { throw posixError(errno) }
        } catch {
            close(fd)
            return Self.log.error("files socket \(self.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        lock.withLock { listener = fd }
        let thread = Thread { [weak self] in self?.accept(on: fd) }
        thread.name = "Rinflow files"
        thread.start()
    }

    func stop() {
        let fd = lock.withLock { () -> Int32 in
            defer { listener = -1 }
            return listener
        }
        guard fd >= 0 else { return }
        // Wakes accept(), which then returns.
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path)
    }

    private func accept(on listener: Int32) {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            if fd < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            let stream = SocketStream(fd: fd)
            stream.ignoreSigpipe()
            Thread.detachNewThread { [weak self] in
                defer { stream.close() }
                self?.answer(stream)
            }
        }
    }

    private func answer(_ stream: SocketStream) {
        guard Self.isOurExtension(stream.fd) else {
            return Self.log.error("files socket: refused a client that is not Rinflow's extension")
        }
        stream.setTimeout(seconds: 30)
        guard let line = try? stream.readLine(limit: FetchWire.maxRequest),
              let request = try? JSONDecoder().decode(FetchRequest.self, from: line)
        else { return }
        let (served, source) = lock.withLock { (clips[request.clip], self.source) }
        guard let served, let source,
              served.clip.entries.indices.contains(request.entry), !served.clip.entries[request.entry].dir,
              let lease = served.acquire(from: source)
        else {
            try? stream.write(FetchWire.header(FetchWire.failure) + [FetchFailure.unavailable.rawValue])
            return
        }
        let delivered = send(entry: request.entry, size: served.clip.entries[request.entry].size, of: lease, to: stream)
        served.release(delivered: delivered)
    }

    /// One file, in frames; false if it did not all get there.
    private func send(entry: Int, size: UInt64, of lease: Lease, to stream: SocketStream) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4 + FetchWire.chunk)
        var offset: UInt64 = 0
        while offset < size {
            let count = buffer.withUnsafeMutableBytes { bytes in
                lease.read(entry: entry, offset: offset, into: UnsafeMutableRawBufferPointer(rebasing: bytes[4...]))
            }
            guard let count, count > 0 else {
                // Broke off, or the file got shorter on the peer.
                try? stream.write(FetchWire.header(FetchWire.failure) + [FetchFailure.interrupted.rawValue])
                return false
            }
            buffer.replaceSubrange(0..<4, with: FetchWire.header(UInt32(count)))
            do {
                try buffer.withUnsafeBytes { try stream.write(UnsafeRawBufferPointer(rebasing: $0[..<(4 + count)])) }
            } catch {
                // The extension closed: cancelled in Finder.
                return false
            }
            offset += UInt64(count)
        }
        return (try? stream.write(FetchWire.header(FetchWire.end))) != nil
    }

    /// The client is Rinflow's File Provider extension, signed by this team.
    static func isOurExtension(_ fd: Int32) -> Bool {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let data = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess,
              let code
        else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(extensionRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

/// A clip being served, and the lease its files share.
private final class Served: @unchecked Sendable {
    let clip: Clip
    private let condition = NSCondition()
    private var lease: Lease?
    private var readers = 0
    /// Bumped whenever a reader comes or goes; an idle close checks it.
    private var generation = 0
    private var interrupted = false
    private var retiring: (@Sendable () -> Void)?

    init(_ clip: Clip) {
        self.clip = clip
    }

    /// The clip's lease, opened by the first reader (the others wait for it).
    func acquire(from source: LeaseSource) -> Lease? {
        condition.lock()
        defer { condition.unlock() }
        guard retiring == nil else { return nil }
        if lease == nil {
            // Opening holds the lock: a second file waits instead of
            // opening a second paste.
            lease = source.open(peer: clip.peer, transfer: clip.transfer)
        }
        guard let lease else { return nil }
        readers += 1
        generation += 1
        return lease
    }

    func release(delivered: Bool) {
        condition.lock()
        readers -= 1
        generation += 1
        if !delivered { interrupted = true }
        let generation = generation
        let idle = readers == 0
        let retiring = self.retiring
        condition.unlock()
        guard idle else { return }
        if let retiring {
            close()
            retiring()
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
            // Only if no file was read meanwhile.
            self?.close(ifStill: generation)
        }
    }

    func retire(_ done: @escaping @Sendable () -> Void) {
        condition.lock()
        retiring = done
        let idle = readers == 0
        condition.unlock()
        if idle {
            close()
            done()
        }
    }

    /// Closes the lease if no reader holds it (and, with `generation`, if
    /// none came and went since); a later file opens a new one.
    private func close(ifStill generation: Int? = nil) {
        condition.lock()
        guard readers == 0, generation == nil || generation == self.generation else {
            return condition.unlock()
        }
        let lease = self.lease
        self.lease = nil
        let reason = interrupted ? "cancelled" : "delivered"
        interrupted = false
        condition.unlock()
        lease?.close(reason)
    }
}
