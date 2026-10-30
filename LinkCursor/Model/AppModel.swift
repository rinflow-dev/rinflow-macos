import AppKit
import Foundation
import Network
import Observation
import OSLog
import ServiceManagement

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
    /// Files on their way, either way.
    private(set) var transfers: [FileTransfer] = []
    /// The addresses the user added, as the core reports them.
    private(set) var manualAddressStatus: [ManualAddressStatus] = []
    /// Another program holds the switch shortcuts' combination.
    private(set) var switchHotkeysBlocked = false
    private(set) var settings: AppSettings
    /// Peers the user paired, saved from `paired` and handed to the core.
    private(set) var trustedPeers: [String: TrustedPeer]
    /// The core's placements, saved as it reports them and handed back to it
    /// at start-up. The core owns them; the Mac never edits one directly.
    private(set) var placements: [String: PlacementRecord]
    /// Every device seen, with its last known name, platform and displays,
    /// so placed devices keep their place on the canvas while offline.
    private(set) var knownPeers: [String: Peer]
    private(set) var localDisplays: [Display] = []
    private(set) var loginStatus = SMAppService.mainApp.status
    private(set) var pointerLocked = false

    let deviceName: String

    private let core = RustCore()
    private let inputBridge = InputBridge()
    private let player = InputPlayer()
    private let hud = ControlHUDController()
    private let clipboard = ClipboardBridge()
    private let pairing = PairingPrompt()
    private let hotkeys = SwitchHotkeys()
    private let presence = Presence()
    private let cursorHider = CursorHider()
    private let notifications = TransferNotifications()
    private let fullscreen = FullscreenMonitor()
    /// Reports network changes to the core (Wi-Fi, addresses, VPN).
    private let pathMonitor = NWPathMonitor()
    /// Network changes come in bursts; the core hears of them once settled.
    private var pendingNetworkChange: DispatchWorkItem?
    private var shuttingDown = false
    private static let log = Logger(subsystem: "com.linkcursor.mac", category: "model")

    var isControlling: Bool { controlledPeerID != nil }

    /// Discovery expires independently of sessions. Keep connected and paired
    /// devices visible so an offline device can still be unpaired or arranged.
    var visiblePeers: [Peer] {
        let ids = Set(peers.map(\.id)).union(sessions.keys).union(trustedPeers.keys)
        return ids.compactMap { id in
            peers.first { $0.id == id } ?? knownPeers[id] ?? sessions[id]?.peer
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

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
        settings = AppSettings.load()
        placements = Self.loadPlacements()
        knownPeers = Self.loadKnownPeers()
        trustedPeers = Self.loadTrustedPeers()
        core.delegate = self
        inputBridge.send = { [weak self] input in
            guard let self else { return }
            if self.core.send(input) {
                self.sentEventCount += 1
            } else {
                self.lastError = String(localized: "Rust Core 拒绝了输入事件")
            }
        }
        inputBridge.didChangeTarget = { [weak self] peerID in
            self?.controlTargetChanged(peerID)
        }
        inputBridge.inputFor = { [weak self] peerID in
            self?.settings.input(for: peerID) ?? PeerInput()
        }
        clipboard.didChange = { [weak self] items in
            self?.core.setClipboard(items)
        }
        inputBridge.willEnter = { [weak self] in
            // The cursor a peer left hidden here is this capture's to hide now.
            self?.cursorHider.reveal()
            self?.clipboard.reportIfChanged()
        }
        player.pointerLockChanged = { [weak self] locked in
            self?.core.setPointerLocked(locked)
        }
        hotkeys.pressed = { [weak self] side in
            self?.inputBridge.jumpFromHere(toward: side)
        }
        hotkeys.togglePointerLock = { [weak self] in self?.togglePointerLock() }
        inputBridge.togglePointerLock = { [weak self] in self?.togglePointerLock() }
        fullscreen.changed = { [weak self] in self?.inputBridge.fullscreenBlocked = $0 }
        presence.reportActivity = { [weak self] in self?.core.reportUserActivity() }
        presence.lockPeers = { [weak self] in self?.core.lockPeers() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        // Locked or switched away: the tap no longer sees the keyboard (the
        // login window has secure input), so give the pointer back here.
        for (center, name) in [
            (DistributedNotificationCenter.default() as NotificationCenter,
             Notification.Name("com.apple.screenIsLocked")),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification),
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.inputBridge.stopCapturing() }
            }
        }
        observePowerAndNetwork()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        applySettings(settings, previous: nil)
        presence.start()
        startCore()
        refreshPermission()
    }

    func startCore() {
        // A failed start can still own a handle whose Rust thread exited.
        clipboard.stop()
        inputBridge.stop()
        player.releaseAll()
        core.stop()
        sessions.removeAll()
        peers.removeAll()
        transfers.removeAll()
        pairing.dismissAll()
        lastError = nil
        coreState = .starting
        localDisplays = Self.currentDisplays()
        guard core.start(
            deviceID: Self.deviceID,
            deviceName: deviceName,
            displays: localDisplays,
            placements: Array(placements.values),
            trustedPeers: Array(trustedPeers.values),
            settings: settings
        ) else {
            coreState = .failed(String(localized: "无法启动 Rust Core"))
            return
        }
        migrateLegacyPlacements()
        core.setRemoteControlAllowed(settings.sharing && inputBridge.hasAccessibilityPermission)
        if settings.clipboard { clipboard.start() }
    }

    func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        pendingNetworkChange?.cancel()
        pathMonitor.cancel()
        clipboard.stop()
        pairing.dismissAll()
        inputBridge.stop()
        _ = hotkeys.register(nil)
        cursorHider.reveal()
        player.releaseAll()
        presence.stop()
        fullscreen.setEnabled(false)
        core.stop()
    }

    func togglePointerLock() {
        pointerLocked.toggle()
        inputBridge.crossingLocked = pointerLocked
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = String(localized: "无法更改登录启动：\(error.localizedDescription)")
        }
        loginStatus = SMAppService.mainApp.status
    }

    func openLoginSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Settings

    /// Changes the settings, saves them and applies what changed at once.
    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let previous = settings
        settings = next
        next.save()
        applySettings(next, previous: previous)
    }

    private func applySettings(_ settings: AppSettings, previous: AppSettings?) {
        if settings.pauseInFullscreen != previous?.pauseInFullscreen || settings.sharing != previous?.sharing {
            fullscreen.setEnabled(settings.pauseInFullscreen && settings.sharing)
        }
        if settings.clipboard, previous?.clipboard != true { notifications.start() }
        if settings.switchDelay != previous?.switchDelay || settings.cornerGuard != previous?.cornerGuard {
            inputBridge.setCrossingOptions(delay: settings.switchDelay, cornerGuard: settings.cornerGuard)
        }
        if let previous, settings.clipboard != previous.clipboard {
            if settings.clipboard {
                clipboard.start()
            } else {
                clipboard.stop()
                pairing.dismissFiles()
                core.setClipboard([])
                for transfer in transfers { core.cancelFiles(transfer.transfer) }
            }
        }
        if let previous, settings.sharing != previous.sharing {
            if !settings.sharing {
                inputBridge.stop()
                cursorHider.reveal()
                player.releaseAll()
            }
            core.setRemoteControlAllowed(settings.sharing && hasAccessibilityPermission)
            refreshArrangement()
        }
        if previous != nil {
            // At start-up these go into the core's configuration.
            if settings.pairedOnly != previous?.pairedOnly {
                core.setRequirePairing(settings.pairedOnly)
            }
            if settings.shortcutRemap != previous?.shortcutRemap {
                core.setShortcutRemap(settings.shortcutRemap)
            }
            if settings.manualAddresses != previous?.manualAddresses {
                core.setManualAddresses(settings.manualAddresses)
            }
        }
        if settings.switchHotkeys != previous?.switchHotkeys
            || settings.switchModifiers != previous?.switchModifiers
            || settings.sharing != previous?.sharing
        {
            let modifiers = settings.switchHotkeys && settings.sharing ? settings.switchModifiers : nil
            switchHotkeysBlocked = !hotkeys.register(modifiers, lockEnabled: settings.sharing)
            inputBridge.setSwitchShortcuts(modifiers)
        }
        if settings.language != previous?.language {
            settings.language.apply()
        }
        if !settings.hideCursorOnLeave {
            cursorHider.reveal()
        }
        presence.keepAwake = settings.keepAwake
        presence.lockSync = settings.lockSync
    }

    /// Adds an address to look for devices at; a message when it cannot be.
    func addManualAddress(_ text: String) -> String? {
        if let problem = ManualAddress.problem(with: text, existing: settings.manualAddresses) {
            return problem
        }
        let address = text.trimmingCharacters(in: .whitespaces)
        updateSettings { $0.manualAddresses.append(address) }
        return nil
    }

    func removeManualAddress(_ address: String) {
        updateSettings { $0.manualAddresses.removeAll { $0 == address } }
    }

    func setInput(_ input: PeerInput, for peerID: String) {
        updateSettings { $0.peerInput[peerID] = input.isDefault ? nil : input }
        inputBridge.refreshInputSettings()
    }

    /// What the UI shows for an address: the core's report, or searching.
    func status(of address: String) -> ManualAddressStatus {
        manualAddressStatus.first { $0.address == address }
            ?? ManualAddressStatus(address: address, status: .searching, peerID: nil, name: nil, error: nil)
    }

    // MARK: - Devices

    func connect(to peer: Peer) {
        if sessions[peer.id] == nil {
            sessions[peer.id] = PeerSession(status: .connecting)
        }
        if !core.connect(to: peer.id) {
            sessions[peer.id] = nil
            lastError = String(localized: "无法向 Rust Core 发送连接请求")
        }
    }

    func disconnect(_ peer: Peer) {
        core.disconnect(peerID: peer.id)
    }

    func stopControlling() {
        inputBridge.stopCapturing()
    }

    func cancelTransfer(_ transfer: FileTransfer) {
        core.cancelFiles(transfer.transfer)
    }

    func placement(for peer: Peer) -> PeerPlacement {
        if let side = world.portals(to: peer.id).first?.side {
            return PeerPlacement(side)
        }
        // Placed against another peer only.
        return placements[peer.id]?.offset != nil ? .chained : .disabled
    }

    /// What the arrangement canvas draws: discovered devices and placed ones,
    /// online or not.
    var arrangedDevices: [ArrangedDevice] {
        let online = Set(peers.map(\.id))
        let placed = placements.values.filter { $0.offset != nil }.map(\.peerID)
        return online.union(placed).union(sessions.keys).sorted().map { id in
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
        guard placement != .chained else { return }
        core.place(peer.id, beside: placement.side)
        if placement.isEnabled, sessions[peer.id] == nil, peers.contains(where: { $0.id == peer.id }) {
            connect(to: peer)
        }
    }

    func requestPermission() {
        inputBridge.requestAccessibilityPermission()
        refreshPermission()
    }

    func refreshPermission() {
        loginStatus = SMAppService.mainApp.status
        hasAccessibilityPermission = inputBridge.hasAccessibilityPermission
        core.setRemoteControlAllowed(settings.sharing && hasAccessibilityPermission)
        if hasAccessibilityPermission {
            if lastError == Self.permissionNeeded {
                lastError = nil
            }
            refreshArrangement()
        } else {
            inputBridge.stop()
            cursorHider.reveal()
            player.releaseAll()
        }
    }

    func isPaired(_ peer: Peer) -> Bool {
        trustedPeers[peer.id] != nil
    }

    /// Forgets a paired peer; with pairing required it must pair again.
    func unpair(_ peer: Peer) {
        core.unpair(peer.id)
    }

    func dismissError() {
        lastError = nil
    }

    // MARK: - Core events

    func rustCore(_ core: RustCore, received event: CoreEventEnvelope) {
        guard !shuttingDown else { return }
        switch event.event {
        case "started":
            coreState = .running
        case "stopped":
            // A failed start sends `error`, then `stopped`: keep the failure
            // (and its Retry button) on screen.
            if case .failed = coreState {} else { coreState = .stopped }
            inputBridge.stop()
            player.releaseAll()
            sessions.removeAll()
            transfers.removeAll()
            pairing.dismissAll()
            updateDriven()
        case "peer_up":
            guard let peer = event.peer else { break }
            peers.removeAll { $0.id == peer.id }
            peers.append(peer)
            peers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            remember(peer)
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
            remember(peer)
            sessions[peer.id, default: PeerSession(status: .connecting)].status = .connected(knownPeers[peer.id] ?? peer)
            lastError = nil
            refreshArrangement()
        case "disconnected":
            // Sessions are per peer; one without a peer ID concerns none.
            guard let peerID = event.peerID else { break }
            let name = sessions[peerID]?.peer?.name ?? name(of: peerID)
            sessions[peerID] = nil
            // The core does not always end a transfer whose peer went away
            // (as on Windows, `state.rs`, they go with the peer).
            for transfer in transfers where transfer.peerID == peerID {
                pairing.dismiss(id: "file-\(transfer.transfer)")
            }
            transfers.removeAll { $0.peerID == peerID }
            inputBridge.setPointerHeld(false, on: peerID)
            refreshArrangement()
            updateDriven()
            if let message = event.reason.flatMap(Self.disconnectMessage) {
                lastError = "\(name)：\(message)"
            }
        case "remote_control_started", "remote_control_ended":
            guard let peerID = event.peerID else { break }
            let active = event.event == "remote_control_started"
            sessions[peerID]?.remoteControl = active
            updateDriven()
            if active {
                cursorHider.reveal()
            } else if event.reason == "remote reset", settings.hideCursorOnLeave,
                      !sessions.values.contains(where: \.remoteControl)
            {
                // The peer's pointer moved away: the cursor shows only where
                // the pointer is.
                cursorHider.hideUntilLocalMotion()
            }
        case "control_revoked":
            // The core took this Mac's control of the peer away: another
            // device drives that peer now, or a peer drives this Mac
            // ("taken_over", and that peer places the cursor).
            guard let peerID = event.peerID, peerID == controlledPeerID else { break }
            inputBridge.controlRevoked(pointerStays: event.reason == "taken_over")
        case "peer_pointer_lock":
            guard let peerID = event.peerID else { break }
            inputBridge.setPointerHeld(event.locked ?? false, on: peerID)
        case "peer_active":
            presence.peerActive()
        case "lock_requested":
            presence.lockRequested()
        case "manual_addresses":
            manualAddressStatus = event.addresses ?? []
        case "peer_displays":
            guard let peerID = event.peerID, let displays = event.displays,
                  var peer = knownPeers[peerID] ?? peers.first(where: { $0.id == peerID })
            else {
                break
            }
            peer.displays = displays
            remember(peer)
            refreshArrangement()
        case "placement_changed":
            guard let peerID = event.peerID, let updatedMs = event.updatedMs else { break }
            placements[peerID] = PlacementRecord(
                peerID: peerID,
                offset: event.offset,
                updatedMs: updatedMs
            )
            Self.savePlacements(placements)
            refreshArrangement()
        case "clipboard":
            guard settings.clipboard else {
                // The core keeps what it received as this device's clipboard
                // and would pass it on to the next peer (as on Windows).
                core.setClipboard([])
                break
            }
            // A peer's clipboard, handed over with the control.
            let items = (event.formats ?? []).compactMap { format in
                Data(base64Encoded: format.data).map { ClipboardItem(mime: format.mime, data: $0) }
            }
            clipboard.write(items)
        case "pairing_requested":
            guard let peerID = event.peerID, let code = event.code else { break }
            let name = event.name ?? name(of: peerID)
            pairing.ask(peerID: peerID, name: name, code: code) { [core] accepted in
                if accepted {
                    core.acceptPairing(peerID)
                } else {
                    core.rejectPairing(peerID)
                }
            }
        case "paired":
            guard let peerID = event.peerID, let fingerprint = event.fingerprint else { break }
            trustedPeers[peerID] = TrustedPeer(peerID: peerID, fingerprint: fingerprint)
            Self.saveTrustedPeers(trustedPeers)
            pairing.dismiss(peerID: peerID)
        case "pairing_ended":
            guard let peerID = event.peerID else { break }
            pairing.dismiss(peerID: peerID)
            if let message = event.reason.flatMap(Self.disconnectMessage) {
                lastError = String(localized: "配对未完成：\(message)")
            }
        case "unpaired":
            guard let peerID = event.peerID else { break }
            trustedPeers[peerID] = nil
            Self.saveTrustedPeers(trustedPeers)
        case "files_offered":
            guard let transfer = event.transfer else { break }
            guard settings.clipboard else {
                core.cancelFiles(transfer)
                break
            }
            askToReceiveFiles(transfer, from: event.peerID, count: event.count ?? 0, size: event.totalSize ?? 0)
        case "files_receiving", "files_progress", "files_sending":
            guard settings.clipboard else {
                if let transfer = event.transfer { core.cancelFiles(transfer) }
                break
            }
            updateTransfer(with: event)
        case "files_received":
            guard let transfer = event.transfer else { break }
            transfers.removeAll { $0.direction == .receiving && $0.transfer == transfer }
            notifications.filesReceived(from: name(of: event.peerID), paths: event.paths ?? [])
            Self.log.info("received \(event.paths?.count ?? 0) file items")
        case "files_not_shared":
            // Copied here, past the core's limits: the rest of the clipboard
            // still went.
            lastError = event.reason == "too_deep"
                ? String(localized: "复制的文件夹层级太深，文件未共享。请先压缩后再复制。")
                : String(localized: "复制的文件太多，文件未共享。请先压缩后再复制。")
        case "files_failed", "files_send_ended":
            guard let transfer = event.transfer else { break }
            let sending = event.event == "files_send_ended"
            pairing.dismiss(id: "file-\(transfer)")
            transfers.removeAll { $0.direction == (sending ? .sending : .receiving) && $0.transfer == transfer }
            if let reason = event.reason, !Self.quietTransferEnds.contains(reason) {
                lastError = sending
                    ? String(localized: "发送文件失败：\(reason)")
                    : String(localized: "接收文件失败：\(reason)")
            }
        case "error":
            lastError = event.message
            if coreState == .starting {
                coreState = .failed(event.message ?? String(localized: "无法启动 Rust Core"))
            }
        default:
            break
        }
    }

    func rustCore(_ core: RustCore, received input: LcInputEvent) {
        // Reset releases must still be played after pausing. New presses and
        // motion already queued before the pause must not take effect.
        guard !shuttingDown,
              settings.sharing || input.kind == UInt32(LC_INPUT_KEY_UP)
                || input.kind == UInt32(LC_INPUT_MOUSE_BUTTON_UP)
        else { return }
        player.play(input)
        receivedEventCount += 1
    }

    /// The card of a transfer starting or under way.
    private func updateTransfer(with event: CoreEventEnvelope) {
        guard let transfer = event.transfer else { return }
        let direction: FileTransfer.Direction = event.event == "files_sending" ? .sending : .receiving
        let index = transfers.firstIndex { $0.direction == direction && $0.transfer == transfer }
        var card = index.map { transfers[$0] } ?? FileTransfer(
            direction: direction,
            transfer: transfer,
            peerID: event.peerID,
            name: "",
            items: 0,
            count: 0,
            done: 0,
            total: 0
        )
        if let name = event.name { card.name = name }
        if let items = event.items { card.items = items }
        if let count = event.count { card.count = count }
        if let total = event.totalSize ?? event.total { card.total = total }
        if let done = event.received ?? event.sent { card.done = done }
        if let index {
            transfers[index] = card
        } else {
            transfers.append(card)
        }
    }

    /// Transfers that end for these were stopped on purpose or replaced.
    private static let quietTransferEnds: Set<String> = [
        "done",
        "cancelled",
        "replaced by a newer copy",
        "files are no longer on the clipboard",
    ]

    /// What to tell the user about a session or pairing that ended, if
    /// anything: ending it here or on the peer, or for sleep, is not an
    /// error. The core reconnects by itself where it should.
    private static func disconnectMessage(_ reason: String) -> String? {
        switch reason {
        case "local request", "peer closed the connection", "disconnected on the other device",
             "going to sleep", "pairing declined", "core stopped":
            nil
        case "heartbeat timeout":
            String(localized: "对方没有响应（可能睡眠了或断网），回来后会自动重新连接。")
        case "refused by the other device":
            String(localized: "对方拒绝了连接：对方可能移除了本机，或只允许已配对的设备。点“连接”可以重新配对。")
        case "the device's identity changed":
            String(localized: "设备的身份证书变了，已拒绝连接。如果对方重装过，请取消配对后重新配对。")
        case "pairing declined on the other device":
            String(localized: "对方拒绝了配对。")
        case "pairing timed out":
            String(localized: "配对超时，没有在两分钟内确认。")
        case "pairing required":
            String(localized: "未配对的设备已断开（已开启“仅允许已配对的设备”）。")
        case "the other device needs a newer LinkCursor to pair":
            String(localized: "对方的 LinkCursor 版本太旧，无法配对，请先更新。")
        case "unpaired":
            String(localized: "已取消配对。")
        default:
            reason
        }
    }

    /// The core keeps the user's devices connected by itself, but it has to
    /// hear about sleep and network changes to end sessions in order and
    /// come back at once instead of after heartbeat timeouts.
    private func observePowerAndNetwork() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.core.systemWillSleep() }
        }
        workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.core.networkChanged() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.networkChanged() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.linkcursor.network"))
    }

    /// Tells the core once the network has been quiet for 0.8 s.
    private func networkChanged() {
        pendingNetworkChange?.cancel()
        let change = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.core.networkChanged() }
        }
        pendingNetworkChange = change
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: change)
    }

    /// Up to this size copied files come in by themselves, as on Windows
    /// (the agent's 512 MB); over it, the user decides.
    private static let autoReceiveBytes: UInt64 = 512 * 1024 * 1024

    /// The core offers every transfer (its own limit is 0), so turning the
    /// clipboard off stops one before any file is written.
    private func askToReceiveFiles(_ transfer: UInt32, from peerID: String?, count: Int, size: UInt64) {
        if size <= Self.autoReceiveBytes {
            core.acceptFiles(transfer)
            return
        }
        pairing.show(
            id: "file-\(transfer)",
            title: String(localized: "\(name(of: peerID)) 想发送 \(count) 个文件"),
            message: String(localized: "共 \(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))，将保存到“下载/LinkCursor”。"),
            accept: String(localized: "接收")
        ) { [weak self] accepted in
            guard let self else { return }
            if accepted && self.settings.clipboard { self.core.acceptFiles(transfer) }
            else { self.core.cancelFiles(transfer) }
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
        hud.show(peerName: name(of: peerID)) { [weak self] in self?.stopControlling() }
    }

    /// Whether some peer drives this Mac: input is played then.
    private func updateDriven() {
        player.setDriven(sessions.values.contains(where: \.remoteControl))
    }

    private func name(of peerID: String?) -> String {
        guard let peerID else { return String(localized: "对方") }
        return sessions[peerID]?.peer?.name
            ?? peers.first { $0.id == peerID }?.name
            ?? knownPeers[peerID]?.name
            ?? peerID
    }

    private func screensChanged() {
        localDisplays = Self.currentDisplays()
        core.setLocalDisplays(localDisplays)
        refreshArrangement()
    }

    // MARK: - Arrangement

    /// The peer's displays as last described, or the core's default.
    private func layout(of peerID: String) -> [Display] {
        let displays = knownPeers[peerID]?.displays ?? []
        return displays.isEmpty ? [.fallback] : displays
    }

    /// This Mac and every placed peer, in this Mac's space.
    private var world: World {
        World(
            local: localDisplays,
            peers: placements.values.compactMap { record in
                record.offset.map { PlacedPeer(id: record.peerID, displays: layout(of: record.peerID), offset: $0) }
            }.sorted { $0.id < $1.id }
        )
    }

    private static let permissionNeeded = String(localized: "设备位置已保存；授予辅助功能权限后即可从屏幕边缘切换")

    /// Hands the arrangement and the connected peers to the input bridge.
    private func refreshArrangement() {
        guard settings.sharing, !shuttingDown else {
            inputBridge.stop()
            return
        }
        let connected = Set(sessions.filter { $0.value.peer != nil }.keys)
        if !inputBridge.setArrangement(world, connected: connected) {
            lastError = Self.permissionNeeded
        }
    }

    private func remember(_ peer: Peer) {
        let peer = peer.mergingKnown(knownPeers[peer.id])
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

    private static let trustedPeersKey = "linkcursor.trusted-peers"

    private static func loadTrustedPeers() -> [String: TrustedPeer] {
        guard
            let data = UserDefaults.standard.data(forKey: trustedPeersKey),
            let peers = try? JSONDecoder().decode([TrustedPeer].self, from: data)
        else {
            return [:]
        }
        return Dictionary(peers.map { ($0.peerID, $0) }) { _, latest in latest }
    }

    private static func saveTrustedPeers(_ peers: [String: TrustedPeer]) {
        guard let data = try? JSONEncoder().encode(Array(peers.values)) else { return }
        UserDefaults.standard.set(data, forKey: trustedPeersKey)
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
