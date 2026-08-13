import CoreGraphics
import Foundation

struct Peer: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let platform: String?
    let address: String
    let port: UInt16
}

enum PeerPlacement: String, CaseIterable, Identifiable, Sendable {
    case disabled
    case left
    case right
    case top
    case bottom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .disabled: "未配置"
        case .left: "位于左侧"
        case .right: "位于右侧"
        case .top: "位于上方"
        case .bottom: "位于下方"
        }
    }

    var edgeDescription: String {
        switch self {
        case .disabled: ""
        case .left: "屏幕左边缘"
        case .right: "屏幕右边缘"
        case .top: "屏幕上边缘"
        case .bottom: "屏幕下边缘"
        }
    }

    var systemImage: String {
        switch self {
        case .disabled: "rectangle.dashed"
        case .left: "rectangle.leadinghalf.inset.filled"
        case .right: "rectangle.trailinghalf.inset.filled"
        case .top: "rectangle.tophalf.inset.filled"
        case .bottom: "rectangle.bottomhalf.inset.filled"
        }
    }

    var isEnabled: Bool { self != .disabled }
}

struct EdgeSwitchPolicy {
    static func shouldEnter(
        placement: PeerPlacement,
        location: CGPoint,
        desktopBounds: CGRect,
        jumpZoneSize: CGFloat = 1
    ) -> Bool {
        switch placement {
        case .left:
            location.x < desktopBounds.minX + jumpZoneSize
        case .right:
            location.x >= desktopBounds.maxX - jumpZoneSize
        case .top:
            location.y < desktopBounds.minY + jumpZoneSize
        case .bottom:
            location.y >= desktopBounds.maxY - jumpZoneSize
        case .disabled:
            false
        }
    }
}

enum CoreRunState: Equatable, Sendable {
    case starting
    case running
    case failed(String)
    case stopped
}

enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting(String)
    case connected(Peer)

    var connectedPeer: Peer? {
        if case let .connected(peer) = self {
            peer
        } else {
            nil
        }
    }
}

struct CoreEventEnvelope: Decodable, Sendable {
    let event: String
    let peer: Peer?
    let peerID: String?
    let reason: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case event
        case peer
        case peerID = "peer_id"
        case reason
        case message
    }
}
