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

    /// Whether a local pointer at `location`, moving by `delta`, pushes
    /// through this portal. The pointer must be within a point of the edge
    /// and moving toward it, so resting against the edge does nothing.
    func isEntered(at location: CGPoint, delta: CGVector) -> Bool {
        switch side {
        case .right:
            delta.dx > 0 && location.x >= line - 1 && (from..<to).contains(location.y)
        case .left:
            delta.dx < 0 && location.x < line + 1 && (from..<to).contains(location.y)
        case .bottom:
            delta.dy > 0 && location.y >= line - 1 && (from..<to).contains(location.x)
        case .top:
            delta.dy < 0 && location.y < line + 1 && (from..<to).contains(location.x)
        }
    }

    /// Where a pointer entering at `location` (local) appears on the peer,
    /// in the peer's space.
    func peerEntry(for location: CGPoint) -> CGPoint {
        peerDisplay.clamp(CGPoint(x: location.x - offset.x, y: location.y - offset.y))
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

    /// A local point just inside this edge, for leaving control without
    /// crossing (release key, disconnect).
    func localInside(near location: CGPoint) -> CGPoint {
        let inset = 8.0
        switch side {
        case .right: return CGPoint(x: line - inset, y: location.y)
        case .left: return CGPoint(x: line + inset, y: location.y)
        case .bottom: return CGPoint(x: location.x, y: line - inset)
        case .top: return CGPoint(x: location.x, y: line + inset)
        }
    }
}

/// The pointer while it drives a peer, tracked in the peer's logical space.
/// The Mac cursor stays frozen meanwhile; this is the only position there is.
struct RemotePointer {
    let peerID: String
    /// Every portal to this peer: the pointer may come back through any.
    let portals: [Portal]
    let displays: [Display]
    let entry: Portal
    private(set) var position: CGPoint

    init(entering portal: Portal, at location: CGPoint, portals: [Portal], displays: [Display]) {
        peerID = portal.peerID
        entry = portal
        self.portals = portals
        self.displays = displays.isEmpty ? [.fallback] : displays
        position = portal.peerEntry(for: location)
    }

    /// Moves by `delta`. Returns the local point to continue at when the
    /// move leaves the peer through a portal; the position is then stale.
    mutating func move(by delta: CGVector) -> CGPoint? {
        let target = CGPoint(x: position.x + delta.dx, y: position.y + delta.dy)
        if displays.contains(where: { $0.contains(target) }) {
            position = target
            return nil
        }
        for portal in portals {
            if let exit = portal.localExit(for: target) {
                return exit
            }
        }
        // Against an edge with nothing beyond it: slide along it, as the
        // peer's own cursor does.
        let current = displays.first { $0.contains(position) } ?? displays[0]
        position = current.clamp(target)
        return nil
    }
}
