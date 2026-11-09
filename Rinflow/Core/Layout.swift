// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Foundation

/// One display in logical points within its device's desktop space (the
/// core's `layout::Display`). On the Mac this is the CoreGraphics global
/// space: origin at the top left of the main display, y pointing down.
struct Display: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var scale: Double = 1

    /// What the core assumes for a peer that has not described its displays.
    static let fallback = Display(x: 0, y: 0, width: 1440, height: 900, scale: 1)

    var right: Double { x + width }
    var bottom: Double { y + height }

    func contains(_ point: CGPoint) -> Bool {
        point.x >= x && point.x < right && point.y >= y && point.y < bottom
    }

    /// The nearest point inside the display (at least one point from the
    /// far edges, which are exclusive).
    func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, x), right - 1),
            y: min(max(point.y, y), bottom - 1)
        )
    }
}

extension Display {
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// Bounding box of a desktop; `.null` for no displays.
    static func bounds(of displays: [Display]) -> CGRect {
        displays.reduce(CGRect.null) { $0.union($1.rect) }
    }
}

/// A device on the arrangement canvas.
struct ArrangedDevice: Identifiable, Equatable {
    enum State: Equatable {
        case connected
        /// Discovered but not connected.
        case online
        /// Placed earlier, not on the network now.
        case offline
    }

    let id: String
    let name: String
    let platform: String?
    /// In the device's own space.
    let displays: [Display]
    /// Where it sits in this Mac's space; nil while unplaced.
    let offset: Offset?
    let state: State

    /// Bounding box of its displays, in its own space.
    var bounds: CGRect { Display.bounds(of: displays) }
}

/// Translation from a peer's desktop space into this Mac's space.
struct Offset: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}

/// A placement as the core reports it in `placement_changed`. The shell only
/// stores these and hands them back in the `placements` config key.
struct PlacementRecord: Codable, Equatable, Sendable {
    let peerID: String
    let offset: Offset?
    let updatedMs: UInt64

    enum CodingKeys: String, CodingKey {
        case peerID = "peer_id"
        case offset
        case updatedMs = "updated_ms"
    }
}

enum Side: String, Sendable {
    case left, right, top, bottom
}

/// A stretch of a local display edge that touches a placed peer display.
/// The pointer passes through it point for point: local = peer + offset.
struct Portal: Equatable, Sendable {
    let peerID: String
    let side: Side
    /// x of the edge for left/right, y for top/bottom (local space).
    let line: Double
    /// Extent along the edge (local space), `from..<to`.
    let from: Double
    let to: Double
    let offset: Offset
    /// The peer display on the other side, in the peer's own space.
    let peerDisplay: Display

    private static let touchTolerance = 0.5

    /// Same rules as `layout::portals` in the core.
    static func between(
        local: [Display],
        peer: [Display],
        offset: Offset,
        peerID: String
    ) -> [Portal] {
        let near = { (a: Double, b: Double) in abs(a - b) <= touchTolerance }
        var found: [Portal] = []
        for l in local {
            for original in peer {
                var p = original
                p.x += offset.x
                p.y += offset.y
                let vertical = (max(l.y, p.y), min(l.bottom, p.bottom))
                let horizontal = (max(l.x, p.x), min(l.right, p.right))
                let candidates: [(Bool, Side, Double, (Double, Double))] = [
                    (near(l.right, p.x), .right, l.right, vertical),
                    (near(l.x, p.right), .left, l.x, vertical),
                    (near(l.bottom, p.y), .bottom, l.bottom, horizontal),
                    (near(l.y, p.bottom), .top, l.y, horizontal),
                ]
                for (touching, side, line, (from, to)) in candidates where touching && to - from >= 1 {
                    found.append(Portal(
                        peerID: peerID, side: side, line: line, from: from, to: to,
                        offset: offset, peerDisplay: original
                    ))
                }
            }
        }
        return found
    }

    /// Whether a local pointer at `location` is against this portal: within
    /// a point of the edge and along its extent.
    func touches(_ location: CGPoint) -> Bool {
        switch side {
        case .left, .right: abs(location.x - line) <= 1 && (from..<to).contains(location.y)
        case .top, .bottom: abs(location.y - line) <= 1 && (from..<to).contains(location.x)
        }
    }

    /// How far `delta` moves through this portal's edge (negative: away).
    func outward(_ delta: CGVector) -> Double {
        switch side {
        case .right: delta.dx
        case .left: -delta.dx
        case .bottom: delta.dy
        case .top: -delta.dy
        }
    }

    /// Whether a local pointer at `location`, moving by `delta`, pushes
    /// through this portal.
    func isEntered(at location: CGPoint, delta: CGVector) -> Bool {
        outward(delta) > 0 && touches(location)
    }

    /// Where a pointer entering at `location` (local) appears on the peer,
    /// in the peer's space: two points inside its edge, so a small move back
    /// right after crossing does not bounce straight out again (the same
    /// margin `localExit` leaves on the way back, and `CROSSING_MARGIN` in
    /// the core's `RemotePointer`).
    func peerEntry(for location: CGPoint) -> CGPoint {
        let entry = peerDisplay.clamp(CGPoint(x: location.x - offset.x, y: location.y - offset.y))
        let margin = 2.0
        switch side {
        case .right: return CGPoint(x: min(entry.x + margin, peerDisplay.right - 1), y: entry.y)
        case .left: return CGPoint(x: max(entry.x - margin, peerDisplay.x), y: entry.y)
        case .bottom: return CGPoint(x: entry.x, y: min(entry.y + margin, peerDisplay.bottom - 1))
        case .top: return CGPoint(x: entry.x, y: max(entry.y - margin, peerDisplay.y))
        }
    }

    /// If a peer pointer moving to `point` (peer space) leaves the peer
    /// through this portal, the local point to continue at; otherwise nil.
    func localExit(for point: CGPoint) -> CGPoint? {
        let local = CGPoint(x: point.x + offset.x, y: point.y + offset.y)
        // Land two points inside, so the arrival does not count as a new push.
        let margin = 2.0
        switch side {
        case .right:
            guard local.x < line, (from..<to).contains(local.y) else { return nil }
            return CGPoint(x: line - margin, y: local.y)
        case .left:
            guard local.x >= line, (from..<to).contains(local.y) else { return nil }
            return CGPoint(x: line + margin, y: local.y)
        case .bottom:
            guard local.y < line, (from..<to).contains(local.x) else { return nil }
            return CGPoint(x: local.x, y: line - margin)
        case .top:
            guard local.y >= line, (from..<to).contains(local.x) else { return nil }
            return CGPoint(x: local.x, y: line + margin)
        }
    }

    /// A local point just inside this edge, near `location`, for leaving
    /// control without crossing (release key, disconnect). Kept within the
    /// portal's extent, as the core's `RemotePointer::return_point`.
    func localInside(near location: CGPoint) -> CGPoint {
        let inset = 8.0
        let along = { (value: Double) in max(min(value, to - 1), from) }
        switch side {
        case .right: return CGPoint(x: line - inset, y: along(location.y))
        case .left: return CGPoint(x: line + inset, y: along(location.y))
        case .bottom: return CGPoint(x: along(location.x), y: line - inset)
        case .top: return CGPoint(x: along(location.x), y: line + inset)
        }
    }
}

extension Display {
    func translated(by offset: Offset) -> Display {
        Display(x: x + offset.x, y: y + offset.y, width: width, height: height, scale: scale)
    }

    var centre: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }
}

/// A placed peer: its displays in its own space, and the offset that puts
/// them into this Mac's space.
struct PlacedPeer: Equatable, Sendable {
    let id: String
    /// Never empty: the core's default size until the peer describes them.
    let displays: [Display]
    let offset: Offset

    init(id: String, displays: [Display], offset: Offset) {
        self.id = id
        self.displays = displays.isEmpty ? [.fallback] : displays
        self.offset = offset
    }

    /// Its displays in this Mac's space.
    var placed: [Display] { displays.map { $0.translated(by: offset) } }
}

/// One of the devices of an arrangement: this Mac or a placed peer.
enum Device: Hashable, Sendable {
    case local
    case peer(String)
}

/// This Mac and every placed peer, in this Mac's space: what crossing,
/// moving on between peers (chained placements) and the switch shortcuts
/// go by. The port of the Windows agent's `World` and the core's
/// `RemotePointer` neighbours.
struct World: Equatable, Sendable {
    var local: [Display] = []
    /// By device ID, as the core orders them.
    var peers: [PlacedPeer] = []

    func peer(_ id: String) -> PlacedPeer? {
        peers.first { $0.id == id }
    }

    /// The portals between this Mac and the peer; none for a peer placed
    /// against another peer only.
    func portals(to id: String) -> [Portal] {
        guard let peer = peer(id) else { return [] }
        return Portal.between(local: local, peer: peer.displays, offset: peer.offset, peerID: id)
    }

    /// The pointer on `id` may move on into these.
    func neighbors(of id: String) -> [PlacedPeer] {
        peers.filter { $0.id != id }
    }

    private func displays(of device: Device) -> [Display]? {
        switch device {
        case .local: local
        case let .peer(id): peer(id)?.placed
        }
    }

    /// The device next to `from` toward `side`: the nearest whose middle
    /// lies that way, more that way than sideways.
    func toward(from: Device, side: Side, connected: Set<String>? = nil) -> Device? {
        guard let current = displays(of: from).map(Display.bounds(of:)), !current.isNull else {
            return nil
        }
        let candidates = [Device.local] + peers.map { Device.peer($0.id) }
        var best: (score: Double, device: Device)?
        for device in candidates where device != from {
            if case let .peer(id) = device, let connected, !connected.contains(id) { continue }
            guard let bounds = displays(of: device).map(Display.bounds(of:)), !bounds.isNull else {
                continue
            }
            let (dx, dy) = (bounds.midX - current.midX, bounds.midY - current.midY)
            let (along, across): (Double, Double) = switch side {
            case .right: (dx, dy)
            case .left: (-dx, dy)
            case .bottom: (dy, dx)
            case .top: (-dy, dx)
            }
            guard along > 1, abs(across) <= along * 2 else { continue }
            let score = along + 2 * abs(across)
            if best.map({ score < $0.score }) ?? true {
                best = (score, device)
            }
        }
        return best?.device
    }

    /// Where the pointer lands when it jumps from `from` to `to`: the middle
    /// of the display of `to` nearest to `from`.
    func landing(from: Device, to: Device) -> CGPoint? {
        guard let source = displays(of: from).map(Display.bounds(of:)), !source.isNull,
              let targets = displays(of: to)
        else {
            return nil
        }
        let origin = CGPoint(x: source.midX, y: source.midY)
        return targets.map(\.centre).min {
            hypot($0.x - origin.x, $0.y - origin.y) < hypot($1.x - origin.x, $1.y - origin.y)
        }
    }
}

/// The pointer while it drives a peer, tracked in the peer's logical space:
/// the port of the core's `layout::RemotePointer`. The Mac cursor stays
/// parked meanwhile; this is the only position there is.
struct RemotePointer {
    /// Where a move took the pointer.
    enum Motion: Equatable {
        /// Still on the peer.
        case stay
        /// Back on this Mac, continuing at this local point.
        case home(CGPoint)
        /// Into another placed peer that touches this one, at this local
        /// point. The pointer itself stopped at the edge, so not moving on
        /// simply leaves an edge there.
        case neighbor(String, CGPoint)
    }

    let peer: PlacedPeer
    /// Every portal to this peer: the pointer may come back through any.
    let portals: [Portal]
    /// Where the pointer first left this Mac, for giving control back
    /// without crossing; nil when it came by shortcut.
    let entry: Portal?
    let neighbors: [PlacedPeer]
    private(set) var position: CGPoint

    var peerID: String { peer.id }

    /// Crosses through `portal` from the local point `location` on its edge.
    init(crossing portal: Portal, at location: CGPoint, peer: PlacedPeer, portals: [Portal], neighbors: [PlacedPeer]) {
        self.peer = peer
        self.portals = portals
        self.neighbors = neighbors
        entry = portal
        position = portal.peerEntry(for: location)
    }

    /// Arrives at the local point `location`, from another peer (`entry` is
    /// where the pointer first left this Mac) or by shortcut (none). The
    /// point is moved into the nearest of the peer's displays.
    init(arrivingAt location: CGPoint, peer: PlacedPeer, portals: [Portal], neighbors: [PlacedPeer], entry: Portal?) {
        self.peer = peer
        self.portals = portals
        self.neighbors = neighbors
        self.entry = entry
        let point = CGPoint(x: location.x - peer.offset.x, y: location.y - peer.offset.y)
        let distance = { (display: Display) -> Double in
            let clamped = display.clamp(point)
            return hypot(clamped.x - point.x, clamped.y - point.y)
        }
        let nearest = peer.displays.min { distance($0) < distance($1) } ?? peer.displays[0]
        position = nearest.clamp(point)
    }

    /// The same pointer against a changed arrangement (displays rearranged
    /// on either side, a placement refitted): it stays where it is on its
    /// peer, moved into the nearest display if that one is gone. The entry
    /// becomes the new portal on the same side, if any.
    func rebased(onto peer: PlacedPeer, portals: [Portal], neighbors: [PlacedPeer]) -> RemotePointer {
        let entry = entry.flatMap { old in portals.first { $0.side == old.side } ?? portals.first }
        let local = CGPoint(x: position.x + peer.offset.x, y: position.y + peer.offset.y)
        return RemotePointer(arrivingAt: local, peer: peer, portals: portals, neighbors: neighbors, entry: entry)
    }

    /// Where the pointer is, in this Mac's space.
    var localPosition: CGPoint {
        CGPoint(x: position.x + peer.offset.x, y: position.y + peer.offset.y)
    }

    /// Moves by `delta`: within the peer, back to this Mac through a portal,
    /// or on into a neighbouring peer.
    mutating func step(by delta: CGVector, allowCrossing: Bool = true) -> Motion {
        let target = CGPoint(x: position.x + delta.dx, y: position.y + delta.dy)
        if peer.displays.contains(where: { $0.contains(target) }) {
            position = target
            return .stay
        }
        for portal in portals where allowCrossing {
            if let exit = portal.localExit(for: target) {
                return .home(exit)
            }
        }
        let local = CGPoint(x: target.x + peer.offset.x, y: target.y + peer.offset.y)
        let neighbor = allowCrossing ? neighbors.first { $0.placed.contains { $0.contains(local) } } : nil
        // Against an edge: slide along it, as the peer's own cursor does.
        let current = peer.displays.first { $0.contains(position) } ?? peer.displays[0]
        position = current.clamp(target)
        return neighbor.map { .neighbor($0.id, local) } ?? .stay
    }

    /// Where the cursor comes back when control is given back without
    /// crossing: just inside the edge it left through, near `location`;
    /// `location` itself when it came by shortcut.
    func returnPoint(near location: CGPoint) -> CGPoint {
        entry?.localInside(near: location) ?? location
    }
}
