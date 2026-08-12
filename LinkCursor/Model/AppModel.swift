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

    let deviceName: String

    private let core = RustCore()
    private let inputBridge = InputBridge()
    private let hud = ControlHUDController()

    init() {
        deviceName = Host.current().localizedName ?? "Mac"
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
        connectionState = .connecting(peer.id)
        if !core.connect(to: peer.id) {
            connectionState = .disconnected
            lastError = "无法向 Rust Core 发送连接请求"
        }
    }

    func disconnect() {
        stopControlling()
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
        isControlling = true
        hud.show(peerName: peer.name) { [weak self] in
            self?.stopControlling()
        }
    }

    func stopControlling() {
        if isControlling {
            _ = core.resetInput()
        }
        inputBridge.stopCapturing()
        hud.dismiss()
        isControlling = false
    }

    func requestPermission() {
        inputBridge.requestAccessibilityPermission()
        refreshPermission()
    }

    func refreshPermission() {
        hasAccessibilityPermission = inputBridge.hasAccessibilityPermission
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
            }
        case "disconnected":
            stopControlling()
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

    private static var deviceID: String {
        let key = "linkcursor.device-id"
        if let stored = UserDefaults.standard.string(forKey: key) {
            return stored
        }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}
