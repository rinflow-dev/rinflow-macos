import SwiftUI

struct PeerRow: View {
    let peer: Peer
    let isConnected: Bool
    let isConnecting: Bool
    let isOnline: Bool
    let placement: PeerPlacement
    let setPlacement: (PeerPlacement) -> Void
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
                .font(.body)
                .foregroundStyle(isConnected ? Color.accentColor : .secondary)
                .frame(width: 26, height: 26)
                .background(.quaternary, in: .rect(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(peer.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if isPaired {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .help("已配对")
                            .accessibilityLabel("已配对")
                    }
                }
                Text(!isOnline && !isConnected
                     ? String(localized: "离线 · 设备回来后自动重连")
                     : peer.address == "incoming"
                     ? String(localized: "由对方发起的连接") : "\(peer.address):\(peer.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            Button {
                showsInput = true
            } label: {
                Image(systemName: input.isDefault ? "computermouse" : "computermouse.fill")
            }
            .buttonStyle(.borderless)
            .help("指针与滚动")
            .accessibilityLabel("指针与滚动")
            .popover(isPresented: $showsInput, arrowEdge: .bottom) {
                PeerInputView(peerName: peer.name, input: input, setInput: setInput)
            }

            HStack(spacing: 6) {
                Picker(
                    "位置",
                    selection: Binding(
                        get: { placement },
                        set: { newValue in setPlacement(newValue) }
                    )
                ) {
                    ForEach(placement == .chained ? PeerPlacement.choices + [.chained] : PeerPlacement.choices) {
                        Label($0.label, systemImage: $0.systemImage)
                            .tag($0)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 130)

                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 56)
                } else if isConnected {
                    Button("断开", action: disconnect)
                        .buttonStyle(.bordered)
                } else {
                    Button("连接", systemImage: "link", action: connect)
                        .buttonStyle(.borderedProminent)
                        .disabled(!isOnline)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 5)
        .contextMenu {
            if isPaired {
                Button("取消配对", role: .destructive, action: unpair)
            }
        }
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
