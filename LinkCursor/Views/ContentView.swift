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
                    if case let .failed(reason) = model.coreState {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("连接服务未能启动", systemImage: "exclamationmark.triangle")
                                .font(.headline)
                            Text(reason).font(.callout).textSelection(.enabled)
                            Text("请确认没有其他 LinkCursor 正在运行，然后重试。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("重试", action: model.startCore)
                        }
                    }
                    HStack {
                        Label(model.settings.sharing ? "键鼠共享已开启" : "键鼠共享已暂停",
                              systemImage: model.settings.sharing ? "keyboard" : "pause.circle")
                        Spacer()
                        Button(model.settings.sharing ? "暂停共享" : "恢复共享") {
                            model.updateSettings { $0.sharing.toggle() }
                        }
                        SettingsLink { Label("设置…", systemImage: "gearshape") }
                    }
                    if model.pointerLocked {
                        HStack {
                            Label("指针已锁定在当前屏幕", systemImage: "lock.fill")
                            Spacer()
                            Button("解锁（⌃⌥L）", action: model.togglePointerLock)
                        }
                        .foregroundStyle(.orange)
                    }

                    if let lastError = model.lastError {
                        HStack(alignment: .firstTextBaseline) {
                            Label(lastError, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.callout)
                                .textSelection(.enabled)
                            Spacer()
                            Button("关闭", action: model.dismissError)
                                .buttonStyle(.borderless)
                        }
                    }

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
                        sharing: model.settings.sharing,
                        pointerLocked: model.pointerLocked,
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

                    if !model.transfers.isEmpty {
                        TransfersView(
                            transfers: model.transfers,
                            peerName: { id in
                                id.flatMap { id in model.peers.first { $0.id == id }?.name } ?? String(localized: "对方")
                            },
                            cancel: model.cancelTransfer
                        )
                    }

                    peerSection

                    ManualAddressesView(
                        addresses: model.settings.manualAddresses,
                        status: model.status(of:),
                        add: model.addManualAddress,
                        remove: model.removeManualAddress
                    )

                }
                .padding(22)
            }

            Divider()

            HStack {
                Text("按 ⌃⌥⎋ 随时释放控制")
                Spacer()
                Label("连接已加密", systemImage: "lock.shield")
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
                Text("我的设备与附近设备")
                    .font(.headline)
                Spacer()
                if model.visiblePeers.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if model.visiblePeers.isEmpty {
                ContentUnavailableView(
                    "正在发现设备",
                    systemImage: "network",
                    description: Text("请在另一台设备上启动 LinkCursor，并保持在同一局域网；没有出现时可以在下方通过地址添加。")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ForEach(model.visiblePeers) { peer in
                    PeerRow(
                        peer: peer,
                        isConnected: model.sessions[peer.id]?.peer != nil,
                        isConnecting: model.sessions[peer.id]?.status == .connecting,
                        isOnline: model.peers.contains { $0.id == peer.id },
                        placement: model.placement(for: peer),
                        setPlacement: { model.setPlacement($0, for: peer) },
                        connect: { model.connect(to: peer) },
                        disconnect: { model.disconnect(peer) },
                        isPaired: model.isPaired(peer),
                        unpair: { model.unpair(peer) },
                        input: model.settings.input(for: peer.id),
                        setInput: { model.setInput($0, for: peer.id) }
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
        if case let .connected(peer) = connectionState { return String(localized: "已连接 · \(peer.name)") }
        if case .connecting = connectionState { return String(localized: "正在连接") }
        if coreState == .running { return String(localized: "正在运行") }
        if coreState == .stopped { return String(localized: "已停止") }
        if case .failed = coreState { return String(localized: "Core 异常") }
        return String(localized: "正在启动")
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
                Text("用于共享本机键鼠，以及接收其他设备的控制。")
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
    let sharing: Bool
    let pointerLocked: Bool
    let isControlling: Bool
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cursorarrow.motionlines")
                .font(.title2)
                .foregroundStyle(peer == nil ? Color.secondary : Color.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(peer.map { String(localized: "输入目标：\($0.name)") } ?? String(localized: "尚未连接控制目标"))
                    .bold()
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isControlling {
                Button("释放控制", action: stop)
                    .buttonStyle(.borderedProminent)
            } else if sharing, !pointerLocked, peer != nil, placement.isEnabled, hasAccessibilityPermission {
                Label("自动切换已启用", systemImage: "arrow.right.to.line.compact")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }

    private var detailText: String {
        if !sharing { return String(localized: "键鼠共享已暂停，可在上方恢复。") }
        if pointerLocked { return String(localized: "指针已锁定在当前屏幕") }
        if isControlling {
            return String(localized: "键鼠输入正在转发，按 ⌃⌥⎋ 释放")
        }
        if peer != nil, !placement.isEnabled {
            return String(localized: "请在下方设备列表选择位置；位置决定从哪条边缘自动切换")
        }
        if peer != nil, placement.isEnabled, !hasAccessibilityPermission {
            return String(localized: "授予辅助功能权限后，越过\(placement.edgeDescription)即可自动切换")
        }
        if peer != nil, placement.isEnabled {
            return String(localized: "将鼠标越过\(placement.edgeDescription)，输入会自动切换到该设备")
        }
        return String(localized: "连接设备并配置相对位置后，将自动启用边缘切换")
    }
}
