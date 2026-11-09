// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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

    /// Incoming connections may identify only the ID and name. Preserve
    /// discovery metadata instead of replacing it with a placeholder.
    func mergingKnown(_ known: Peer?) -> Peer {
        guard let known, known.id == id else { return self }
        return Peer(id: id, name: name, platform: platform ?? known.platform,
                    address: address == "incoming" ? known.address : address, port: port,
                    displays: displays?.isEmpty == false ? displays : known.displays)
    }
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
    /// English, for the log; what to show is `code`'s.
    let reason: String?
    let message: String?
    /// Why it ended, or which error (`reason.rs` in the core); set with
    /// every `reason` and on `error`.
    let reasonCode: CoreReason?
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
        /// Base64 on the wire, decoded with the event (off the main thread).
        let data: Data
    }

    enum CodingKeys: String, CodingKey {
        case event
        case peer
        case peerID = "peer_id"
        case reason
        case message
        case reasonCode = "reason_code"
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

/// A saved list decoded one element at a time: a damaged element is dropped
/// instead of the whole list (every paired device, say).
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element] = []

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                // Steps over the damaged element.
                _ = try? container.decode(Skipped.self)
            }
        }
    }

    private struct Skipped: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    /// The elements saved under `key`, or none.
    static func load(_ key: String, from defaults: UserDefaults = .standard) -> [Element] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode(Self.self, from: data))?.elements ?? []
    }
}

/// The core's `reason_code` for an event's `reason` or an error (`src/reason.rs`
/// in rinflow-core, which lists them all), shown in the user's language.
/// One the core adds later decodes as `other`.
enum CoreReason: String, Decodable, Sendable, CaseIterable {
    // Sessions and pairing.
    case localRequest = "local_request"
    case peerClosed = "peer_closed"
    case peerDisconnected = "peer_disconnected"
    case goingToSleep = "going_to_sleep"
    case coreStopped = "core_stopped"
    case heartbeatTimeout = "heartbeat_timeout"
    case handshakeTimeout = "handshake_timeout"
    case connectionLost = "connection_lost"
    case connectFailed = "connect_failed"
    case peerRefused = "peer_refused"
    case identityChanged = "identity_changed"
    case identityConflict = "identity_conflict"
    case replacedConnection = "replaced_connection"
    case incompatible
    case wrongDevice = "wrong_device"
    case protocolError = "protocol_error"
    case pairingDeclined = "pairing_declined"
    case pairingDeclinedByPeer = "pairing_declined_by_peer"
    case pairingTimedOut = "pairing_timed_out"
    case pairingRequired = "pairing_required"
    case pairingBusy = "pairing_busy"
    case pairingOutdated = "pairing_outdated"
    case pairingFailed = "pairing_failed"
    case unpaired
    // Control.
    case remoteReset = "remote_reset"
    case takenOverByAnotherDevice = "taken_over_by_another_device"
    case takenBackLocally = "taken_back_locally"
    case remoteControlOff = "remote_control_off"
    case takenOver = "taken_over"
    case revoked
    // Files.
    case done
    case cancelled
    case replacedByNewerCopy = "replaced_by_newer_copy"
    case filesGone = "files_gone"
    case tooManyFiles = "too_many_files"
    case tooDeep = "too_deep"
    case fileTimedOut = "file_timed_out"
    case fileCorrupted = "file_corrupted"
    case fileOperationEnded = "file_operation_ended"
    case tooManyFileReads = "too_many_file_reads"
    // Errors.
    case coreStartFailed = "core_start_failed"
    case discoveryUnavailable = "discovery_unavailable"
    case identityUnavailable = "identity_unavailable"
    case controlPortUnavailable = "control_port_unavailable"
    case peerUnavailable = "peer_unavailable"
    case placementFailed = "placement_failed"
    case dataLinkFailed = "data_link_failed"
    case clipboardNotShared = "clipboard_not_shared"
    case clipboardNotReceived = "clipboard_not_received"
    case filesNotShared = "files_not_shared"
    case filesNotReceived = "files_not_received"
    /// Not classified: an I/O error, or a reason newer than this app.
    case other

    init(from decoder: any Decoder) throws {
        self = CoreReason(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }

    /// Where a reason is shown, for the words of one nobody classified.
    enum Context {
        case session, files, error

        var fallback: String {
            switch self {
            case .session: String(localized: "连接已断开。")
            case .files: String(localized: "读写文件时出错。")
            case .error: String(localized: "出现了意外错误，详情见日志。")
            }
        }
    }

    /// What to tell the user, or nil when nothing went wrong: ended here or
    /// on the peer on purpose, for sleep, or replaced by something newer.
    func message(in context: Context) -> String? {
        switch self {
        case .localRequest, .peerClosed, .peerDisconnected, .goingToSleep, .coreStopped,
             .replacedConnection, .pairingDeclined,
             .remoteReset, .takenOverByAnotherDevice, .takenBackLocally, .remoteControlOff, .takenOver, .revoked,
             .done, .cancelled, .replacedByNewerCopy, .filesGone, .fileOperationEnded:
            nil
        case .heartbeatTimeout:
            String(localized: "对方没有响应（可能睡眠了或断网），回来后会自动重新连接。")
        case .handshakeTimeout:
            String(localized: "连接对方时没有完成握手，稍后会自动重试。")
        case .connectionLost:
            String(localized: "连接中断（网络不稳定或对方离线），会自动重新连接。")
        case .connectFailed:
            String(localized: "无法连接到对方：请确认对方在同一网络中，并且正在运行 Rinflow。")
        case .peerRefused:
            String(localized: "对方拒绝了连接：对方可能移除了本机，或只允许已配对的设备。点“连接”可以重新配对。")
        case .identityChanged:
            String(localized: "设备的身份证书变了，已拒绝连接。如果对方重装过，请取消配对后重新配对。")
        case .identityConflict:
            String(localized: "另一台设备使用了相同的设备 ID，已拒绝连接。")
        case .incompatible:
            String(localized: "对方的 Rinflow 版本不兼容，请把两边都更新到最新版本。")
        case .wrongDevice:
            String(localized: "这个地址上应答的是另一台设备。")
        case .protocolError:
            String(localized: "对方发来了无法识别的数据，连接已断开。请把两边都更新到最新版本。")
        case .pairingDeclinedByPeer:
            String(localized: "对方拒绝了配对。")
        case .pairingTimedOut:
            String(localized: "配对超时，没有在两分钟内确认。")
        case .pairingRequired:
            String(localized: "未配对的设备已断开（已开启“仅允许已配对的设备”）。")
        case .pairingBusy:
            String(localized: "正在和另一台设备配对，请完成后再试。")
        case .pairingOutdated:
            String(localized: "对方的 Rinflow 版本太旧，无法配对，请先更新。")
        case .pairingFailed:
            String(localized: "配对失败，请重试。")
        case .unpaired:
            String(localized: "已取消配对。")
        case .tooManyFiles:
            String(localized: "复制的文件太多，文件未共享。请先压缩后再复制。")
        case .tooDeep:
            String(localized: "复制的文件夹层级太深，文件未共享。请先压缩后再复制。")
        case .fileTimedOut:
            String(localized: "读取文件超时，传输已停止。")
        case .fileCorrupted:
            String(localized: "收到的文件数据不完整，传输已停止。")
        case .tooManyFileReads:
            String(localized: "同时读取的文件太多，请稍后再试。")
        case .coreStartFailed:
            String(localized: "无法启动 Rust Core")
        case .discoveryUnavailable:
            String(localized: "无法打开设备发现端口（UDP 42420），可能被其他程序占用。")
        case .identityUnavailable:
            String(localized: "无法读取或创建本机的身份证书。")
        case .controlPortUnavailable:
            String(localized: "无法打开连接端口（42421），可能有另一个 Rinflow 正在运行。")
        case .peerUnavailable:
            String(localized: "这台设备已不在网络上。")
        case .placementFailed:
            String(localized: "无法把设备放在这个位置。")
        case .dataLinkFailed:
            String(localized: "无法建立传输剪贴板和文件的连接。")
        case .clipboardNotShared:
            String(localized: "剪贴板内容无法共享（可能超过 8 MB）。")
        case .clipboardNotReceived:
            String(localized: "没能收到对方的剪贴板。")
        case .filesNotShared:
            String(localized: "复制的文件无法共享。")
        case .filesNotReceived:
            String(localized: "没能接收对方的文件。")
        case .other:
            context.fallback
        }
    }
}
