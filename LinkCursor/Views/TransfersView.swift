import SwiftUI

/// One card per transfer under way, either way: progress, "done of total"
/// and a cancel button.
struct TransfersView: View {
    let transfers: [FileTransfer]
    let peerName: (String?) -> String
    let cancel: (FileTransfer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("文件传输")
                .font(.headline)
            ForEach(transfers) { transfer in
                TransferCard(transfer: transfer, peerName: peerName(transfer.peerID)) {
                    cancel(transfer)
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }
}

private struct TransferCard: View {
    let transfer: FileTransfer
    let peerName: String
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.direction == .receiving ? "arrow.down.doc" : "arrow.up.doc")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: transfer.fraction)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button("取消", action: cancel)
                .buttonStyle(.bordered)
        }
    }

    private var title: String {
        let name = transfer.name.isEmpty ? String(localized: "文件") : transfer.name
        let more = transfer.items > 1 ? String(localized: " 等 \(transfer.items) 项") : ""
        return transfer.direction == .receiving
            ? String(localized: "正在从 \(peerName) 接收 \(name)\(more)")
            : String(localized: "正在发送 \(name)\(more) 到 \(peerName)")
    }

    private var detail: String {
        let done = ByteCountFormatter.string(fromByteCount: Int64(transfer.done), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(transfer.total), countStyle: .file)
        let percent = Int((transfer.fraction * 100).rounded())
        return "\(done) / \(total) · \(percent)%"
    }
}
