import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(
                deviceName: model.deviceName,
                coreState: model.coreState,
                connectionState: model.connectionState
            )

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    PermissionCard(
                        isGranted: model.hasAccessibilityPermission,
                        requestPermission: model.requestPermission,
                        refreshPermission: model.refreshPermission
                    )

                    ConnectedControlCard(
                        peer: model.connectionState.connectedPeer,
                        placement: model.connectionState.connectedPeer
                            .map(model.placement(for:)) ?? .disabled,
                        hasAccessibilityPermission: model.hasAccessibilityPermission,
                        isControlling: model.isControlling,
                        stop: model.stopControlling
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text("排列")
                            .font(.headline)
                        Text("拖动设备决定从哪条边缘切换过去；拖出画布即取消放置。两端的排列会自动同步。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ArrangementView(
                            deviceName: model.deviceName,
                            local: model.localDisplays,
                            devices: model.arrangedDevices,
                            place: { model.place($0, at: $1) }
                        )
                    }
                    .padding(16)
                    .background(.background.secondary, in: .rect(cornerRadius: 14))

                    peerSection

                    if let lastError = model.lastError {
                        Label(lastError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }

                    Text("MVP 说明：当前链路未启用加密和配对，仅应在可信局域网中测试。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(22)
            }

            Divider()

            HStack {
                if let fileTransfer = model.fileTransfer {
                    Text(fileTransfer)
                    Text("·")
                }
                Text("已发送 \(model.sentEventCount) 个事件")
                Text("·")
                Text("已接收 \(model.receivedEventCount) 个事件")
                Spacer()
                Text("Rust Core · UDP Discovery · TCP")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 620, minHeight: 580)
        .onAppear(perform: model.refreshPermission)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                model.refreshPermission()
            }
        }
    }

    private var peerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("附近的设备")
                    .font(.headline)
                Spacer()
                if model.peers.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if model.peers.isEmpty {
                ContentUnavailableView(
                    "正在发现设备",
                    systemImage: "network",
                    description: Text("请在另一台设备上启动 LinkCursor，并保持在同一局域网。")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ForEach(model.peers) { peer in
                    PeerRow(
                        peer: peer,
                        isConnected: model.sessions[peer.id]?.peer != nil,
                        isConnecting: model.sessions[peer.id]?.status == .connecting,
                        placement: model.placement(for: peer),
                        setPlacement: { model.setPlacement($0, for: peer) },
                        connect: { model.connect(to: peer) },
                        disconnect: { model.disconnect(peer) },
                        isPaired: model.isPaired(peer),
                        unpair: { model.unpair(peer) }
                    )
                    Divider()
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }
}

private struct HeaderView: View {
    let deviceName: String
    let coreState: CoreRunState
    let connectionState: ConnectionState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cursorarrow.rays")
                .font(.largeTitle)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("LinkCursor")
                    .font(.title2)
                    .bold()
                Text(deviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusPill(coreState: coreState, connectionState: connectionState)
        }
        .padding(22)
    }
}

private struct StatusPill: View {
    let coreState: CoreRunState
    let connectionState: ConnectionState

    private var label: String {
        if case let .connected(peer) = connectionState { return "已连接 · \(peer.name)" }
        if case .connecting = connectionState { return "正在连接" }
        if coreState == .running { return "正在运行" }
        if case .failed = coreState { return "Core 异常" }
        return "正在启动"
    }

    private var color: Color {
        if case .connected = connectionState { return .green }
        if case .failed = coreState { return .red }
        return .blue
    }

    var body: some View {
        Label(label, systemImage: "circle.fill")
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: .capsule)
    }
}

private struct PermissionCard: View {
    let isGranted: Bool
    let requestPermission: () -> Void
    let refreshPermission: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isGranted ? "checkmark.shield.fill" : "hand.raised.fill")
                .font(.title2)
                .foregroundStyle(isGranted ? .green : .orange)

            VStack(alignment: .leading, spacing: 3) {
                Text(isGranted ? "辅助功能权限已就绪" : "需要辅助功能权限")
                    .bold()
                Text("用于捕获本机输入，并发送给当前控制设备。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !isGranted {
                Button("授权", action: requestPermission)
                    .buttonStyle(.borderedProminent)
                Button("刷新", action: refreshPermission)
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }
}

private struct ConnectedControlCard: View {
    let peer: Peer?
    let placement: PeerPlacement
    let hasAccessibilityPermission: Bool
    let isControlling: Bool
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cursorarrow.motionlines")
                .font(.title2)
                .foregroundStyle(peer == nil ? Color.secondary : Color.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(peer.map { "输入目标：\($0.name)" } ?? "尚未连接控制目标")
                    .bold()
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isControlling {
                Button("释放控制", action: stop)
                    .buttonStyle(.borderedProminent)
            } else if peer != nil, placement.isEnabled, hasAccessibilityPermission {
                Label("自动切换已启用", systemImage: "arrow.right.to.line.compact")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }

    private var detailText: String {
        if isControlling {
            return "键鼠输入正在转发，按 ⌃⌥⎋ 释放"
        }
        if peer != nil, !placement.isEnabled {
            return "请在下方设备列表选择位置；位置决定从哪条边缘自动切换"
        }
        if peer != nil, placement.isEnabled, !hasAccessibilityPermission {
            return "授予辅助功能权限后，越过\(placement.edgeDescription)即可自动切换"
        }
        if peer != nil, placement.isEnabled {
            return "将鼠标越过\(placement.edgeDescription)，输入会自动切换到该设备"
        }
        return "连接设备并配置相对位置后，将自动启用边缘切换"
    }
}
