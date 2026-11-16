// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import OSLog

/// A peer's copied files on this Mac's pasteboard, fetched when pasted.
///
/// The core reports them (`files_available`) without fetching anything.
/// Small copies are fetched at once into the caches (LocalCopy); larger
/// ones become placeholders of the File Provider extension, whose bytes
/// come over FileServer when Finder or another app reads them. With the
/// extension turned off, every copy goes the local way (asking first past
/// 512 MB). The pasteboard is emptied when the files arrive and holds their
/// URLs once those exist, a moment later: no pasteboard callback waits on
/// the main thread, which also runs the input tap.
@MainActor
final class RemoteFiles {
    /// Below this a copy is fetched at once.
    static let smallBytes: UInt64 = 16 * 1024 * 1024
    /// Past this, with the extension off, the user decides.
    static let askBytes: UInt64 = 512 * 1024 * 1024

    /// Asks the user to fetch a large copy (count, bytes, peer); answers on
    /// the main thread.
    var confirm: ((Clip, @escaping (Bool) -> Void) -> Void)?

    private let clipboard: ClipboardBridge
    private let container = FilesGroup.container
    private let server: FileServer?
    private var source: LeaseSource?
    /// The newest copy, and the one before (a paste of it may still run).
    private var current: Clip?
    private var previous: Clip?
    /// The local fetch under way, stopped when a newer copy comes.
    private var fetching: Flag?
    private static let log = Logger(subsystem: "com.rinflow.mac", category: "files")

    private var started = false

    init(clipboard: ClipboardBridge) {
        self.clipboard = clipboard
        server = container.map { FileServer(socket: FilesGroup.socket(in: $0)) }
    }

    /// Once, before the core first runs.
    func start() {
        guard !started else { return }
        started = true
        // What a previous run left: nothing of it is on the pasteboard any more.
        LocalCopy.prune(keeping: [])
        if let container, !ClipStore.ids(in: container).isEmpty {
            ClipStore.removeAll(in: container)
            Self.helper(["signal"]) { _, _ in }
        }
        server?.start()
    }

    /// The running core, or nil once it stopped.
    func setSource(_ source: LeaseSource?) {
        self.source = source
        server?.setSource(source)
    }

    func stop() {
        server?.stop()
    }

    /// The core's `files_available`.
    func available(peer: String, manifest: Manifest) {
        let clip = Clip(id: UUID().uuidString.lowercased(), peer: peer, transfer: manifest.transfer,
                        created: Date(), entries: manifest.entries)
        replace(with: clip)
        let hold = clipboard.holdForPeerFiles()
        Self.log.info("peer files: \(clip.entries.count) entries, \(clip.totalSize) bytes")
        if clip.totalSize <= Self.smallBytes || server == nil {
            fetchLocally(clip, hold: hold)
        } else {
            publish(clip, hold: hold)
        }
    }

    /// The core's `files_unavailable`: the peer's copy is gone. What is on
    /// the pasteboard stays; reading it fails, as copying a file someone
    /// deleted would.
    func unavailable(peer: String) {
        Self.log.info("peer files no longer available")
    }

    /// Sharing the clipboard was turned off: nothing of a peer's copy stays.
    func withdrawAll() {
        fetching?.set()
        fetching = nil
        for clip in [current, previous].compactMap({ $0 }) { retire(clip) }
        current = nil
        previous = nil
        LocalCopy.prune(keeping: [])
    }

    private func replace(with clip: Clip) {
        fetching?.set()
        fetching = nil
        if let previous { retire(previous) }
        previous = current
        current = clip
        LocalCopy.prune(keeping: Set([current?.id, previous?.id].compactMap { $0 }))
    }

    /// A clip's placeholders go once no paste of it runs any more.
    private func retire(_ clip: Clip) {
        guard let container, let server else { return }
        server.retire(clip.id) {
            ClipStore.remove(clip.id, in: container)
            Self.helper(["signal"]) { _, _ in }
        }
    }

    private func fetchLocally(_ clip: Clip, hold: Int) {
        guard clip.totalSize <= Self.askBytes || confirm == nil else {
            confirm?(clip) { [weak self] accepted in
                guard accepted else { return }
                self?.fetchLocallyNow(clip, hold: hold)
            }
            return
        }
        fetchLocallyNow(clip, hold: hold)
    }

    private func fetchLocallyNow(_ clip: Clip, hold: Int) {
        guard let source else { return }
        let cancelled = Flag()
        fetching = cancelled
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let urls: [URL]?
            if let lease = source.open(peer: clip.peer, transfer: clip.transfer) {
                urls = try? LocalCopy.fetch(clip, from: lease, cancelled: { cancelled.isSet })
            } else {
                urls = nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.ready(clip, urls: urls, hold: hold) }
            }
        }
    }

    private func publish(_ clip: Clip, hold: Int) {
        guard let container, let server else { return fetchLocally(clip, hold: hold) }
        do {
            try ClipStore.write(clip, in: container)
        } catch {
            Self.log.error("clip not written: \(error.localizedDescription, privacy: .public)")
            return fetchLocally(clip, hold: hold)
        }
        server.serve(clip)
        let names = ClipTree(clip).topLevel.map(\.name)
        Self.helper(["publish", clip.id] + names) { [weak self] status, output in
            MainActor.assumeIsolated {
                guard let self, self.current?.id == clip.id else { return }
                guard status == 0 else {
                    Self.log.notice("placeholders not made (\(status)), fetching instead")
                    ClipStore.remove(clip.id, in: container)
                    return self.fetchLocally(clip, hold: hold)
                }
                let folder = URL(filePath: output.trimmingCharacters(in: .whitespacesAndNewlines), directoryHint: .isDirectory)
                self.ready(clip, urls: names.map { folder.appending(path: $0) }, hold: hold)
            }
        }
    }

    private func ready(_ clip: Clip, urls: [URL]?, hold: Int) {
        guard current?.id == clip.id else { return }
        guard let urls, !urls.isEmpty else {
            return Self.log.error("peer files could not be made pasteable")
        }
        if !clipboard.writeFiles(urls, ifUnchangedSince: hold) {
            Self.log.info("pasteboard changed meanwhile: peer files not written")
        }
    }

    /// Runs rinflow-files (Contents/MacOS) and answers on the main queue
    /// with its exit status and output.
    private nonisolated static func helper(_ arguments: [String], done: @escaping @Sendable (Int32, String) -> Void) {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "rinflow-files") else {
            return DispatchQueue.main.async { done(127, "") }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = url
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            do {
                try process.run()
            } catch {
                return DispatchQueue.main.async { done(127, "") }
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let status = process.terminationStatus
            DispatchQueue.main.async { done(status, String(decoding: data, as: UTF8.self)) }
        }
    }
}

/// Tells a worker to stop.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false

    var isSet: Bool { lock.withLock { on } }

    func set() {
        lock.withLock { on = true }
    }
}
