import SwiftUI

struct PeerRow: View {
    let peer: Peer
    let isConnected: Bool
    let isConnecting: Bool
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
        HStack(spacing: 12) {
            Image(systemName: peer.platform == "android" ? "iphone" : "desktopcomputer")
                .font(.title2)
                .frame(width: 34, height: 34)
                .background(.quaternary, in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                    .bold()
                Text(verbatim: "\(peer.address):\(peer.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if isPaired {
                    Label("已配对", systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            Spacer()

            Button {
                showsInput = true
            } label: {
                Image(systemName: input.isDefault ? "computermouse" : "computermouse.fill")
            }
            .buttonStyle(.borderless)
            .help("指针与滚动")
            .popover(isPresented: $showsInput, arrowEdge: .bottom) {
                PeerInputView(peerName: peer.name, input: input, setInput: setInput)
            }

            VStack(alignment: .trailing, spacing: 6) {
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
                .frame(width: 150)

                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                } else if isConnected {
                    Button("断开", action: disconnect)
                        .buttonStyle(.bordered)
                } else {
                    Button("连接", systemImage: "link", action: connect)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 6)
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
