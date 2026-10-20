import AppKit
import Foundation
import Observation
import OSLog

@Observable
@MainActor
final class AppModel: RustCoreDelegate {
    private(set) var peers: [Peer] = []
    private(set) var coreState: CoreRunState = .starting
    /// One entry per peer the core is connecting or connected to.
    private(set) var sessions: [String: PeerSession] = [:]
    /// The peer this Mac's keyboard and mouse currently drive.
    private(set) var controlledPeerID: String?
    private(set) var hasAccessibilityPermission = false
    private(set) var sentEventCount = 0
    private(set) var receivedEventCount = 0
    private(set) var lastError: String?
    /// The core's placements, saved as it reports them and handed back to it
    /// at start-up. The core owns them; the Mac never edits one directly.
    private(set) var placements: [String: PlacementRecord]
    /// Every device seen, with its last known name, platform and displays,
    /// so placed devices keep their place on the canvas while offline.
    private(set) var knownPeers: [String: Peer]
    private(set) var localDisplays: [Display] = []

    let deviceName: String

    private let core = RustCore()
    private let inputBridge = InputBridge()
    private let hud = ControlHUDController()
    private var reconnectTimer: Timer?
    private static let log = Logger(subsystem: "com.linkcursor.mac", category: "model")

    var isControlling: Bool { controlledPeerID != nil }

    /// A single connection for the UI, which still shows one.
    var connectionState: ConnectionState {
        if let id = controlledPeerID, let peer = sessions[id]?.peer {
            return .connected(peer)
        }
        let ordered = sessions.sorted { $0.key < $1.key }
        if let peer = ordered.lazy.compactMap(\.value.peer).first {
            return .connected(peer)
        }
        if let id = ordered.first?.key {
            return .connecting(id)
        }
        return .disconnected
    }

    init() {
        deviceName = Host.current().localizedName ?? "Mac"
        placements = Self.loadPlacements()
        knownPeers = Self.loadKnownPeers()
        core.delegate = self
        inputBridge.send = { [weak self] input in
            guard let self else { return }
            if self.core.send(input) {
                self.sentEventCount += 1
            } else {
                self.lastError = "Rust Core 拒绝了输入事件"
            }
        }
        inputBridge.didChangeTarget = { [weak self] peerID in
            self?.controlTargetChanged(peerID)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.connectPlacedPeers() }
        }
        startCore()
        refreshPermission()
    }

    func startCore() {
        coreState = .starting
        localDisplays = Self.currentDisplays()
        guard core.start(
            deviceID: Self.deviceID,
            deviceName: deviceName,
            displays: localDisplays,
            placements: Array(placements.values)
        ) else {
            coreState = .failed("无法启动 Rust Core")
            return
        }
        migrateLegacyPlacements()
    }

    func connect(to peer: Peer) {
        if sessions[peer.id] == nil {
            sessions[peer.id] = PeerSession(status: .connecting)
        }
        if !core.connect(to: peer.id) {
            sessions[peer.id] = nil
            lastError = "无法向 Rust Core 发送连接请求"
        }
    }

    func disconnect(_ peer: Peer) {
        core.disconnect(peerID: peer.id)
    }

    func stopControlling() {
        inputBridge.stopCapturing()
    }

    func placement(for peer: Peer) -> PeerPlacement {
        PeerPlacement(portals(for: peer.id).first?.side)
    }

    /// What the arrangement canvas draws: discovered devices and placed ones,
    /// online or not.
    var arrangedDevices: [ArrangedDevice] {
        let online = Set(peers.map(\.id))
        let placed = placements.values.filter { $0.offset != nil }.map(\.peerID)
        return online.union(placed).sorted().map { id in
            let peer = peers.first { $0.id == id } ?? knownPeers[id]
            let state: ArrangedDevice.State =
                sessions[id]?.peer != nil ? .connected : online.contains(id) ? .online : .offline
            return ArrangedDevice(
                id: id,
                name: peer?.name ?? String(id.prefix(8)),
                platform: peer?.platform,
                displays: layout(of: id),
                offset: placements[id]?.offset,
                state: state
            )
        }
    }

    /// Proposes a spot for the peer (nil removes its placement). The core
    /// snaps it, syncs it and reports the result as `placement_changed`.
    func place(_ peerID: String, at offset: Offset?) {
        core.place(peerID, at: offset)
    }

    /// Asks the core to place the peer beside an edge (or remove it); the
    /// outcome arrives as `placement_changed`.
    func setPlacement(_ placement: PeerPlacement, for peer: Peer) {
        core.place(peer.id, beside: placement.side)
        if placement.isEnabled, sessions[peer.id] == nil {
            connect(to: peer)
        }
    }

    func requestPermission() {
        inputBridge.requestAccessibilityPermission()
        refreshPermission()
    }

    func refreshPermission() {
        hasAccessibilityPermission = inputBridge.hasAccessibilityPermission
        if hasAccessibilityPermission {
            if lastError?.hasPrefix("设备位置已保存；") == true {
                lastError = nil
            }
            refreshPortals()
        }
    }

    func rustCore(_ core: RustCore, received event: CoreEventEnvelope) {
        switch event.event {
        case "started":
            coreState = .running
        case "stopped":
            coreState = .stopped
        case "peer_up":
            guard let peer = event.peer else { break }
            peers.removeAll { $0.id == peer.id }
            peers.append(peer)
            peers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            remember(peer)
            connectPlacedPeers()
        case "peer_down":
            if let peerID = event.peerID {
                peers.removeAll { $0.id == peerID }
            }
        case "connecting":
            if let peerID = event.peerID, sessions[peerID] == nil {
                sessions[peerID] = PeerSession(status: .connecting)
            }
        case "connected":
            guard let peer = event.peer else { break }
            sessions[peer.id, default: PeerSession(status: .connecting)].status = .connected(peer)
            lastError = nil
            refreshPortals()
        case "disconnected":
            // Sessions are per peer; one without a peer ID concerns none.
            guard let peerID = event.peerID else { break }
            let name = sessions[peerID]?.peer?.name ?? peerID
            sessions[peerID] = nil
            refreshPortals()
            if let reason = event.reason, reason != "local request" {
                lastError = "\(name)：\(reason)"
            }
        case "remote_control_started", "remote_control_ended":
            if let peerID = event.peerID {
                sessions[peerID]?.remoteControl = event.event == "remote_control_started"
            }
        case "peer_displays":
            guard let peerID = event.peerID, let displays = event.displays,
                  var peer = knownPeers[peerID] ?? peers.first(where: { $0.id == peerID })
            else {
                break
            }
            peer.displays = displays
            remember(peer)
            refreshPortals()
        case "placement_changed":
            guard let peerID = event.peerID, let updatedMs = event.updatedMs else { break }
            placements[peerID] = PlacementRecord(
                peerID: peerID,
                offset: event.offset,
                updatedMs: updatedMs
            )
            Self.savePlacements(placements)
            refreshPortals()
            connectPlacedPeers()
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

    /// A placed peer is meant to be one push away, so its session is kept
    /// open: opened when it appears or is placed, and reopened (by the timer)
    /// when it drops while the peer is still around. Not while this Mac is
    /// driving a peer: `connect` also moves the input target.
    private func connectPlacedPeers() {
        guard controlledPeerID == nil else { return }
        for peer in peers where placements[peer.id]?.offset != nil && sessions[peer.id] == nil {
            Self.log.info("connecting placed peer \(peer.id, privacy: .public)")
            connect(to: peer)
        }
    }

    /// Called synchronously from the event tap, so the target is set before
    /// the first event for it is queued.
    private func controlTargetChanged(_ peerID: String?) {
        if let peerID {
            core.setInputTarget(peerID)
        } else {
            // Releases whatever the peer still holds and ends its control.
            core.resetInput()
        }
        controlledPeerID = peerID
        // Window work stays out of the event tap callback.
        Task { @MainActor [weak self] in self?.updateHUD() }
    }

    private func updateHUD() {
        guard let peerID = controlledPeerID else {
            hud.dismiss()
            return
        }
        let name = sessions[peerID]?.peer?.name
            ?? peers.first { $0.id == peerID }?.name
            ?? peerID
        hud.show(peerName: name) { [weak self] in self?.stopControlling() }
    }

    private func screensChanged() {
        localDisplays = Self.currentDisplays()
        core.setLocalDisplays(localDisplays)
        refreshPortals()
    }

    /// The peer's displays as last described, or the core's default.
    private func layout(of peerID: String) -> [Display] {
        let displays = knownPeers[peerID]?.displays ?? []
        return displays.isEmpty ? [.fallback] : displays
    }

    private func remember(_ peer: Peer) {
        var peer = peer
        if peer.displays?.isEmpty ?? true {
            peer.displays = knownPeers[peer.id]?.displays
        }
        guard knownPeers[peer.id] != peer else { return }
        knownPeers[peer.id] = peer
        guard let data = try? JSONEncoder().encode(Array(knownPeers.values)) else { return }
        UserDefaults.standard.set(data, forKey: Self.knownPeersKey)
    }

    private static let knownPeersKey = "linkcursor.known-peers"

    private static func loadKnownPeers() -> [String: Peer] {
        guard
            let data = UserDefaults.standard.data(forKey: knownPeersKey),
            let peers = try? JSONDecoder().decode([Peer].self, from: data)
        else {
            return [:]
        }
        return Dictionary(peers.map { ($0.id, $0) }) { _, latest in latest }
    }

    private func portals(for peerID: String) -> [Portal] {
        guard let offset = placements[peerID]?.offset else { return [] }
        return Portal.between(
            local: localDisplays,
            peer: layout(of: peerID),
            offset: offset,
            peerID: peerID
        )
    }

    /// Hands the edges of every connected, placed peer to the input bridge.
    private func refreshPortals() {
        let connected = sessions.filter { $0.value.peer != nil }.keys.sorted()
        let portals = connected.flatMap(portals(for:))
        let displays = Dictionary(uniqueKeysWithValues: connected.map { ($0, layout(of: $0)) })
        if !inputBridge.setPortals(portals, peerDisplays: displays) {
            lastError = "设备位置已保存；授予辅助功能权限后即可从屏幕边缘切换"
        }
        for portal in portals {
            Self.log.info(
                "portal \(portal.peerID, privacy: .public) \(portal.side.rawValue, privacy: .public) line=\(portal.line) \(portal.from)..<\(portal.to) offset=(\(portal.offset.x), \(portal.offset.y))"
            )
        }
    }

    /// This Mac's displays in the CoreGraphics global space (points, origin
    /// at the top left of the main display, y down), as the core expects.
    private static func currentDisplays() -> [Display] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber
            else {
                return nil
            }
            let bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            return Display(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width,
                height: bounds.height,
                scale: screen.backingScaleFactor
            )
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

    private static let placementsKey = "linkcursor.placements"

    private static func loadPlacements() -> [String: PlacementRecord] {
        guard
            let data = UserDefaults.standard.data(forKey: placementsKey),
            let records = try? JSONDecoder().decode([PlacementRecord].self, from: data)
        else {
            return [:]
        }
        return Dictionary(records.map { ($0.peerID, $0) }) { _, latest in latest }
    }

    private static func savePlacements(_ placements: [String: PlacementRecord]) {
        guard let data = try? JSONEncoder().encode(Array(placements.values)) else { return }
        UserDefaults.standard.set(data, forKey: placementsKey)
    }

    /// Earlier builds saved only a side per peer. Hand those to the core
    /// once; it turns each into a real placement.
    private func migrateLegacyPlacements() {
        let legacyKey = "linkcursor.peer-placements"
        guard let legacy = UserDefaults.standard.dictionary(forKey: legacyKey) as? [String: String]
        else {
            return
        }
        for (peerID, value) in legacy where placements[peerID] == nil {
            if let side = Side(rawValue: value) {
                core.place(peerID, beside: side)
            }
        }
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }
}
