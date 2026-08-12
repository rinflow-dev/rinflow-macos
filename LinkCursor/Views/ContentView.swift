import SwiftUI

struct ContentView: View {
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
                        isControlling: model.isControlling,
                        start: model.startControlling,
                        stop: model.stopControlling
                    )

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
                    description: Text("请在另一台 Mac 上启动 LinkCursor，并保持在同一局域网。")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ForEach(model.peers) { peer in
                    PeerRow(
                        peer: peer,
                        isConnected: model.connectionState.connectedPeer?.id == peer.id,
                        isConnecting: isConnecting(peer),
                        connect: { model.connect(to: peer) },
                        disconnect: model.disconnect
                    )
                    Divider()
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }

    private func isConnecting(_ peer: Peer) -> Bool {
        if case let .connecting(peerID) = model.connectionState {
            peerID == peer.id
        } else {
            false
        }
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
                Text("用于捕获本机输入，并在被控 Mac 上注入键鼠事件。")
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
    let isControlling: Bool
    let start: () -> Void
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cursorarrow.motionlines")
                .font(.title2)
                .foregroundStyle(peer == nil ? Color.secondary : Color.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(peer.map { "输入目标：\($0.name)" } ?? "尚未连接控制目标")
                    .bold()
                Text(isControlling ? "键鼠输入正在转发，按 ⌃⌥⎋ 释放" : "连接后可手动开始转发输入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(isControlling ? "停止控制" : "开始控制", action: isControlling ? stop : start)
                .buttonStyle(.borderedProminent)
                .disabled(peer == nil)
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }
}
