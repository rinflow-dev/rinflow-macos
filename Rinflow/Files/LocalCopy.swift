// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A peer's copy fetched whole into this Mac's caches, for pasting: small
/// ones (a placeholder would cost more than the bytes), and any when the
/// File Provider extension is off. Read through one lease, so the core
/// reports it as one transfer.
enum LocalCopy {
    /// ~/Library/Caches/com.rinflow.mac/Pasted, one folder per clip.
    static var root: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appending(path: "com.rinflow.mac/Pasted", directoryHint: .isDirectory)
    }

    static func folder(of clip: String) -> URL {
        root.appending(path: clip, directoryHint: .isDirectory)
    }

    /// Fetches `clip` into its folder; the top-level items to paste. Blocks:
    /// call on a worker thread. `cancelled` is checked between reads.
    static func fetch(_ clip: Clip, from lease: Lease, cancelled: @Sendable () -> Bool) throws -> [URL] {
        let folder = folder(of: clip.id)
        try? FileManager.default.removeItem(at: folder)
        let tree = ClipTree(clip)
        var buffer = [UInt8](repeating: 0, count: FetchWire.chunk)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for node in tree.all {
                let url = folder.appending(path: node.path)
                if node.dir {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    continue
                }
                guard let entry = node.entry else { continue }
                try copy(entry: entry, size: node.size, of: lease, to: url, buffer: &buffer, cancelled: cancelled)
            }
        } catch {
            lease.close("cancelled")
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        lease.close("delivered")
        return tree.topLevel.map { folder.appending(path: $0.path) }
    }

    private static func copy(
        entry: Int, size: UInt64, of lease: Lease, to url: URL,
        buffer: inout [UInt8], cancelled: @Sendable () -> Bool
    ) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var offset: UInt64 = 0
        while offset < size {
            guard !cancelled() else { throw CocoaError(.userCancelled) }
            let count = buffer.withUnsafeMutableBytes { lease.read(entry: entry, offset: offset, into: $0) }
            // Broke off, or the file got shorter on the peer.
            guard let count, count > 0 else { throw FetchFailure.interrupted }
            try handle.write(contentsOf: buffer[..<count])
            offset += UInt64(count)
        }
    }

    /// Removes the clips' folders but those in `keep`.
    static func prune(keeping keep: Set<String>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where !keep.contains(name) {
            try? FileManager.default.removeItem(at: root.appending(path: name))
        }
    }
}
