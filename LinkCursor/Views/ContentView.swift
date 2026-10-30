import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    notices

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

                    SectionBox("排列", note: "拖动设备决定从哪条边缘切换过去；拖出画布即取消放置。两端的排列会自动同步。") {
                        ArrangementView(
                            deviceName: model.deviceName,
                            local: model.localDisplays,
                            devices: model.arrangedDevices,
                            place: { model.place($0, at: $1) }
                        )
                    }

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
                }
                .padding(16)
            }

            Divider()

            HStack {
                Text("按 ⌃⌥⎋ 随时释放控制")
                Spacer()
                Label("连接已加密", systemImage: "lock.shield")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        // A utility window: wider only spreads the rows. The width cap also
        // shrinks a larger frame the system remembered.
        .frame(minWidth: 520, maxWidth: 720, minHeight: 440, maxHeight: .infinity)
        .navigationTitle("LinkCursor")
        .navigationSubtitle(model.deviceName)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                StatusPill(coreState: model.coreState, connectionState: model.connectionState)
                Button {
                    model.updateSettings { $0.sharing.toggle() }
                } label: {
                    Label(model.settings.sharing ? "暂停共享" : "恢复共享",
                          systemImage: model.settings.sharing ? "pause.circle" : "play.circle")
                }
                .help(model.settings.sharing ? "暂停共享" : "恢复共享")
                SettingsLink { Label("设置…", systemImage: "gearshape") }
                    .help("设置…")
            }
        }
        .background(InitialWindowSize(CGSize(width: 600, height: 620)))
        .onAppear(perform: model.refreshPermission)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                model.refreshPermission()
            }
        }
    }

    /// Only what needs the user: a failed start, an error, a lock, a
    /// missing permission, paused sharing. Nothing when all is well.
    @ViewBuilder private var notices: some View {
        if case let .failed(reason) = model.coreState {
            Notice(symbol: "exclamationmark.triangle.fill", tint: .red,
                   title: "连接服务未能启动",
                   detail: "\(reason)\n" + String(localized: "请确认没有其他 LinkCursor 正在运行，然后重试。")) {
                Button("重试", action: model.startCore)
            }
        }
        if let lastError = model.lastError {
            Notice(symbol: "exclamationmark.triangle.fill", tint: .orange, title: lastError) {
                Button("关闭", action: model.dismissError).buttonStyle(.borderless)
            }
        }
        if !model.hasAccessibilityPermission {
            Notice(symbol: "hand.raised.fill", tint: .orange, title: "需要辅助功能权限",
                   detail: String(localized: "用于共享本机键鼠，以及接收其他设备的控制。")) {
                Button("授权", action: model.requestPermission).buttonStyle(.borderedProminent)
                Button("刷新", action: model.refreshPermission)
            }
        }
        if model.pointerLocked {
            Notice(symbol: "lock.fill", tint: .orange, title: "指针已锁定在当前屏幕") {
                Button("解锁（⌃⌥L）", action: model.togglePointerLock)
            }
        }
        if !model.settings.sharing {
            Notice(symbol: "pause.circle.fill", tint: .secondary, title: "键鼠共享已暂停") {
                Button("恢复共享") { model.updateSettings { $0.sharing = true } }
            }
        }
    }

    private var peerSection: some View {
        SectionBox("我的设备与附近设备", accessory: model.visiblePeers.isEmpty ? AnyView(ProgressView().controlSize(.small)) : nil) {
            if model.visiblePeers.isEmpty {
                ContentUnavailableView(
                    "正在发现设备",
                    systemImage: "network",
                    description: Text("请在另一台设备上启动 LinkCursor，并保持在同一局域网；没有出现时可以在下方通过地址添加。如果曾拒绝“本地网络”权限，请在“系统设置 › 隐私与安全性 › 本地网络”中允许 LinkCursor。")
                )
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.visiblePeers.enumerated()), id: \.element.id) { index, peer in
                        if index > 0 { Divider() }
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
                    }
                }
            }
            Divider()
            ManualAddressesView(
                addresses: model.settings.manualAddresses,
                status: model.status(of:),
                add: model.addManualAddress,
                remove: model.removeManualAddress
            )
        }
    }
}

/// SwiftUI on macOS 26 ignores the scene's `defaultSize` here and opens
/// the window at a size of its own (683×653). The window is not autosaved,
/// so each time it opens it is sized once, when it first gets a window.
private struct InitialWindowSize: NSViewRepresentable {
    let size: CGSize

    init(_ size: CGSize) { self.size = size }

    func makeNSView(context: Context) -> NSView { Probe(size: size) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        let size: CGSize
        private var sized = false

        init(size: CGSize) {
            self.size = size
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !sized, let window else { return }
            sized = true
            DispatchQueue.main.async { [size] in
                window.setContentSize(size)
                window.center()
            }
        }
    }
}

/// A titled group, at the density of a grouped form: a small heading
/// outside, the content in a rounded box.
struct SectionBox<Content: View>: View {
    let title: LocalizedStringKey
    var note: LocalizedStringKey?
    var accessory: AnyView?
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, note: LocalizedStringKey? = nil, accessory: AnyView? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                if let note {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help(Text(note))
                        .accessibilityLabel(Text(note))
                }
                Spacer()
                accessory
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 10))
        }
    }
}

/// One line that asks for attention, with its actions on the right.
private struct Notice<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String?
    @ViewBuilder let actions: Actions

    init(symbol: String, tint: Color, title: LocalizedStringResource, detail: String? = nil,
         @ViewBuilder actions: () -> Actions) {
        self.init(symbol: symbol, tint: tint, title: String(localized: title), detail: detail, actions: actions)
    }

    init(symbol: String, tint: Color, title: String, detail: String? = nil,
         @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.detail = detail
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium)).textSelection(.enabled)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            actions.controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 8))
    }
}

private struct StatusPill: View {
    let coreState: CoreRunState
    let connectionState: ConnectionState

    /// Short, so the toolbar does not set the window's width: the peer's
    /// name is in the input-target row and in the help tag.
    private var label: String {
        if case .connected = connectionState { return String(localized: "已连接") }
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
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: .capsule)
            .fixedSize()
            .help(help)
    }

    private var help: String {
        if case let .connected(peer) = connectionState { return String(localized: "已连接 · \(peer.name)") }
        return label
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
        HStack(spacing: 10) {
            Image(systemName: "cursorarrow.motionlines")
                .foregroundStyle(peer == nil ? Color.secondary : Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(peer.map { String(localized: "输入目标：\($0.name)") } ?? String(localized: "尚未连接控制目标"))
                    .font(.callout.weight(.medium))
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isControlling {
                Button("释放控制", action: stop)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else if sharing, !pointerLocked, peer != nil, placement.isEnabled, hasAccessibilityPermission {
                Label("自动切换已启用", systemImage: "arrow.right.to.line.compact")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
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
