// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import FileProvider
import UniformTypeIdentifiers

/// One file or folder of a peer's copy, or the domain's root.
final class Item: NSObject, NSFileProviderItem, @unchecked Sendable {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let itemVersion: NSFileProviderItemVersion
    let creationDate: Date?
    let contentModificationDate: Date?

    /// Writing, deleting and renaming are allowed though nothing is done
    /// with them: a placeholder that only allows reading makes Finder's
    /// copy of it locked (uchg) too.
    var capabilities: NSFileProviderItemCapabilities {
        var capabilities: NSFileProviderItemCapabilities = [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming, .allowsReparenting]
        if contentType == .folder {
            capabilities.insert(.allowsContentEnumerating)
            capabilities.insert(.allowsAddingSubItems)
        }
        return capabilities
    }

    var fileSystemFlags: NSFileProviderFileSystemFlags {
        contentType == .folder ? [.userReadable, .userWritable, .userExecutable] : [.userReadable, .userWritable]
    }

    /// Fetched when read, kept as long as the system likes.
    var contentPolicy: NSFileProviderContentPolicy { .downloadLazily }

    private init(
        identifier: NSFileProviderItemIdentifier,
        parent: NSFileProviderItemIdentifier,
        filename: String,
        folder: Bool,
        size: UInt64,
        version: Data,
        date: Date
    ) {
        itemIdentifier = identifier
        parentItemIdentifier = parent
        self.filename = filename
        contentType = folder ? .folder : (UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data)
        documentSize = folder ? nil : NSNumber(value: size)
        itemVersion = NSFileProviderItemVersion(contentVersion: version, metadataVersion: version)
        creationDate = date
        contentModificationDate = date
    }

    static let root = Item(
        identifier: .rootContainer, parent: .rootContainer, filename: "Rinflow",
        folder: true, size: 0, version: Data("root".utf8), date: Date(timeIntervalSince1970: 0)
    )

    /// A node of a clip; its version is the clip's, which never changes.
    convenience init(_ node: ClipTree.Node, of clip: Clip) {
        let identifier = NSFileProviderItemIdentifier(ItemName.item(clip.id, node.path))
        let parent: NSFileProviderItemIdentifier = node.path.isEmpty
            ? .rootContainer
            : NSFileProviderItemIdentifier(ItemName.item(clip.id, ClipTree.parent(of: node.path)))
        self.init(
            identifier: identifier, parent: parent, filename: node.name, folder: node.dir,
            size: node.size, version: Data("\(clip.transfer)".utf8), date: clip.created
        )
    }
}
