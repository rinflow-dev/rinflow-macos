// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import XCTest

/// The arrangement geometry, against the same cases as the Windows agent's
/// `arrangement.rs` and the core's `layout.rs`.
final class LayoutTests: XCTestCase {
    func testPointerLockClampsAtTheEdgeUntilUnlocked() throws {
        let world = world()
        let peer = try XCTUnwrap(world.peer("mac"))
        let portal = try XCTUnwrap(world.portals(to: "mac").first)
        var pointer = RemotePointer(crossing: portal, at: CGPoint(x: 1920, y: 500), peer: peer,
                                    portals: world.portals(to: "mac"), neighbors: world.neighbors(of: "mac"))
        XCTAssertEqual(pointer.step(by: CGVector(dx: -100, dy: 0), allowCrossing: false), .stay)
        XCTAssertEqual(pointer.position.x, 0)
        XCTAssertEqual(pointer.step(by: CGVector(dx: -10, dy: 0)), .home(CGPoint(x: 1918, y: 500)))
    }

    private func screen(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Display {
        Display(x: x, y: y, width: width, height: height, scale: 1)
    }

    /// This Mac in the middle, a Mac to its right, a PC right of that Mac,
    /// and a tablet above this one. Peers are given in their own space.
    private func world(local: [Display]? = nil) -> World {
        World(
            local: local ?? [screen(0, 0, 1920, 1080)],
            peers: [
                PlacedPeer(id: "mac", displays: [screen(0, 0, 1512, 982)], offset: Offset(x: 1920, y: 0)),
                PlacedPeer(id: "pc", displays: [screen(0, 0, 1920, 1080)], offset: Offset(x: 3432, y: 0)),
                PlacedPeer(id: "tablet", displays: [screen(0, 0, 1280, 800)], offset: Offset(x: 400, y: -800)),
            ]
        )
    }

    func testShortcutsMoveToTheNearestDeviceOnThatSide() {
        let world = world()
        XCTAssertEqual(world.toward(from: .local, side: .right), .peer("mac"))
        XCTAssertEqual(world.toward(from: .peer("mac"), side: .right), .peer("pc"))
        XCTAssertEqual(world.toward(from: .peer("mac"), side: .left), .local)
        XCTAssertEqual(world.toward(from: .local, side: .top), .peer("tablet"))
        XCTAssertEqual(world.toward(from: .peer("tablet"), side: .bottom), .local)
        // Nothing that way.
        XCTAssertNil(world.toward(from: .local, side: .left))
        XCTAssertNil(world.toward(from: .peer("pc"), side: .right))
        // A remembered offline device must not block a connected device
        // farther in the same direction.
        XCTAssertEqual(world.toward(from: .local, side: .right, connected: ["pc"]), .peer("pc"))
        XCTAssertNil(world.toward(from: .local, side: .right, connected: []))
    }

    func testAJumpLandsInTheMiddleOfTheNearestDisplay() {
        let world = world(local: [screen(0, 0, 1920, 1080), screen(-1600, 0, 1600, 900)])
        XCTAssertEqual(world.landing(from: .local, to: .peer("mac")), CGPoint(x: 2676, y: 491))
        // Back from the Mac: the right-hand display of this Mac, not the left.
        XCTAssertEqual(world.landing(from: .peer("mac"), to: .local), CGPoint(x: 960, y: 540))
    }

    func testOnlyPeersTouchingThisMacHavePortals() {
        let world = world()
        XCTAssertEqual(world.portals(to: "mac").map(\.side), [.right])
        // The PC sits against the other Mac only.
        XCTAssertTrue(world.portals(to: "pc").isEmpty)
    }

    func testThePointerMovesOnIntoATouchingPeerAndComesHome() throws {
        let world = world()
        let mac = try XCTUnwrap(world.peer("mac"))
        let portal = try XCTUnwrap(world.portals(to: "mac").first)
        var pointer = RemotePointer(
            crossing: portal,
            at: CGPoint(x: 1920, y: 500),
            peer: mac,
            portals: world.portals(to: "mac"),
            neighbors: world.neighbors(of: "mac")
        )
        // Two points inside the Mac's left edge, as the core enters.
        XCTAssertEqual(pointer.position, CGPoint(x: 2, y: 500))

        XCTAssertEqual(pointer.step(by: CGVector(dx: 1000, dy: 0)), .stay)
        // Out through its right edge: into the PC, at this Mac's coordinates.
        XCTAssertEqual(pointer.step(by: CGVector(dx: 600, dy: 0)), .neighbor("pc", CGPoint(x: 3522, y: 500)))
        // The pointer itself stopped at the edge (a PC not connected is a wall).
        XCTAssertEqual(pointer.position, CGPoint(x: 1511, y: 500))

        // Back out through the portal it came in by: home, two points inside.
        XCTAssertEqual(pointer.step(by: CGVector(dx: -1600, dy: 0)), .home(CGPoint(x: 1918, y: 500)))
    }

    func testArrivingFromANeighbourLandsInsideAndRemembersTheEntry() throws {
        let world = world()
        let pc = try XCTUnwrap(world.peer("pc"))
        let entry = try XCTUnwrap(world.portals(to: "mac").first)
        let pointer = RemotePointer(
            arrivingAt: CGPoint(x: 3420, y: 2000),
            peer: pc,
            portals: world.portals(to: "pc"),
            neighbors: world.neighbors(of: "pc"),
            entry: entry
        )
        // Below the PC's display: moved into it.
        XCTAssertEqual(pointer.position, CGPoint(x: 0, y: 1079))
        // Given back without crossing: just inside the edge it first left by.
        XCTAssertEqual(pointer.returnPoint(near: CGPoint(x: 1915, y: 300)), CGPoint(x: 1912, y: 300))
        // By shortcut there is no such edge: the cursor stays where it was.
        let shortcut = RemotePointer(
            arrivingAt: CGPoint(x: 4000, y: 500),
            peer: pc,
            portals: [],
            neighbors: [],
            entry: nil
        )
        XCTAssertEqual(shortcut.returnPoint(near: CGPoint(x: 10, y: 20)), CGPoint(x: 10, y: 20))
    }

    /// The driven peer is placed elsewhere meanwhile (on either device): the
    /// pointer stays where it is on it and comes home through the new edge,
    /// rather than control being given back.
    func testADrivenPeerMovedElsewhereKeepsItsPointer() throws {
        let before = world()
        let mac = try XCTUnwrap(before.peer("mac"))
        let portal = try XCTUnwrap(before.portals(to: "mac").first)
        var pointer = RemotePointer(crossing: portal, at: CGPoint(x: 1920, y: 500), peer: mac,
                                    portals: before.portals(to: "mac"), neighbors: before.neighbors(of: "mac"))
        XCTAssertEqual(pointer.step(by: CGVector(dx: 300, dy: 40)), .stay)
        let position = pointer.position

        // Now on the left of this Mac.
        let after = World(
            local: [screen(0, 0, 1920, 1080)],
            peers: [PlacedPeer(id: "mac", displays: [screen(0, 0, 1512, 982)], offset: Offset(x: -1512, y: 0))]
        )
        let moved = try XCTUnwrap(after.peer("mac"))
        var rearranged = pointer.rearranged(peer: moved, portals: after.portals(to: "mac"),
                                            neighbors: after.neighbors(of: "mac"))
        XCTAssertEqual(rearranged.position, position)
        XCTAssertEqual(rearranged.entry?.side, .left)
        // Out through the Mac's right edge: home, at this Mac's left edge.
        guard case let .home(location) = rearranged.step(by: CGVector(dx: 2000, dy: 0)) else {
            return XCTFail("expected to come home")
        }
        XCTAssertLessThan(location.x, 10)
    }
}

final class HIDKeyMapTests: XCTestCase {
    func testFunctionAndJapaneseKeysMatchTheirHIDUsages() {
        // Events.h kVK_* → USB HID usage. F12 was sent as F14.
        let expected: [CGKeyCode: UInt32] = [
            111: 0x45, 105: 0x46, 107: 0x69, 113: 0x6A, 106: 0x6B,
            10: 0x64, 93: 0x89, 94: 0x87, 102: 0x91, 104: 0x90,
        ]
        for (key, usage) in expected {
            XCTAssertEqual(HIDKeyMap.hidUsage(for: key), usage, "key \(key)")
            XCTAssertEqual(HIDKeyMap.macKeyCode(for: usage), key, "usage \(usage)")
        }
    }
}
