// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import FileProvider
import Foundation

/// The clips the app wrote, as trees. A clip never changes once written, so
/// a tree is built once per clip.
final class Catalog: @unchecked Sendable {
    let container: URL
    private let lock = NSLock()
    private var trees: [String: ClipTree] = [:]

    init?() {
        guard let container = FilesGroup.container else { return nil }
        self.container = container
    }

    /// The clips there now, sorted; forgets the trees of withdrawn ones.
    func ids() -> [String] {
        let ids = ClipStore.ids(in: container)
        lock.withLock {
            let present = Set(ids)
            trees = trees.filter { present.contains($0.key) }
        }
        return ids
    }

    func tree(_ id: String) -> ClipTree? {
        if let tree = lock.withLock({ trees[id] }) { return tree }
        guard let clip = ClipStore.read(id, in: container), clip.id == id else { return nil }
        let tree = ClipTree(clip)
        lock.withLock { trees[id] = tree }
        return tree
    }

    func item(_ identifier: NSFileProviderItemIdentifier) -> Item? {
        if identifier == .rootContainer { return .root }
        guard let (clip, path) = ItemName.parse(identifier.rawValue),
              let tree = tree(clip), let node = tree.nodes[path]
        else { return nil }
        return Item(node, of: tree.clip)
    }

    /// What a folder holds, or nil if it is not a folder (any more).
    func children(of identifier: NSFileProviderItemIdentifier) -> [Item]? {
        if identifier == .rootContainer {
            return ids().compactMap { id in tree(id).flatMap { tree in tree.nodes[""].map { Item($0, of: tree.clip) } } }
        }
        guard let (clip, path) = ItemName.parse(identifier.rawValue),
              let tree = tree(clip), tree.nodes[path]?.dir == true
        else { return nil }
        return tree.children(of: path).map { Item($0, of: tree.clip) }
    }

    /// A clip's folder and then everything in it, each after its parent.
    func items(of id: String, in range: Range<Int>) -> [Item] {
        guard let tree = tree(id), let folder = tree.nodes[""] else { return [] }
        let nodes = [folder] + tree.all
        let clamped = range.clamped(to: 0..<nodes.count)
        return nodes[clamped].map { Item($0, of: tree.clip) }
    }

    func count(of id: String) -> Int {
        tree(id)?.all.count ?? 0
    }
}
