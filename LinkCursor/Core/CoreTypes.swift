import Foundation

struct Peer: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let address: String
    let port: UInt16
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

