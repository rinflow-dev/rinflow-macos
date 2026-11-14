// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// What macOS will ask for, and why, before it asks, and whether to share
/// anonymous diagnostics. Shown over the main window whenever it opens
/// without the Accessibility permission (the first launch, or after the
/// permission was taken away), or before the user chose about diagnostics
/// (also after updating from a version without them).
struct PermissionGuide: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Off unless the user turns it on; saved however the sheet closes.
    @State private var shareDiagnostics: Bool

    private var granted: Bool { model.hasAccessibilityPermission }

    init(model: AppModel) {
        self.model = model
        _shareDiagnostics = State(initialValue: model.settings.diagnostics ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("欢迎使用 Rinflow").font(.title2.bold())
                    Text("开始之前，请先允许 Rinflow 使用下面的权限。")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                step(
                    symbol: granted ? "checkmark.circle.fill" : "hand.raised.fill",
                    tint: granted ? .green : .orange,
                    title: "辅助功能",
                    detail: "用来把这台 Mac 的键盘和鼠标共享给其他设备，也让其他设备控制这台 Mac。键入的内容只发给你正在控制的设备，不会被保存。"
                ) {
                    if granted {
                        Text("已允许").foregroundStyle(.green)
                    } else {
                        Button("打开系统设置", action: model.requestPermission)
                            .buttonStyle(.borderedProminent)
                        Text("在“隐私与安全性 › 辅助功能”里打开 Rinflow 的开关，这里会自动更新。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // macOS 14 does not ask for the local network.
                if #available(macOS 15, *) {
                    Divider()
                    step(
                        symbol: "network",
                        tint: .accentColor,
                        title: "本地网络",
                        detail: "用来发现同一网络中的其他设备。macOS 询问时请点“允许”。"
                    ) {}
                }
                Divider()
                step(
                    symbol: "chart.bar.xaxis",
                    tint: .accentColor,
                    title: "帮助改进 Rinflow",
                    detail: "每小时匿名发送连接断开的原因、丢包和延迟统计，不含设备名称、地址或任何内容。可以随时在设置里关闭。"
                ) {
                    Toggle("共享匿名诊断数据", isOn: $shareDiagnostics)
                }
            }
            .card()

            HStack {
                Spacer()
                Button(granted ? "开始使用" : "稍后设置") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onDisappear {
            model.updateSettings { $0.diagnostics = shareDiagnostics }
        }
        .task {
            // The switch is flipped in System Settings, which tells no one.
            while !Task.isCancelled, !model.hasAccessibilityPermission {
                try? await Task.sleep(for: .seconds(1))
                model.refreshPermission()
            }
        }
    }

    private func step(
        symbol: String,
        tint: Color,
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        @ViewBuilder action: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                action()
            }
        }
    }
}
