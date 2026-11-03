// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// One card per transfer under way, either way: progress, "done of total"
/// and a cancel button.
struct TransfersView: View {
    let transfers: [FileTransfer]
    let peerName: (String?) -> String
    let cancel: (FileTransfer) -> Void

    var body: some View {
        SectionBox("文件传输") {
            ForEach(transfers) { transfer in
                TransferCard(transfer: transfer, peerName: peerName(transfer.peerID)) {
                    cancel(transfer)
                }
            }
        }
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
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button("取消", action: cancel)
                .buttonStyle(.bordered)
        }
    }

    private var title: String {
        let name = transfer.name.isEmpty ? String(localized: "文件") : transfer.name
        // Whole sentences: word order differs too much between languages to
        // assemble one from pieces.
        let items = transfer.items
        return switch (transfer.direction, items > 1) {
        case (.receiving, false): String(localized: "正在从 \(peerName) 接收 \(name)")
        case (.receiving, true): String(localized: "正在从 \(peerName) 接收 \(name) 等 \(items) 项")
        case (.sending, false): String(localized: "正在发送 \(name) 到 \(peerName)")
        case (.sending, true): String(localized: "正在发送 \(name) 等 \(items) 项到 \(peerName)")
        }
    }

    private var detail: String {
        let done = ByteCountFormatter.string(fromByteCount: Int64(clamping: transfer.done), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(clamping: transfer.total), countStyle: .file)
        return "\(done) / \(total)"
    }
}
