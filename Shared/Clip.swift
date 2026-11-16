// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Files a peer copied, as the app and its File Provider extension
/// (FileProvider/) both see them. Compiled into both, and the tests.
///
/// The app writes one `Clip` per peer copy into the App Group container
/// (`Clips/<id>.json`); the extension turns it into placeholders that hold no
/// bytes until something reads them, and then asks the app for those bytes
/// over `files.sock` (FetchWire.swift). docs/on-demand-files.md has the whole.
enum FilesGroup {
    /// Team-prefixed, so it needs no provisioning profile (Developer ID).
    static let identifier = "998ZTJV2HQ.com.rinflow.mac"
    static let domain = "clipboard"
    static let extensionIdentifier = "com.rinflow.mac.files"

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static func clips(in container: URL) -> URL {
        container.appending(path: "Clips", directoryHint: .isDirectory)
    }

    /// Unix sockets have a 104-byte path limit; this one is about 75.
    static func socket(in container: URL) -> URL {
        container.appending(path: "files.sock", directoryHint: .notDirectory)
    }
}

/// The core's manifest in `files_available`.
struct Manifest: Decodable, Sendable {
    let transfer: UInt32
    let entries: [Clip.Entry]
}

/// One peer copy: the core's manifest (`files_available`) and who has it.
struct Clip: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        /// Relative, "/"-separated, checked by the core not to leave its
        /// folder (no "..", no leading "/").
        var path: String
        var size: UInt64
        var dir: Bool

        init(path: String, size: UInt64 = 0, dir: Bool = false) {
            self.path = path
            self.size = size
            self.dir = dir
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            path = try values.decode(String.self, forKey: .path)
            size = try values.decodeIfPresent(UInt64.self, forKey: .size) ?? 0
            dir = try values.decodeIfPresent(Bool.self, forKey: .dir) ?? false
        }
    }

    /// Random, lowercase UUID: names the clip's folder and prefixes its items.
    var id: String
    var peer: String
    var transfer: UInt32
    var created: Date
    /// In the manifest's order: entry `i` is the core's entry `i`.
    var entries: [Entry]

    var totalSize: UInt64 { entries.reduce(0) { $0 + $1.size } }
}

/// A clip as a tree, for enumerating it. Folders a manifest leaves out
/// (it names `a/b.txt` but not `a`) are added, so every path has a parent.
struct ClipTree: Sendable {
    struct Node: Equatable, Sendable {
        /// "" for the clip's own folder.
        let path: String
        let name: String
        let dir: Bool
        let size: UInt64
        /// The manifest entry to read; nil for folders.
        let entry: Int?
    }

    let clip: Clip
    private(set) var nodes: [String: Node] = [:]
    private(set) var children: [String: [String]] = [:]

    init(_ clip: Clip) {
        self.clip = clip
        nodes[""] = Node(path: "", name: clip.id, dir: true, size: 0, entry: nil)
        for (index, entry) in clip.entries.enumerated() where nodes[entry.path] == nil {
            add(entry.path, dir: entry.dir, size: entry.dir ? 0 : entry.size, entry: entry.dir ? nil : index)
        }
    }

    private mutating func add(_ path: String, dir: Bool, size: UInt64, entry: Int?) {
        let parent = Self.parent(of: path)
        if nodes[parent] == nil {
            add(parent, dir: true, size: 0, entry: nil)
        }
        nodes[path] = Node(path: path, name: Self.name(of: path), dir: dir, size: size, entry: entry)
        children[parent, default: []].append(path)
    }

    /// What goes on the pasteboard: the clip's top-level items.
    var topLevel: [Node] { (children[""] ?? []).compactMap { nodes[$0] } }

    func children(of path: String) -> [Node] {
        (children[path] ?? []).compactMap { nodes[$0] }
    }

    /// Every node but the clip's folder, each after its parent.
    var all: [Node] {
        var result: [Node] = []
        var stack = Array((children[""] ?? []).reversed())
        while let path = stack.popLast() {
            guard let node = nodes[path] else { continue }
            result.append(node)
            stack.append(contentsOf: (children[path] ?? []).reversed())
        }
        return result
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    static func name(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}

/// File Provider item identifiers: "<clip>" for a clip's folder and
/// "<clip>/<path>" for what is in it. Clip IDs hold no "/".
enum ItemName {
    static func clipFolder(_ clip: String) -> String { clip }

    static func item(_ clip: String, _ path: String) -> String {
        path.isEmpty ? clip : "\(clip)/\(path)"
    }

    /// (clip, path); path "" for the clip's folder.
    static func parse(_ identifier: String) -> (clip: String, path: String)? {
        guard !identifier.isEmpty else { return nil }
        guard let slash = identifier.firstIndex(of: "/") else { return (identifier, "") }
        let clip = String(identifier[..<slash])
        let path = String(identifier[identifier.index(after: slash)...])
        return clip.isEmpty || path.isEmpty ? nil : (clip, path)
    }
}

/// Where the working set's change enumeration stands. The extension reports
/// a new clip's items in pages and a withdrawn clip as one deletion (its
/// folder: the system removes what is inside).
struct ClipAnchor: Codable, Equatable, Sendable {
    /// Clips fully reported.
    var clips: [String]
    /// A clip being reported, and how many of its items went already.
    var clip: String?
    var offset: Int

    init(clips: [String], clip: String? = nil, offset: Int = 0) {
        self.clips = clips
        self.clip = clip
        self.offset = offset
    }

    var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }

    init?(_ data: Data) {
        guard let anchor = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = anchor
    }

    /// The next step from `self` to `current` (sorted clip IDs): what to
    /// delete, which items of which clip to report (the folder itself is
    /// offset 0), and where that leaves things.
    struct Step: Equatable {
        var deleted: [String]
        var clip: String?
        var range: Range<Int>
        var next: ClipAnchor
        var moreComing: Bool
    }

    func step(to current: [String], count: (String) -> Int, page: Int) -> Step {
        let known = Set(clips)
        let present = Set(current)
        let deleted = clips.filter { !present.contains($0) }
        let kept = clips.filter { present.contains($0) }
        let fresh = current.filter { !known.contains($0) }
        guard let clip = fresh.first else {
            return Step(deleted: deleted, clip: nil, range: 0..<0, next: ClipAnchor(clips: kept), moreComing: false)
        }
        let start = self.clip == clip ? offset : 0
        // The folder, then each of its nodes.
        let total = count(clip) + 1
        let end = min(total, start + page)
        let done = end >= total
        let next = done ? ClipAnchor(clips: kept + [clip]) : ClipAnchor(clips: kept, clip: clip, offset: end)
        let moreComing = !done || fresh.count > 1
        return Step(deleted: deleted, clip: clip, range: start..<end, next: next, moreComing: moreComing)
    }
}

/// Reads and writes clips in the App Group container. Clips never change
/// once written: a new copy is a new clip.
enum ClipStore {
    static func write(_ clip: Clip, in container: URL) throws {
        let directory = FilesGroup.clips(in: container)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(clip)
        try data.write(to: directory.appending(path: "\(clip.id).json"), options: .atomic)
    }

    static func remove(_ id: String, in container: URL) {
        try? FileManager.default.removeItem(at: FilesGroup.clips(in: container).appending(path: "\(id).json"))
    }

    static func removeAll(in container: URL) {
        try? FileManager.default.removeItem(at: FilesGroup.clips(in: container))
    }

    /// The clips there now, sorted by ID.
    static func ids(in container: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FilesGroup.clips(in: container).path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    static func read(_ id: String, in container: URL) -> Clip? {
        guard !id.contains("/"),
              let data = try? Data(contentsOf: FilesGroup.clips(in: container).appending(path: "\(id).json"))
        else { return nil }
        return try? JSONDecoder().decode(Clip.self, from: data)
    }
}
