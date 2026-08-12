import Foundation

@MainActor
protocol RustCoreDelegate: AnyObject {
    func rustCore(_ core: RustCore, received event: CoreEventEnvelope)
    func rustCore(_ core: RustCore, received input: LcInputEvent)
}

@MainActor
final class RustCore {
    weak var delegate: (any RustCoreDelegate)?

    private var handle: OpaquePointer?

    isolated deinit {
        if let handle {
            lc_core_destroy(handle)
        }
    }

    func start(deviceID: String, deviceName: String) -> Bool {
        guard handle == nil else { return true }
        guard lc_core_abi_version() == UInt32(LC_CORE_ABI_VERSION) else { return false }

        let configuration: [String: Any] = [
            "device_id": deviceID,
            "device_name": deviceName,
            "control_port": 42_421,
            "discovery_port": 42_420,
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: configuration),
            let json = String(data: data, encoding: .utf8)
        else {
            return false
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        handle = json.withCString { pointer in
            lc_core_create(pointer, linkCursorCoreEventCallback, linkCursorInputCallback, context)
        }
        return handle != nil
    }

    func connect(to peerID: String) -> Bool {
        guard let handle else { return false }
        return peerID.withCString { lc_core_connect(handle, $0) }
    }

    func disconnect() {
        guard let handle else { return }
        _ = lc_core_disconnect(handle)
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
