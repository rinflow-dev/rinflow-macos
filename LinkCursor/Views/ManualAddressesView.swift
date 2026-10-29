import SwiftUI

/// Adding a device by its address, for networks that do not carry the
/// discovery multicast (guest and company Wi-Fi, other subnets, VPNs). Only
/// one of the two devices needs the other's address.
struct ManualAddressesView: View {
    let addresses: [String]
    let status: (String) -> ManualAddressStatus
    /// Returns why the address cannot be added, or nil when it was.
    let add: (String) -> String?
    let remove: (String) -> Void

    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("通过地址添加设备")
                .font(.headline)
            Text("设备没有自动出现时（访客或公司网络、不同网段、VPN），输入它的 IP 地址或设备名称。只需在其中一台设备上添加。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("例如 192.168.1.20 或 mac-mini.local", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button("添加", action: submit)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ForEach(addresses, id: \.self) { address in
                AddressRow(status: status(address)) { remove(address) }
            }
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }

    private func submit() {
        problem = add(text)
        if problem == nil {
            text = ""
        }
    }
}

private struct AddressRow: View {
    let status: ManualAddressStatus
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: status.address)
                    .textSelection(.enabled)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive, action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("移除这个地址")
        }
    }

    private var description: String {
        switch status.status {
        case .searching: String(localized: "正在查找…")
        case .found: String(localized: "已找到 \(status.name ?? status.peerID ?? "")")
        case .noResponse: String(localized: "没有响应：确认对方已打开 LinkCursor，且防火墙允许 UDP 42420–42421")
        case .unresolved: String(localized: "无法解析这个名称：\(status.error ?? "")")
        }
    }

    private var symbol: String {
        switch status.status {
        case .searching: "magnifyingglass"
        case .found: "checkmark.circle.fill"
        case .noResponse: "exclamationmark.circle"
        case .unresolved: "xmark.circle"
        }
    }

    private var color: Color {
        switch status.status {
        case .searching: .secondary
        case .found: .green
        case .noResponse, .unresolved: .orange
        }
    }
}
