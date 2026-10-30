import SwiftUI

/// This Mac's displays and the devices around it, drawn to scale in points
/// like the Displays settings. Dragging only proposes a spot: the core snaps
/// it to a valid one, syncs it to the peer and reports where it landed, which
/// is what gets drawn. Dropping a device outside the canvas unplaces it.
struct ArrangementView: View {
    let deviceName: String
    let local: [Display]
    let devices: [ArrangedDevice]
    let place: @MainActor (String, Offset?) -> Void

    @State private var dragging: Dragging?

    private struct Dragging: Equatable {
        let id: String
        /// Pointer, in the view's coordinates.
        var location: CGPoint
        var translation: CGSize
    }

    private static let space = "arrangement"
    private static let trayHeight: CGFloat = 48
    private static let gap: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let canvas = CGRect(
                x: 0,
                y: 0,
                width: geometry.size.width,
                height: geometry.size.height - Self.trayHeight - Self.gap
            )
            let scale = CanvasScale(local: local, devices: devices, in: canvas.insetBy(dx: 12, dy: 12))

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: canvas.width, height: canvas.height)

                ForEach(Array(local.enumerated()), id: \.offset) { _, display in
                    localTile(display, scale: scale)
                }

                ForEach(devices.filter { $0.offset != nil }) { device in
                    placedTile(device, scale: scale, canvas: canvas)
                }

                tray(width: geometry.size.width, scale: scale, canvas: canvas)
                    .offset(y: canvas.maxY + Self.gap)

                if let dragging, let device = devices.first(where: { $0.id == dragging.id }),
                   device.offset == nil
                {
                    // An unplaced device is drawn to scale under the pointer.
                    DeviceTile(device: device, scale: scale.scale)
                        .opacity(canvas.contains(dragging.location) ? 0.9 : 0.5)
                        .position(dragging.location)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: Self.space)
        }
        .frame(height: 220)
    }

    private func localTile(_ display: Display, scale: CanvasScale) -> some View {
        let rect = scale.view(display.rect)
        let isMain = display.x == 0 && display.y == 0
        return RoundedRectangle(cornerRadius: 4)
            .fill(Color.accentColor.opacity(0.8))
            .overlay {
                RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.6), lineWidth: 1)
            }
            .overlay {
                if isMain {
                    Text(deviceName)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(4)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    private func placedTile(_ device: ArrangedDevice, scale: CanvasScale, canvas: CGRect) -> some View {
        let offset = device.offset ?? Offset(x: 0, y: 0)
        let rect = scale.view(device.bounds.offsetBy(dx: offset.x, dy: offset.y))
        let shift = dragging?.id == device.id ? dragging?.translation ?? .zero : .zero
        return DeviceTile(device: device, scale: scale.scale)
            .position(x: rect.midX + shift.width, y: rect.midY + shift.height)
            .gesture(
                DragGesture(coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        dragging = Dragging(
                            id: device.id,
                            location: value.location,
                            translation: value.translation
                        )
                    }
                    .onEnded { value in
                        dragging = nil
                        guard canvas.contains(value.location) else {
                            place(device.id, nil)
                            return
                        }
                        place(device.id, Offset(
                            x: offset.x + value.translation.width / scale.scale,
                            y: offset.y + value.translation.height / scale.scale
                        ))
                    }
            )
    }

    private func tray(width: CGFloat, scale: CanvasScale, canvas: CGRect) -> some View {
        let unplaced = devices.filter { $0.offset == nil }
        return VStack(alignment: .leading, spacing: 6) {
            Text(unplaced.isEmpty ? "所有设备都已放置" : "未放置的设备 · 拖到本机屏幕旁边")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(unplaced) { device in
                    DeviceChip(device: device)
                        .opacity(dragging?.id == device.id ? 0.3 : 1)
                        .gesture(
                            DragGesture(coordinateSpace: .named(Self.space))
                                .onChanged { value in
                                    dragging = Dragging(
                                        id: device.id,
                                        location: value.location,
                                        translation: value.translation
                                    )
                                }
                                .onEnded { value in
                                    dragging = nil
                                    guard canvas.contains(value.location) else { return }
                                    // The pointer holds the middle of the device.
                                    let point = scale.points(value.location)
                                    let bounds = device.bounds
                                    place(device.id, Offset(
                                        x: point.x - bounds.width / 2 - bounds.minX,
                                        y: point.y - bounds.height / 2 - bounds.minY
                                    ))
                                }
                        )
                }
            }
        }
        .frame(width: width, height: Self.trayHeight, alignment: .topLeading)
    }
}

/// Maps the arrangement (points, this Mac's space) into the canvas.
private struct CanvasScale {
    let scale: CGFloat
    /// The canvas position of `box.origin`.
    let origin: CGPoint
    let box: CGRect

    init(local: [Display], devices: [ArrangedDevice], in canvas: CGRect) {
        let localBounds = Display.bounds(of: local)
        let home = localBounds.isNull ? Display.fallback.rect : localBounds
        var box = home
        var room = Display.fallback.rect.size
        for device in devices {
            let bounds = device.bounds
            room.width = max(room.width, bounds.width)
            room.height = max(room.height, bounds.height)
            if let offset = device.offset {
                box = box.union(bounds.offsetBy(dx: offset.x, dy: offset.y))
            }
        }
        // Room on every side of this Mac to drop a device beside any edge.
        box = box.union(home.insetBy(dx: -room.width, dy: -room.height))
        let scale = min(canvas.width / box.width, canvas.height / box.height)
        self.scale = scale
        self.box = box
        origin = CGPoint(
            x: canvas.midX - box.width * scale / 2,
            y: canvas.midY - box.height * scale / 2
        )
    }

    func view(_ rect: CGRect) -> CGRect {
        CGRect(
            x: origin.x + (rect.minX - box.minX) * scale,
            y: origin.y + (rect.minY - box.minY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    func points(_ location: CGPoint) -> CGPoint {
        CGPoint(
            x: box.minX + (location.x - origin.x) / scale,
            y: box.minY + (location.y - origin.y) / scale
        )
    }
}

/// A peer's displays at canvas scale, outlined by its state.
private struct DeviceTile: View {
    let device: ArrangedDevice
    let scale: CGFloat

    var body: some View {
        let bounds = device.bounds
        ZStack(alignment: .topLeading) {
            ForEach(Array(device.displays.enumerated()), id: \.offset) { _, display in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(device.state.color, style: device.state.stroke)
                    }
                    .frame(width: display.width * scale, height: display.height * scale)
                    .offset(
                        x: (display.x - bounds.minX) * scale,
                        y: (display.y - bounds.minY) * scale
                    )
            }
            VStack(spacing: 2) {
                Image(systemName: device.symbol)
                Text(device.name)
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(device.state == .offline ? .secondary : .primary)
            .padding(2)
            .frame(width: bounds.width * scale, height: bounds.height * scale)
        }
        .frame(width: bounds.width * scale, height: bounds.height * scale, alignment: .topLeading)
        .contentShape(.rect)
    }
}

private struct DeviceChip: View {
    let device: ArrangedDevice

    var body: some View {
        Label(device.name, systemImage: device.symbol)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor), in: .capsule)
            .overlay {
                Capsule().strokeBorder(device.state.color, style: device.state.stroke)
            }
            .contentShape(.capsule)
    }
}

private extension ArrangedDevice {
    var symbol: String {
        switch platform {
        case "windows": "pc"
        case "android": "smartphone"
        case "macos": "laptopcomputer"
        default: "desktopcomputer"
        }
    }
}

private extension ArrangedDevice.State {
    var color: Color {
        switch self {
        case .connected: .accentColor
        case .online: .primary.opacity(0.6)
        case .offline: .secondary
        }
    }

    var stroke: StrokeStyle {
        switch self {
        case .connected: StrokeStyle(lineWidth: 2)
        case .online: StrokeStyle(lineWidth: 1)
        case .offline: StrokeStyle(lineWidth: 1, dash: [4, 3])
        }
    }
}
