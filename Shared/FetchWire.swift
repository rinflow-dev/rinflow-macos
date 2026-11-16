// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Darwin
import Foundation

/// How the File Provider extension gets a file's bytes from the app, over
/// the Unix socket `files.sock` in the App Group container. One connection
/// per file:
///
///   extension → app   one line of JSON, `FetchRequest`, ending in "\n"
///   app → extension   frames: a big-endian UInt32 n, then
///                       n > 0          n bytes of the file, in order
///                       0              the end: every byte was sent
///                       0xFFFF_FFFF    a failure: one byte, `FetchFailure`
///
/// The extension cancels by closing the connection; the app notices at its
/// next write. The app checks the extension's signature before it answers.
struct FetchRequest: Codable, Equatable, Sendable {
    var clip: String
    /// The manifest entry.
    var entry: Int
}

enum FetchFailure: UInt8, Error, Sendable {
    /// The peer's copy is gone (it copied something else, or left), or the
    /// clip is not this app's current one.
    case unavailable = 1
    /// The transfer broke off: the connection was lost, a read timed out,
    /// or the file changed on the peer.
    case interrupted = 2
}

enum FetchWire {
    static let end: UInt32 = 0
    static let failure: UInt32 = 0xFFFF_FFFF
    /// What the core reads at a time (LC_FILE_READ_MAX).
    static let chunk = 256 * 1024
    static let maxRequest = 4096

    static func header(_ length: UInt32) -> [UInt8] {
        withUnsafeBytes(of: length.bigEndian, Array.init)
    }

    static func length(_ header: [UInt8]) -> UInt32 {
        header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
    }
}

/// A connected stream socket: blocking reads and writes of whole buffers.
struct SocketStream: Sendable {
    let fd: Int32

    /// Connects to the Unix socket at `path`.
    static func connect(to path: String) throws -> SocketStream {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError(errno) }
        var address = try unixAddress(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = posixError(errno)
            Darwin.close(fd)
            throw error
        }
        let stream = SocketStream(fd: fd)
        stream.ignoreSigpipe()
        return stream
    }

    static func unixAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    /// A closed peer is an error from write, not a signal that ends the process.
    func ignoreSigpipe() {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Reads and writes give up after this long without progress.
    func setTimeout(seconds: Int) {
        var time = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { throw posixError(written < 0 ? errno : EPIPE) }
            offset += written
        }
    }

    func write(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try write($0) }
    }

    /// Exactly `count` bytes into `buffer`; EOF before them is an error.
    func read(into buffer: UnsafeMutableRawBufferPointer) throws {
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.read(fd, buffer.baseAddress! + offset, buffer.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw posixError(count < 0 ? errno : ECONNRESET) }
            offset += count
        }
    }

    func read(count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        try bytes.withUnsafeMutableBytes { try read(into: $0) }
        return bytes
    }

    /// One line, without its "\n", of at most `limit` bytes.
    func readLine(limit: Int) throws -> Data {
        var line = Data()
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { throw posixError(count < 0 ? errno : ECONNRESET) }
            if byte == UInt8(ascii: "\n") { return line }
            guard line.count < limit else { throw POSIXError(.EMSGSIZE) }
            line.append(byte)
        }
    }

    func close() {
        Darwin.close(fd)
    }
}

func posixError(_ code: Int32) -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
}
