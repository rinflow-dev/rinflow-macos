// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import FileProvider
import Foundation

private let pageSize = 500

/// What a folder holds. Its contents never change (a clip is written once),
/// so it has no changes to report; the working set reports clips coming
/// and going.
final class FolderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let catalog: Catalog
    private let folder: NSFileProviderItemIdentifier

    init(_ folder: NSFileProviderItemIdentifier, catalog: Catalog) {
        self.folder = folder
        self.catalog = catalog
    }

    func invalidate() {}

    func enumerateItems(for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        guard let items = catalog.children(of: folder) else {
            observer.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
            return
        }
        let start = Self.offset(page)
        let end = min(items.count, start + pageSize)
        observer.didEnumerate(Array(items[min(start, end)..<end]))
        observer.finishEnumerating(upTo: end < items.count ? Self.page(end) : nil)
    }

    func enumerateChanges(for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("folder".utf8)))
    }

    /// The first page (`initialPageSortedByName` and the like) is 0.
    static func offset(_ page: NSFileProviderPage) -> Int {
        Int(String(decoding: page.rawValue, as: UTF8.self)) ?? 0
    }

    static func page(_ offset: Int) -> NSFileProviderPage {
        NSFileProviderPage(Data("\(offset)".utf8))
    }
}

/// Every clip's items. The system keeps these in its database, which is
/// what lets a placeholder's URL go on the pasteboard before anyone looked
/// at the folder. A new clip's items come in pages; a withdrawn clip goes
/// as one deletion of its folder.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let catalog: Catalog

    init(catalog: Catalog) {
        self.catalog = catalog
    }

    func invalidate() {}

    func enumerateItems(for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        // The whole set, as the changes from nothing would be.
        var cursor = ClipAnchor(page.rawValue) ?? ClipAnchor(clips: [])
        let step = cursor.step(to: catalog.ids(), count: catalog.count(of:), page: pageSize)
        if let clip = step.clip {
            observer.didEnumerate(catalog.items(of: clip, in: step.range))
        }
        cursor = step.next
        observer.finishEnumerating(upTo: step.moreComing ? NSFileProviderPage(cursor.data) : nil)
    }

    func enumerateChanges(for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        guard let from = ClipAnchor(anchor.rawValue) else {
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            return
        }
        let step = from.step(to: catalog.ids(), count: catalog.count(of:), page: pageSize)
        if !step.deleted.isEmpty {
            observer.didDeleteItems(withIdentifiers: step.deleted.map { NSFileProviderItemIdentifier(ItemName.clipFolder($0)) })
        }
        if let clip = step.clip {
            observer.didUpdate(catalog.items(of: clip, in: step.range))
        }
        observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(step.next.data), moreComing: step.moreComing)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(ClipAnchor(clips: catalog.ids()).data))
    }
}
