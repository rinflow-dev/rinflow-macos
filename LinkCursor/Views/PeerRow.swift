import SwiftUI

struct PeerRow: View {
    let peer: Peer
    let isConnected: Bool
    let isConnecting: Bool
    let connect: () -> Void
    let disconnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
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
            }

            Spacer()

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
        .padding(.vertical, 6)
    }
}

