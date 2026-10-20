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
    private static let log = Logger(subsystem: "com.linkcursor.mac", category: "core")

    isolated deinit {
        if let handle {
            lc_core_destroy(handle)
        }
    }

    private struct Configuration: Encodable {
        let deviceID: String
        let deviceName: String
        let platform = "macos"
        let controlPort = 42_421
        let discoveryPort = 42_420
        let displays: [Display]
        let placements: [PlacementRecord]

        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case deviceName = "device_name"
            case platform
            case controlPort = "control_port"
            case discoveryPort = "discovery_port"
            case displays
            case placements
        }
    }

    func start(
        deviceID: String,
        deviceName: String,
        displays: [Display],
        placements: [PlacementRecord]
    ) -> Bool {
        guard handle == nil else { return true }
        guard lc_core_abi_version() == UInt32(LC_CORE_ABI_VERSION) else { return false }

        let configuration = Configuration(
            deviceID: deviceID,
            deviceName: deviceName,
            displays: displays,
            placements: placements
        )
        guard let json = Self.json(configuration) else { return false }

        let context = Unmanaged.passUnretained(self).toOpaque()
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
        Self.log.info("\(eventJSON, privacy: .public)")
        guard
            let data = eventJSON.data(using: .utf8),
            let event = try? JSONDecoder().decode(CoreEventEnvelope.self, from: data)
        else {
            return
        }
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
    let contextAddress = UInt(bitPattern: context)

    Task { @MainActor in
        guard let pointer = UnsafeMutableRawPointer(bitPattern: contextAddress) else { return }
        let core = Unmanaged<RustCore>.fromOpaque(pointer).takeUnretainedValue()
        core.receive(eventJSON: message)
    }
}

private func linkCursorInputCallback(
    _ input: UnsafePointer<LcInputEvent>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let input, let context else { return }
    let value = input.pointee
    let contextAddress = UInt(bitPattern: context)

    Task { @MainActor in
        guard let pointer = UnsafeMutableRawPointer(bitPattern: contextAddress) else { return }
        let core = Unmanaged<RustCore>.fromOpaque(pointer).takeUnretainedValue()
        core.receive(input: value)
    }
}
