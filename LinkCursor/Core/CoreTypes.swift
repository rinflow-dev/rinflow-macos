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
/// beside that edge. `chained`: placed against another peer, not this Mac.
enum PeerPlacement: String, Identifiable, Sendable {
    case disabled
    case left
    case right
    case top
    case bottom
    case chained

    /// What the menu offers to choose.
    static let choices: [PeerPlacement] = [.disabled, .left, .right, .top, .bottom]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .disabled: String(localized: "未配置")
        case .left: String(localized: "位于左侧")
        case .right: String(localized: "位于右侧")
        case .top: String(localized: "位于上方")
        case .bottom: String(localized: "位于下方")
        case .chained: String(localized: "接在其他设备旁")
        }
    }

    var edgeDescription: String {
        switch self {
        case .disabled: ""
        case .left: String(localized: "屏幕左边缘")
        case .right: String(localized: "屏幕右边缘")
        case .top: String(localized: "屏幕上边缘")
        case .bottom: String(localized: "屏幕下边缘")
        case .chained: String(localized: "相邻设备的边缘")
        }
    }

    var systemImage: String {
        switch self {
        case .disabled: "rectangle.dashed"
        case .left: "rectangle.leadinghalf.inset.filled"
        case .right: "rectangle.trailinghalf.inset.filled"
        case .top: "rectangle.tophalf.inset.filled"
        case .bottom: "rectangle.bottomhalf.inset.filled"
        case .chained: "rectangle.3.group"
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

/// A peer the user paired, as the core reports it in `paired`.
struct TrustedPeer: Codable, Equatable, Sendable {
    let peerID: String
    let fingerprint: String

    enum CodingKeys: String, CodingKey {
        case peerID = "peer_id"
        case fingerprint
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
    /// `clipboard`
    let formats: [ClipboardFormat]?
    /// `files_*`
    let transfer: UInt32?
    let count: Int?
    /// `files_receiving`, `files_sending`: top-level items.
    let items: Int?
    let totalSize: UInt64?
    let received: UInt64?
    /// `files_sending`
    let sent: UInt64?
    let total: UInt64?
    let paths: [String]?
    /// `manual_addresses`
    let addresses: [ManualAddressStatus]?
    /// `peer_pointer_lock`
    let locked: Bool?
    /// `pairing_requested`
    let code: String?
    let name: String?
    let fingerprint: String?

    struct ClipboardFormat: Decodable, Sendable {
        let mime: String
        /// Base64.
        let data: String
    }

    enum CodingKeys: String, CodingKey {
        case event
        case peer
        case peerID = "peer_id"
        case reason
        case message
        case displays
        case offset
        case updatedMs = "updated_ms"
        case formats
        case transfer
        case count
        case items
        case totalSize = "total_size"
        case received
        case sent
        case total
        case paths
        case addresses
        case locked
        case code
        case name
        case fingerprint
    }
}

/// One address the user added, as the core reports it (`manual_addresses`).
struct ManualAddressStatus: Decodable, Equatable, Sendable, Identifiable {
    enum Status: String, Decodable, Sendable {
        case searching
        case found
        case noResponse = "no_response"
        case unresolved
    }

    let address: String
    let status: Status
    /// `found`: the device at that address.
    let peerID: String?
    let name: String?
    /// `unresolved`: why the name could not be looked up.
    let error: String?

    var id: String { address }

    enum CodingKeys: String, CodingKey {
        case address
        case status
        case peerID = "peer_id"
        case name
        case error
    }
}

/// Files on their way, either way, for the transfer cards.
struct FileTransfer: Identifiable, Equatable, Sendable {
    enum Direction: Equatable, Sendable {
        case receiving
        case sending
    }

    let direction: Direction
    let transfer: UInt32
    let peerID: String?
    var name: String
    /// Top-level items, and files in all.
    var items: Int
    var count: Int
    var done: UInt64
    var total: UInt64

    var id: String { "\(direction == .receiving ? "in" : "out")-\(transfer)" }

    var fraction: Double {
        total > 0 ? min(Double(done) / Double(total), 1) : 0
    }
}
