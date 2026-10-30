import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var model: AppModel
    @State private var addingDevice = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                notices

                SharingCard(
                    sharing: Binding(
                        get: { model.settings.sharing },
                        set: { enabled in model.updateSettings { $0.sharing = enabled } }
                    ),
                    detail: sharingDetail
                )

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("屏幕排列").font(.headline)
                    Text("拖动设备，按实际位置摆放").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("添加设备", systemImage: "plus") { addingDevice = true }
                }
                .padding(.top, 4)

                ArrangementView(
                    deviceName: model.deviceName,
                    local: model.localDisplays,
                    devices: model.arrangedDevices,
                    pointerOn: model.controlledPeerID,
                    place: { model.place($0, at: $1) }
                )

                if !model.transfers.isEmpty {
                    TransfersView(
                        transfers: model.transfers,
                        peerName: { id in
                            id.flatMap { id in model.visiblePeers.first { $0.id == id }?.name } ?? String(localized: "对方")
                        },
                        cancel: model.cancelTransfer
                    )
                }

                devices

                Text("按 ⌃⌥Esc 可随时回到本机。连接已加密。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(20)
        }
        .frame(minWidth: 480, maxWidth: 680, minHeight: 420, maxHeight: .infinity)
        .background(InitialWindowSize(CGSize(width: 540, height: 640)))
        .navigationTitle("LinkCursor")
        .modifier(CenteredTitle())
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink { Label("设置…", systemImage: "slider.horizontal.3") }
                    .help("设置…")
            }
        }
        .sheet(isPresented: $addingDevice) {
            AddDeviceSheet(
                addresses: model.settings.manualAddresses,
                status: model.status(of:),
                add: model.addManualAddress,
                remove: model.removeManualAddress
            )
        }
        .onAppear(perform: model.refreshPermission)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                model.refreshPermission()
            }
        }
    }

    /// Where the mouse is, in one line.
    private var sharingDetail: String {
        guard model.settings.sharing else { return String(localized: "鼠标只在本机移动") }
        if let id = model.controlledPeerID {
            let name = model.visiblePeers.first { $0.id == id }?.name ?? String(id.prefix(8))
            return String(localized: "鼠标正在 \(name) 上")
        }
        let connected = model.arrangedDevices.filter { $0.state == .connected }
        if connected.isEmpty { return String(localized: "等待其他设备连接") }
        if connected.allSatisfy({ $0.offset == nil }) { return String(localized: "把设备拖到屏幕旁边即可切换") }
        return String(localized: "鼠标在本机，越过屏幕边缘即可切换")
    }

    /// Only what needs the user: a failed start, an error, a lock, a
    /// missing permission. Nothing when all is well.
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
    }

    @ViewBuilder private var devices: some View {
        if model.visiblePeers.isEmpty {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在发现设备").font(.headline)
                    Text("请在另一台设备上启动 LinkCursor，并保持在同一局域网；没有出现时可以点“添加设备”。如果曾拒绝“本地网络”权限，请在“系统设置 › 隐私与安全性 › 本地网络”中允许 LinkCursor。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .card()
        } else {
            ForEach(model.visiblePeers) { peer in
                PeerRow(
                    peer: peer,
                    isConnected: model.sessions[peer.id]?.peer != nil,
                    isConnecting: model.sessions[peer.id]?.status == .connecting,
                    isOnline: model.peers.contains { $0.id == peer.id },
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
}

/// The one switch that matters, and where the mouse is.
private struct SharingCard: View {
    @Binding var sharing: Bool
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sharing ? "键鼠共享" : "键鼠共享已暂停").font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle(sharing ? "键鼠共享" : "键鼠共享已暂停", isOn: $sharing)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .card()
    }
}

extension View {
    /// A rounded box at the density of a grouped form.
    func card() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5))
            }
    }
}

/// The title in the middle of the title bar, as in a window without a
/// toolbar; the window keeps its title for the Window menu.
private struct CenteredTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            // Plain text, without the glass capsule toolbar items get.
            content
                .toolbar(removing: .title)
                .toolbar {
                    ToolbarItem(placement: .principal) { title }
                        .sharedBackgroundVisibility(.hidden)
                }
        } else if #available(macOS 15, *) {
            content
                .toolbar(removing: .title)
                .toolbar {
                    ToolbarItem(placement: .principal) { title }
                }
        } else {
            content
        }
    }

    private var title: some View {
        Text(verbatim: "LinkCursor").font(.headline)
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
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 8) { content }.card()
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
                Text(title).font(.headline).textSelection(.enabled)
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 10))
    }
}
