import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class AppModel: RustCoreDelegate {
    private(set) var peers: [Peer] = []
    private(set) var coreState: CoreRunState = .starting
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var isControlling = false
    private(set) var hasAccessibilityPermission = false
    private(set) var sentEventCount = 0
    private(set) var receivedEventCount = 0
    private(set) var lastError: String?
    private(set) var peerPlacements: [String: PeerPlacement]

    let deviceName: String

    private let core = RustCore()
    private let inputBridge = InputBridge()
    private let hud = ControlHUDController()

    init() {
        deviceName = Host.current().localizedName ?? "Mac"
        peerPlacements = Self.loadPeerPlacements()
        core.delegate = self
        inputBridge.send = { [weak self] input in
            guard let self else { return }
            if self.core.send(input) {
                self.sentEventCount += 1
            } else {
                self.lastError = "Rust Core 拒绝了输入事件"
            }
        }
        inputBridge.didRequestRelease = { [weak self] in
            self?.stopControlling()
        }
        inputBridge.didEnterRemoteControl = { [weak self] in
            self?.didEnterRemoteControl()
        }
        startCore()
        refreshPermission()
    }

    func startCore() {
        coreState = .starting
        if core.start(deviceID: Self.deviceID, deviceName: deviceName) {
            coreState = .starting
        } else {
            coreState = .failed("无法启动 Rust Core")
        }
    }

    func connect(to peer: Peer) {
        stopControlling()
        inputBridge.stopMonitoring()
        connectionState = .connecting(peer.id)
        if !core.connect(to: peer.id) {
            connectionState = .disconnected
            lastError = "无法向 Rust Core 发送连接请求"
        }
    }

    func disconnect() {
        stopControlling()
        inputBridge.stopMonitoring()
        core.disconnect()
        connectionState = .disconnected
    }

    func startControlling() {
        guard let peer = connectionState.connectedPeer else { return }
        refreshPermission()
        guard hasAccessibilityPermission else {
            requestPermission()
            return
        }
        guard inputBridge.startCapturing() else {
            lastError = "无法创建系统输入监听，请检查辅助功能权限"
            return
        }
        showRemoteControl(for: peer)
    }

    func stopControlling() {
        if isControlling {
            _ = core.resetInput()
        }
        inputBridge.stopCapturing()
        hud.dismiss()
        isControlling = false
    }

    func placement(for peer: Peer) -> PeerPlacement {
        peerPlacements[peer.id] ?? .disabled
    }

    func setPlacement(_ placement: PeerPlacement, for peer: Peer) {
        peerPlacements[peer.id] = placement
        Self.savePeerPlacements(peerPlacements)

        if connectionState.connectedPeer?.id == peer.id {
            if isControlling {
                stopControlling()
            }
            configureEdgeMonitoring(for: peer)
        } else if placement.isEnabled {
            connect(to: peer)
        }
    }

    func requestPermission() {
        inputBridge.requestAccessibilityPermission()
        refreshPermission()
    }

    func refreshPermission() {
        hasAccessibilityPermission = inputBridge.hasAccessibilityPermission
        if hasAccessibilityPermission, let peer = connectionState.connectedPeer {
            configureEdgeMonitoring(for: peer)
            if lastError?.hasPrefix("设备位置已保存；") == true {
                lastError = nil
            }
        }
    }

    func rustCore(_ core: RustCore, received event: CoreEventEnvelope) {
        switch event.event {
        case "started":
            coreState = .running
        case "stopped":
            coreState = .stopped
        case "peer_up":
            if let peer = event.peer, !peers.contains(where: { $0.id == peer.id }) {
                peers.append(peer)
                peers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                if connectionState == .disconnected, placement(for: peer).isEnabled {
                    connect(to: peer)
                }
            }
        case "peer_down":
            if let peerID = event.peerID {
                peers.removeAll { $0.id == peerID }
            }
        case "connecting":
            if let peerID = event.peerID {
                connectionState = .connecting(peerID)
            }
        case "connected":
            if let peer = event.peer {
                connectionState = .connected(peer)
                configureEdgeMonitoring(for: peer)
            }
        case "disconnected":
            stopControlling()
            inputBridge.stopMonitoring()
            connectionState = .disconnected
            if event.reason != "local request" {
                lastError = event.reason
            }
        case "error":
            lastError = event.message
        default:
            break
        }
    }

    func rustCore(_ core: RustCore, received input: LcInputEvent) {
        inputBridge.inject(input)
        receivedEventCount += 1
    }

    private func configureEdgeMonitoring(for peer: Peer) {
        let placement = placement(for: peer)
        guard inputBridge.configureEdgeMonitoring(for: placement) else {
            if placement.isEnabled {
                lastError = "设备位置已保存；授予辅助功能权限后即可从\(placement.edgeDescription)切换"
            }
            return
        }
    }

    private func didEnterRemoteControl() {
        guard let peer = connectionState.connectedPeer else {
            inputBridge.stopCapturing()
            return
        }
        showRemoteControl(for: peer)
    }

    private func showRemoteControl(for peer: Peer) {
        isControlling = true
        hud.show(peerName: peer.name) { [weak self] in
            self?.stopControlling()
        }
    }

    private static var deviceID: String {
        let key = "linkcursor.device-id"
        if let stored = UserDefaults.standard.string(forKey: key) {
            return stored
        }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    private static let peerPlacementsKey = "linkcursor.peer-placements"

    private static func loadPeerPlacements() -> [String: PeerPlacement] {
        guard let stored = UserDefaults.standard.dictionary(forKey: peerPlacementsKey)
            as? [String: String]
        else {
            return [:]
        }
        return stored.reduce(into: [:]) { result, item in
            if let placement = PeerPlacement(rawValue: item.value) {
                result[item.key] = placement
            }
        }
    }

    private static func savePeerPlacements(_ placements: [String: PeerPlacement]) {
        UserDefaults.standard.set(
            placements.mapValues(\.rawValue),
            forKey: peerPlacementsKey
        )
    }
}
