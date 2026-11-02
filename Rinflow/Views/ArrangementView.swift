// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// This Mac's displays and the devices around it, drawn to scale in points
/// like the Displays settings. Dragging only proposes a spot: the core snaps
/// it to a valid one, syncs it to the peer and reports where it landed, which
/// is what gets drawn. Dropping a device outside the canvas unplaces it.
struct ArrangementView: View {
    let deviceName: String
    let local: [Display]
    let devices: [ArrangedDevice]
    /// The peer the mouse is on now, if any.
    let pointerOn: String?
    let place: @MainActor (String, Offset?) -> Void

    @State private var dragging: Dragging?
    @Environment(\.colorScheme) private var scheme

    private struct Dragging: Equatable {
        let id: String
        /// Pointer, in the view's coordinates.
        var location: CGPoint
        var translation: CGSize
    }

    private static let space = "arrangement"
    private static let trayHeight: CGFloat = 40

    var body: some View {
        GeometryReader { geometry in
            // Above: where devices are placed. Below, a strip of its own:
            // devices not placed yet, and where a placed one is dropped to
            // unplace it.
            let canvas = CGRect(x: 0, y: 0, width: geometry.size.width,
                                height: geometry.size.height - Self.trayHeight)
            let strip = CGRect(x: 0, y: canvas.maxY, width: geometry.size.width, height: Self.trayHeight)
            let scale = CanvasScale(local: local, devices: devices, in: canvas.insetBy(dx: 16, dy: 14))

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(scheme == .dark ? Color.black.opacity(0.25) : Color.secondary.opacity(0.1))
                    .frame(width: geometry.size.width, height: geometry.size.height)

                tray(scale: scale, canvas: canvas, strip: strip)

                ForEach(Array(local.enumerated()), id: \.offset) { _, display in
                    localTile(display, scale: scale)
                }

                ForEach(devices.filter { $0.offset != nil }) { device in
                    placedTile(device, scale: scale, canvas: canvas)
                }

                if let dragging, let device = devices.first(where: { $0.id == dragging.id }),
                   device.offset == nil
                {
                    // An unplaced device is drawn to scale under the pointer.
                    DeviceTile(device: device, scale: scale.scale, pointerHere: false)
                        .opacity(canvas.contains(dragging.location) ? 0.9 : 0.5)
                        .position(dragging.location)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: Self.space)
        }
        .frame(height: 260)
    }

    /// This Mac's displays, plain like a desktop; the main one carries the
    /// Mac's name.
    private func localTile(_ display: Display, scale: CanvasScale) -> some View {
        let rect = scale.view(display.rect)
        let isMain = display.x == 0 && display.y == 0
        return RoundedRectangle(cornerRadius: 4)
            .fill(scheme == .dark ? Color(white: 0.24) : .white)
            .overlay {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
            }
            .overlay {
                if isMain {
                    TileLabel(title: deviceName, detail: Text("本机"))
                }
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    private func placedTile(_ device: ArrangedDevice, scale: CanvasScale, canvas: CGRect) -> some View {
        let offset = device.offset ?? Offset(x: 0, y: 0)
        let rect = scale.view(device.bounds.offsetBy(dx: offset.x, dy: offset.y))
        let shift = dragging?.id == device.id ? dragging?.translation ?? .zero : .zero
        return DeviceTile(device: device, scale: scale.scale, pointerHere: device.id == pointerOn)
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

    /// The strip under the canvas: devices not placed yet, dragged from
    /// here beside a screen; a placed device dropped here is unplaced.
    private func tray(scale: CanvasScale, canvas: CGRect, strip: CGRect) -> some View {
        let unplaced = devices.filter { $0.offset == nil }
        let unplacing = dragging.map { drag in
            strip.contains(drag.location) && devices.contains { $0.id == drag.id && $0.offset != nil }
        } ?? false
        return ZStack(alignment: .leading) {
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                .fill(unplacing ? Color.accentColor.opacity(0.2)
                      : Color.black.opacity(scheme == .dark ? 0.2 : 0.04))
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
                }

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
                if unplaced.isEmpty || unplacing {
                    Text(unplacing ? "松开以取消放置" : "拖到这里可取消放置")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(width: strip.width, height: strip.height)
        .offset(y: strip.minY)
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

/// A peer's displays at canvas scale: filled where the mouse is, outlined
/// when connected, dashed when offline.
private struct DeviceTile: View {
    let device: ArrangedDevice
    let scale: CGFloat
    let pointerHere: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let bounds = device.bounds
        ZStack(alignment: .topLeading) {
            ForEach(Array(device.displays.enumerated()), id: \.offset) { _, display in
                RoundedRectangle(cornerRadius: 4)
                    .fill(pointerHere ? Color.accentColor : scheme == .dark ? Color(white: 0.17) : .white)
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
            TileLabel(title: device.name, detail: detail, symbol: device.symbol)
                .foregroundStyle(pointerHere ? AnyShapeStyle(.white)
                                 : device.state == .offline ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .frame(width: bounds.width * scale, height: bounds.height * scale)
        }
        .frame(width: bounds.width * scale, height: bounds.height * scale, alignment: .topLeading)
        .contentShape(.rect)
    }

    private var detail: Text {
        if pointerHere { return Text(Image(systemName: "cursorarrow")) + Text(" ") + Text("鼠标在这里") }
        switch device.state {
        case .connected: return Text("已连接")
        case .online: return Text("未连接")
        case .offline: return Text("离线")
        }
    }
}

/// A tile's name and state, shrunk to fit small tiles.
private struct TileLabel: View {
    let title: String
    let detail: Text
    /// Shown instead when the name does not fit (a phone standing upright).
    var symbol = "desktopcomputer"

    var body: some View {
        ViewThatFits {
            VStack(spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                detail.font(.caption).opacity(0.75)
            }
            .fixedSize()
            Image(systemName: symbol).font(.subheadline)
        }
        .padding(4)
        .help(title)
    }
}

/// A device waiting in the strip: its icon and name.
private struct DeviceChip: View {
    let device: ArrangedDevice

    var body: some View {
        Label(device.name, systemImage: device.symbol)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.4))
            }
            .contentShape(.rect)
            .help("拖到屏幕旁边")
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
        case .online: .secondary.opacity(0.6)
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
