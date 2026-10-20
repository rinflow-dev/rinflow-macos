import CoreGraphics
import Foundation

struct Peer: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let platform: String?
    let address: String
    let port: UInt16
    /// As announced by the peer, in its own logical space.
    var displays: [Display]?
}

/// The side menu in the UI. The real placement is the core's offset; this is
/// only the side it touches, and choosing one asks the core to place the peer
/// beside that edge.
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

    init(_ side: Side?) {
        self = side.flatMap { PeerPlacement(rawValue: $0.rawValue) } ?? .disabled
    }

    var side: Side? { Side(rawValue: rawValue) }
}

enum CoreRunState: Equatable, Sendable {
    case starting
    case running
    case failed(String)
    case stopped
}

/// One peer this Mac is connecting or connected to. The core keeps a session
/// per peer and several at once.
struct PeerSession: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case connecting
        case connected(Peer)
    }

    var status: Status
    /// The peer is driving this Mac.
    var remoteControl = false

    var peer: Peer? {
        if case let .connected(peer) = status { peer } else { nil }
    }
}

/// What the UI shows as "the" connection: the peer being controlled, else
/// any connected peer, else one being connected.
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
    /// `peer_displays`
    let displays: [Display]?
    /// `placement_changed`; null when the placement was removed.
    let offset: Offset?
    let updatedMs: UInt64?

    enum CodingKeys: String, CodingKey {
        case event
        case peer
        case peerID = "peer_id"
        case reason
        case message
        case displays
        case offset
        case updatedMs = "updated_ms"
    }
}
