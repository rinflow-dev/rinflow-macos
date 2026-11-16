// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import XCTest

final class OnDemandFilesTests: XCTestCase {
    private func clip(_ entries: [Clip.Entry]) -> Clip {
        Clip(id: "c1", peer: "pc", transfer: 7, created: Date(timeIntervalSince1970: 0), entries: entries)
    }

    func testTheManifestOfTheCoreDecodes() throws {
        let json = #"{"transfer":7,"total_size":5,"entries":[{"path":"Folder","dir":true},{"path":"Folder/a.txt","size":5}]}"#
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.transfer, 7)
        XCTAssertEqual(manifest.entries, [Clip.Entry(path: "Folder", dir: true), Clip.Entry(path: "Folder/a.txt", size: 5)])
    }

    func testTreeAddsFoldersTheManifestLeavesOut() {
        let tree = ClipTree(clip([
            Clip.Entry(path: "a/b/c.txt", size: 3),
            Clip.Entry(path: "top.txt", size: 1),
            Clip.Entry(path: "a/d.txt", size: 2),
        ]))
        XCTAssertEqual(tree.topLevel.map(\.name), ["a", "top.txt"])
        XCTAssertEqual(tree.nodes["a/b"]?.dir, true)
        XCTAssertNil(tree.nodes["a/b"]?.entry)
        XCTAssertEqual(tree.nodes["a/b/c.txt"]?.entry, 0)
        XCTAssertEqual(tree.nodes["a/d.txt"]?.entry, 2)
        XCTAssertEqual(tree.children(of: "a").map(\.name), ["b", "d.txt"])
        // Each node after its parent.
        XCTAssertEqual(tree.all.map(\.path), ["a", "a/b", "a/b/c.txt", "a/d.txt", "top.txt"])
        XCTAssertEqual(clip(tree.clip.entries).totalSize, 6)
    }

    func testTreeKeepsTheFirstOfTwoEntriesWithOnePath() {
        let tree = ClipTree(clip([Clip.Entry(path: "x", size: 1), Clip.Entry(path: "x", size: 9)]))
        XCTAssertEqual(tree.all.count, 1)
        XCTAssertEqual(tree.nodes["x"]?.entry, 0)
    }

    func testItemNames() {
        XCTAssertEqual(ItemName.item("c1", ""), "c1")
        XCTAssertEqual(ItemName.item("c1", "a/b.txt"), "c1/a/b.txt")
        XCTAssertEqual(ItemName.parse("c1/a/b.txt")?.clip, "c1")
        XCTAssertEqual(ItemName.parse("c1/a/b.txt")?.path, "a/b.txt")
        XCTAssertEqual(ItemName.parse("c1")?.path, "")
        XCTAssertNil(ItemName.parse(""))
        XCTAssertNil(ItemName.parse("c1/"))
        XCTAssertNil(ItemName.parse("/a"))
    }

    func testWorkingSetReportsNewClipsInPagesAndDeletesGoneOnes() {
        let counts = ["a": 2, "b": 0, "c": 4]
        // From nothing: a's folder and its 2 nodes, in pages of 2.
        var anchor = ClipAnchor(clips: [])
        var step = anchor.step(to: ["a", "c"], count: { counts[$0]! }, page: 2)
        XCTAssertEqual(step.clip, "a")
        XCTAssertEqual(step.range, 0..<2)
        XCTAssertTrue(step.moreComing)
        anchor = step.next
        step = anchor.step(to: ["a", "c"], count: { counts[$0]! }, page: 2)
        XCTAssertEqual(step.clip, "a")
        XCTAssertEqual(step.range, 2..<3)
        XCTAssertTrue(step.moreComing, "c is still to come")
        XCTAssertEqual(step.next.clips, ["a"])
        anchor = step.next
        // a withdrawn, b new, c half done: a deleted, then b.
        anchor = ClipAnchor(clips: ["a"], clip: "c", offset: 2)
        step = anchor.step(to: ["b", "c"], count: { counts[$0]! }, page: 10)
        XCTAssertEqual(step.deleted, ["a"])
        XCTAssertEqual(step.clip, "b")
        XCTAssertEqual(step.range, 0..<1)
        XCTAssertEqual(step.next, ClipAnchor(clips: ["b"]))
        XCTAssertTrue(step.moreComing)
        // c starts over: the half-reported clip was not b.
        step = step.next.step(to: ["b", "c"], count: { counts[$0]! }, page: 10)
        XCTAssertEqual(step.clip, "c")
        XCTAssertEqual(step.range, 0..<5)
        XCTAssertFalse(step.moreComing)
        XCTAssertEqual(step.next, ClipAnchor(clips: ["b", "c"]))
        // Nothing new, nothing gone.
        step = step.next.step(to: ["b", "c"], count: { counts[$0]! }, page: 10)
        XCTAssertNil(step.clip)
        XCTAssertEqual(step.deleted, [])
        XCTAssertFalse(step.moreComing)
        XCTAssertEqual(ClipAnchor(step.next.data), step.next)
    }

    func testClipStoreRoundTrips() throws {
        let container = FileManager.default.temporaryDirectory.appending(path: "clips-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let stored = clip([Clip.Entry(path: "a.txt", size: 3)])
        try ClipStore.write(stored, in: container)
        XCTAssertEqual(ClipStore.ids(in: container), ["c1"])
        XCTAssertEqual(ClipStore.read("c1", in: container), stored)
        XCTAssertNil(ClipStore.read("../c1", in: container))
        ClipStore.remove("c1", in: container)
        XCTAssertEqual(ClipStore.ids(in: container), [])
    }

    func testFramesOverASocket() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let app = SocketStream(fd: fds[0])
        let fileProvider = SocketStream(fd: fds[1])
        defer { app.close(); fileProvider.close() }

        var line = try JSONEncoder().encode(FetchRequest(clip: "c1", entry: 3))
        line.append(UInt8(ascii: "\n"))
        try line.withUnsafeBytes { try fileProvider.write($0) }
        XCTAssertEqual(try JSONDecoder().decode(FetchRequest.self, from: app.readLine(limit: FetchWire.maxRequest)),
                       FetchRequest(clip: "c1", entry: 3))

        try app.write(FetchWire.header(3) + [1, 2, 3] + FetchWire.header(FetchWire.end))
        XCTAssertEqual(FetchWire.length(try fileProvider.read(count: 4)), 3)
        XCTAssertEqual(try fileProvider.read(count: 3), [1, 2, 3])
        XCTAssertEqual(FetchWire.length(try fileProvider.read(count: 4)), FetchWire.end)

        try app.write(FetchWire.header(FetchWire.failure) + [FetchFailure.unavailable.rawValue])
        XCTAssertEqual(FetchWire.length(try fileProvider.read(count: 4)), FetchWire.failure)
        XCTAssertEqual(try fileProvider.read(count: 1), [1])

        try line.withUnsafeBytes { try fileProvider.write($0) }
        XCTAssertThrowsError(try app.readLine(limit: 4), "a request past the limit")
    }

    func testUnixAddressRefusesPathsTooLong() {
        XCTAssertNoThrow(try SocketStream.unixAddress("/tmp/a.sock"))
        XCTAssertThrowsError(try SocketStream.unixAddress("/" + String(repeating: "a", count: 200)))
    }

    @MainActor
    func testPeerFilesWaitOnAnEmptiedPasteboardAndYieldToALaterCopy() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("RinflowTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        let bridge = ClipboardBridge(pasteboard: pasteboard)
        let url = URL(filePath: "/tmp/a.txt")

        var hold = bridge.holdForPeerFiles()
        XCTAssertNil(pasteboard.string(forType: .string), "nothing to paste meanwhile")
        XCTAssertTrue(bridge.writeFiles([url], ifUnchangedSince: hold))
        XCTAssertEqual(pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], [url])

        hold = bridge.holdForPeerFiles()
        pasteboard.clearContents()
        pasteboard.setString("copied meanwhile", forType: .string)
        XCTAssertFalse(bridge.writeFiles([url], ifUnchangedSince: hold))
        XCTAssertEqual(pasteboard.string(forType: .string), "copied meanwhile")
    }
}
