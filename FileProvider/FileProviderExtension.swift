// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import FileProvider
import OSLog

/// Rinflow's File Provider: a peer's copied files as placeholders that are
/// fetched from the peer only when something reads them, such as Finder
/// pasting them. The app writes the clips (Shared/Clip.swift) and serves
/// the bytes (Shared/FetchWire.swift); this extension is sandboxed and only
/// sees the App Group container. One hidden domain, "clipboard".
@objc(FileProviderExtension)
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable {
    private let domain: NSFileProviderDomain
    private let catalog: Catalog?
    private static let log = Logger(subsystem: "com.rinflow.mac.files", category: "extension")

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        catalog = domain.identifier.rawValue == FilesGroup.domain ? Catalog() : nil
        super.init()
        if catalog == nil {
            Self.log.error("no catalog for domain \(domain.identifier.rawValue, privacy: .public)")
        }
    }

    func invalidate() {}

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, (any Error)?) -> Void
    ) -> Progress {
        if let item = catalog?.item(identifier) {
            completionHandler(item, nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress()
    }

    func enumerator(for container: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> any NSFileProviderEnumerator {
        guard let catalog else { throw NSFileProviderError(.noSuchItem) }
        if container == .workingSet { return WorkingSetEnumerator(catalog: catalog) }
        if container == .trashContainer { throw NSFileProviderError(.noSuchItem) }
        guard catalog.children(of: container) != nil else { throw NSFileProviderError(.noSuchItem) }
        return FolderEnumerator(container, catalog: catalog)
    }

    func fetchContents(
        for identifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, (any Error)?) -> Void
    ) -> Progress {
        guard let catalog, let item = catalog.item(identifier),
              let (clip, path) = ItemName.parse(identifier.rawValue),
              let entry = catalog.tree(clip)?.nodes[path]?.entry
        else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        if let requestedVersion, requestedVersion.contentVersion != item.itemVersion.contentVersion {
            completionHandler(nil, nil, NSFileProviderError(.versionNoLongerAvailable))
            return Progress()
        }
        let size = item.documentSize?.int64Value ?? 0
        let progress = Progress(totalUnitCount: size)
        progress.kind = .file
        progress.fileOperationKind = .downloading
        let fetch = Fetch(
            socket: FilesGroup.socket(in: catalog.container).path,
            request: FetchRequest(clip: clip, entry: entry),
            size: size,
            progress: progress
        )
        progress.cancellationHandler = { fetch.cancel() }
        let temporary: URL
        do {
            temporary = try NSFileProviderManager(for: domain)?.temporaryDirectoryURL()
                ?? FileManager.default.temporaryDirectory
        } catch {
            completionHandler(nil, nil, error)
            return progress
        }
        // The system's completion handler may be called from any thread.
        let complete = Unchecked(completionHandler)
        Thread.detachNewThread {
            let file = temporary.appending(path: UUID().uuidString)
            do {
                try fetch.run(into: file)
                complete.value(file, item, nil)
            } catch {
                try? FileManager.default.removeItem(at: file)
                Self.log.error("fetch of \(identifier.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                complete.value(nil, nil, Self.reported(error))
            }
        }
        return progress
    }

    /// What Finder makes of a failure. Interruptions are worth trying
    /// again; a copy that is gone is not (the system would retry it until it
    /// times out).
    private static func reported(_ error: any Error) -> any Error {
        switch error {
        case FetchFailure.unavailable: NSFileProviderError(.noSuchItem)
        case FetchFailure.interrupted: NSFileProviderError(.serverUnreachable)
        case let error as CocoaError where error.code == .userCancelled: error
        case is POSIXError: NSFileProviderError(.serverUnreachable)
        default: error
        }
    }

    // The domain is hidden and its items are the peer's: nothing done to
    // them here goes anywhere. Deleting is accepted, the rest refused.

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
    ) -> Progress {
        completionHandler(nil, [], false, CocoaError(.fileWriteNoPermission))
        return Progress()
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
    ) -> Progress {
        completionHandler(nil, [], false, CocoaError(.fileWriteNoPermission))
        return Progress()
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping ((any Error)?) -> Void
    ) -> Progress {
        completionHandler(nil)
        return Progress()
    }
}

/// A value the system's API does not mark Sendable though it is.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// One file's bytes from the app, into a file.
final class Fetch: @unchecked Sendable {
    private let socket: String
    private let request: FetchRequest
    private let size: Int64
    private let progress: Progress
    private let lock = NSLock()
    private var stream: SocketStream?
    private var cancelled = false

    init(socket: String, request: FetchRequest, size: Int64, progress: Progress) {
        self.socket = socket
        self.request = request
        self.size = size
        self.progress = progress
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            // Wakes a blocked read; the app sees the close at its next write.
            if let stream { shutdown(stream.fd, SHUT_RDWR) }
        }
    }

    func run(into file: URL) throws {
        let stream = try SocketStream.connect(to: socket)
        defer { stream.close() }
        let go = lock.withLock { () -> Bool in
            self.stream = stream
            return !cancelled
        }
        guard go else { throw CocoaError(.userCancelled) }
        // The app opens the peer's copy (up to 15 s) and each read may take
        // as long; a minute of silence means it is gone.
        stream.setTimeout(seconds: 60)
        var line = try JSONEncoder().encode(request)
        line.append(UInt8(ascii: "\n"))
        try line.withUnsafeBytes { try stream.write($0) }

        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var buffer = [UInt8](repeating: 0, count: FetchWire.chunk)
        var received: Int64 = 0
        while true {
            let length: UInt32
            do {
                length = FetchWire.length(try stream.read(count: 4))
            } catch {
                throw lock.withLock({ cancelled }) ? CocoaError(.userCancelled) : FetchFailure.interrupted
            }
            if length == FetchWire.end { break }
            if length == FetchWire.failure {
                let code = (try? stream.read(count: 1))?.first ?? FetchFailure.interrupted.rawValue
                throw FetchFailure(rawValue: code) ?? .interrupted
            }
            guard Int(length) <= buffer.count, received + Int64(length) <= size else {
                throw FetchFailure.interrupted
            }
            do {
                try buffer.withUnsafeMutableBytes { try stream.read(into: UnsafeMutableRawBufferPointer(rebasing: $0[..<Int(length)])) }
            } catch {
                throw lock.withLock({ cancelled }) ? CocoaError(.userCancelled) : FetchFailure.interrupted
            }
            try handle.write(contentsOf: buffer[..<Int(length)])
            received += Int64(length)
            progress.completedUnitCount = received
        }
        guard received == size else { throw FetchFailure.interrupted }
        try handle.synchronize()
    }
}
