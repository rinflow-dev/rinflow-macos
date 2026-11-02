import SwiftUI

/// One device: what it is, where it is, connect or disconnect. Its pointer
/// settings and unpairing are in the More menu (and the context menu).
/// Where it sits is set by dragging it on the arrangement canvas.
struct PeerRow: View {
    let peer: Peer
    let isConnected: Bool
    let isConnecting: Bool
    let isOnline: Bool
    let connect: () -> Void
    let disconnect: () -> Void
    let isPaired: Bool
    let unpair: () -> Void
    let input: PeerInput
    let setInput: (PeerInput) -> Void

    @State private var showsInput = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: peer.platform == "android" ? "iphone" : "desktopcomputer")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(peer.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            Group {
                if isConnecting {
                    ProgressView().controlSize(.small)
                } else if isConnected {
                    Button("断开连接", action: disconnect)
                } else {
                    Button("连接", action: connect)
                        .disabled(!isOnline)
                }
            }

            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多")
            .accessibilityLabel("更多")
            .popover(isPresented: $showsInput, arrowEdge: .bottom) {
                PeerInputView(peerName: peer.name, input: input, setInput: setInput)
            }
        }
        .card()
        .contextMenu { menuItems }
    }

    @ViewBuilder private var menuItems: some View {
        Button("指针与滚动…") { showsInput = true }
        if isPaired {
            Divider()
            Button("取消配对", role: .destructive, action: unpair)
        }
    }

    /// Where it is, or that it is not there. Whether it is connected is
    /// the button's to say.
    private var detail: String {
        guard isConnected || isConnecting || isOnline else { return String(localized: "离线") }
        return peer.address == "incoming" ? String(localized: "由对方发起的连接") : peer.address
    }
}

/// How this Mac's mouse feels on one peer. Applied here, as this Mac drives
/// the peer, so both sides agree where the pointer is.
private struct PeerInputView: View {
    let peerName: String
    let input: PeerInput
    let setInput: (PeerInput) -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("指针速度") {
                    Slider(value: binding(\.pointerSpeed), in: PeerInput.pointerSpeeds, step: 0.25) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text(verbatim: "0.25×")
                    } maximumValueLabel: {
                        Text(verbatim: "4×")
                    }
                }
                LabeledContent("滚动速度") {
                    Slider(value: binding(\.scrollSpeed), in: PeerInput.scrollSpeeds, step: 0.25) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text(verbatim: "0.25×")
                    } maximumValueLabel: {
                        Text(verbatim: "5×")
                    }
                }
                Toggle("反转滚动方向", isOn: binding(\.invertScroll))
            } header: {
                Text("在 \(peerName) 上")
            } footer: {
                HStack {
                    Text(verbatim: String(format: "%.2f× · %.2f×", input.pointerSpeed, input.scrollSpeed))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复默认") { setInput(PeerInput()) }
                        .disabled(input.isDefault)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
    }

    private func binding<Value>(_ path: WritableKeyPath<PeerInput, Value>) -> Binding<Value> {
        Binding(
            get: { input[keyPath: path] },
            set: { value in
                var next = input
                next[keyPath: path] = value
                setInput(next)
            }
        )
    }
}
