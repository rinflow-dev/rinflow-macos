// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import OSLog

@MainActor
protocol RustCoreDelegate: AnyObject {
    func rustCore(_ core: RustCore, received event: CoreEventEnvelope)
    func rustCore(_ core: RustCore, received input: LcInputEvent)
}

@MainActor
final class RustCore {
    weak var delegate: (any RustCoreDelegate)?

    private var handle: OpaquePointer?
    private var callbacks: CallbackRelay<RustCore>?
    private static let log = Logger(subsystem: "com.linkcursor.mac", category: "core")

    isolated deinit {
        callbacks?.invalidate()
        if let handle {
            lc_core_destroy(handle)
        }
    }

    func stop() {
        callbacks?.invalidate()
        if let handle {
            // destroy joins the Rust thread: no callback can borrow the relay
            // after this returns. Queued deliveries own it independently.
            lc_core_destroy(handle)
        }
        handle = nil
        callbacks = nil
    }

    private struct Configuration: Encodable {
        let deviceID: String
        let deviceName: String
        let platform = "macos"
        let controlPort = 42_421
        let discoveryPort = 42_420
        let displays: [Display]
        let placements: [PlacementRecord]
        /// This shell reads and writes the pasteboard (ClipboardBridge).
        let clipboard = true
        /// Copied files travel with the clipboard; received ones land here.
        let files = true
        /// Every transfer is offered (`files_offered`), as on Windows: the
        /// app accepts up to its own limit and asks beyond it, and with the
        /// clipboard off rejects it before any file contents are downloaded.
        let maxAutoReceiveBytes: UInt64 = 0
        let downloadDirectory: String
        /// This Mac's key and certificate; kept, so paired peers know it.
        let identityPath: String
        let trustedPeers: [TrustedPeer]
        /// Only paired peers may connect (as on Windows, by default).
        let requirePairing: Bool
        /// What a PC's modifier keys play as here (core `remap.rs`).
        let modifierMap: [String: String]
        /// Devices to look for by address, besides multicast discovery.
        let manualAddresses: [String]

        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case deviceName = "device_name"
            case platform
            case controlPort = "control_port"
            case discoveryPort = "discovery_port"
            case displays
            case placements
            case clipboard
            case files
            case maxAutoReceiveBytes = "max_auto_receive_bytes"
            case downloadDirectory = "download_directory"
            case identityPath = "identity_path"
            case trustedPeers = "trusted_peers"
            case requirePairing = "require_pairing"
            case modifierMap = "modifier_map"
            case manualAddresses = "manual_addresses"
        }
    }

    func start(
        deviceID: String,
        deviceName: String,
        displays: [Display],
        placements: [PlacementRecord],
        trustedPeers: [TrustedPeer],
        settings: AppSettings
    ) -> Bool {
        guard handle == nil else { return true }
        guard lc_core_abi_version() == UInt32(LC_CORE_ABI_VERSION) else { return false }

        let configuration = Configuration(
            deviceID: deviceID,
            deviceName: deviceName,
            displays: displays,
            placements: placements,
            downloadDirectory: Self.downloadDirectory.path,
            identityPath: Self.identityPath.path,
            trustedPeers: trustedPeers,
            requirePairing: settings.pairedOnly,
            modifierMap: AppSettings.modifierMap(followMacShortcuts: settings.shortcutRemap),
            manualAddresses: settings.manualAddresses
        )
        guard let json = Self.json(configuration) else { return false }

        let callbacks = CallbackRelay(self)
        self.callbacks = callbacks
        let context = Unmanaged.passUnretained(callbacks).toOpaque()
        handle = json.withCString { pointer in
            lc_core_create(pointer, linkCursorCoreEventCallback, linkCursorInputCallback, context)
        }
        return handle != nil
    }

    /// Opens a session with the peer (other sessions stay open) and makes it
    /// the input target.
    func connect(to peerID: String) -> Bool {
        guard let handle else { return false }
        return peerID.withCString { lc_core_connect(handle, $0) }
    }

    func disconnect(peerID: String) {
        guard let handle else { return }
        _ = peerID.withCString { lc_core_disconnect_peer(handle, $0) }
    }

    /// Where `send` and `resetInput` go. Ordered with input: events sent
    /// after this call reach the new target.
    @discardableResult
    func setInputTarget(_ peerID: String?) -> Bool {
        guard let handle else { return false }
        guard let peerID else { return lc_core_set_input_target(handle, nil) }
        return peerID.withCString { lc_core_set_input_target(handle, $0) }
    }

    func setLocalDisplays(_ displays: [Display]) {
        guard let handle, let json = Self.json(displays) else { return }
        _ = json.withCString { lc_core_set_local_displays(handle, $0) }
    }

    /// Places the peer beside this Mac's outermost edge on `side`, or removes
    /// its placement with nil. The result arrives as `placement_changed`.
    func place(_ peerID: String, beside side: Side?) {
        guard let handle else { return }
        _ = peerID.withCString { peer in
            guard let side else { return lc_core_set_placement(handle, peer, nil) }
            return side.rawValue.withCString { lc_core_place_beside(handle, peer, $0) }
        }
    }

    /// Proposes a spot for the peer, or removes its placement with nil.
    /// The core snaps it and reports the result as `placement_changed`.
    func place(_ peerID: String, at offset: Offset?) {
        guard let handle else { return }
        _ = peerID.withCString { peer in
            guard let offset, let json = Self.json(offset) else {
                return lc_core_set_placement(handle, peer, nil)
            }
            return json.withCString { lc_core_set_placement(handle, peer, $0) }
        }
    }

    /// Received files go to ~/Downloads/LinkCursor.
    static var downloadDirectory: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
        return downloads.appending(path: "LinkCursor", directoryHint: .isDirectory)
    }

    /// ~/Library/Application Support/LinkCursor/identity.pem
    static var identityPath: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        let directory = support.appending(path: "LinkCursor", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "identity.pem")
    }

    /// The system is about to sleep: sessions end in order now.
    func systemWillSleep() {
        guard let handle else { return }
        _ = lc_core_system_will_sleep(handle)
    }

    /// After waking, or when the network changed: find and reconnect peers now.
    func networkChanged() {
        guard let handle else { return }
        _ = lc_core_network_changed(handle)
    }

    func setRequirePairing(_ required: Bool) {
        guard let handle else { return }
        _ = lc_core_set_require_pairing(handle, required)
    }

    func setShortcutRemap(_ enabled: Bool) {
        guard let handle,
              let data = try? JSONEncoder().encode(AppSettings.modifierMap(followMacShortcuts: enabled)),
              let json = String(data: data, encoding: .utf8)
        else { return }
        _ = json.withCString { lc_core_set_modifier_map(handle, $0) }
    }


    func setRemoteControlAllowed(_ allowed: Bool) {
        guard let handle else { return }
        _ = lc_core_set_remote_control_allowed(handle, allowed)
    }

    /// Replaces the addresses to look for devices at.
    func setManualAddresses(_ addresses: [String]) {
        guard let handle, let json = Self.json(addresses) else { return }
        _ = json.withCString { lc_core_set_manual_addresses(handle, $0) }
    }

    /// Someone uses this Mac's own keyboard or mouse (every few seconds).
    func reportUserActivity() {
        guard let handle else { return }
        _ = lc_core_report_user_activity(handle)
    }

    /// This Mac was locked: peers that want to lock too.
    func lockPeers() {
        guard let handle else { return }
        _ = lc_core_lock_peers(handle)
    }

    /// A game here holds the pointer (hidden, relative motion), or let go.
    func setPointerLocked(_ locked: Bool) {
        guard let handle else { return }
        _ = lc_core_set_pointer_locked(handle, locked)
    }

    func acceptPairing(_ peerID: String) {
        guard let handle else { return }
        _ = peerID.withCString { lc_core_accept_pairing(handle, $0) }
    }

    func rejectPairing(_ peerID: String) {
        guard let handle else { return }
        _ = peerID.withCString { lc_core_reject_pairing(handle, $0) }
    }

    func unpair(_ peerID: String) {
        guard let handle else { return }
        _ = peerID.withCString { lc_core_unpair(handle, $0) }
    }

    func acceptFiles(_ transfer: UInt32) {
        guard let handle else { return }
        _ = lc_core_accept_files(handle, transfer)
    }

    /// Stops a transfer either way: one being received, or this Mac's
    /// files being sent.
    func cancelFiles(_ transfer: UInt32) {
        guard let handle else { return }
        _ = lc_core_cancel_files(handle, transfer)
    }

    /// The pasteboard after a change; empty when it holds nothing to share.
    func setClipboard(_ items: [ClipboardItem]) {
        guard let handle else { return }
        let formats = items.map { ["mime": $0.mime, "data": $0.data.base64EncodedString()] }
        guard
            let data = try? JSONSerialization.data(withJSONObject: ["formats": formats]),
            let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        _ = json.withCString { lc_core_set_clipboard(handle, $0) }
    }

    private static func json(_ value: some Encodable) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func send(_ event: LcInputEvent) -> Bool {
        guard let handle else { return false }
        var event = event
        return lc_core_send_input(handle, &event)
    }

    @discardableResult
    func resetInput() -> Bool {
        guard let handle else { return false }
        return lc_core_reset_input(handle)
    }

    fileprivate func receive(eventJSON: String) {
        guard
            let data = eventJSON.data(using: .utf8),
            let event = try? JSONDecoder().decode(CoreEventEnvelope.self, from: data)
        else {
            return
        }
        // JSON may contain clipboard contents, pairing codes and file paths.
        // Log only the event type, never any part of its payload.
        Self.log.debug("core event: \(event.event, privacy: .public)")
        delegate?.rustCore(self, received: event)
    }

    fileprivate func receive(input: LcInputEvent) {
        delegate?.rustCore(self, received: input)
    }
}

private func linkCursorCoreEventCallback(
    _ json: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let json, let context else { return }
    let message = String(cString: json)
    let callbacks = Unmanaged<CallbackRelay<RustCore>>.fromOpaque(context).takeUnretainedValue()
    callbacks.enqueue { $0.receive(eventJSON: message) }
}

private func linkCursorInputCallback(
    _ input: UnsafePointer<LcInputEvent>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let input, let context else { return }
    let value = input.pointee
    let callbacks = Unmanaged<CallbackRelay<RustCore>>.fromOpaque(context).takeUnretainedValue()
    callbacks.enqueue { $0.receive(input: value) }
}
