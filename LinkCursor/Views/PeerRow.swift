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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: peer.platform == "android" ? "iphone" : "desktopcomputer")
                .font(.title2)
                .frame(width: 34, height: 34)
                .background(.quaternary, in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                    .bold()
                Text("\(peer.address):\(peer.port)")
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

            VStack(alignment: .trailing, spacing: 6) {
                Picker(
                    "位置",
                    selection: Binding(
                        get: { placement },
                        set: { newValue in setPlacement(newValue) }
                    )
                ) {
                    ForEach(PeerPlacement.allCases) { placement in
                        Label(placement.label, systemImage: placement.systemImage)
                            .tag(placement)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 140)

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
