// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

@MainActor
final class ControlHUDController {
    private var panel: NSPanel?

    func show(peerName: String, stop: @escaping @MainActor () -> Void) {
        dismiss()

        let content = ControlHUDView(peerName: peerName, stop: stop)
        let hostingView = NSHostingView(rootView: content)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 74),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.maxY - panel.frame.height - 18
            ))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ControlHUDView: View {
    let peerName: String
    let stop: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cursorarrow.motionlines")
                .font(.title2)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("正在控制 \(peerName)")
                    .bold()
                Text("按 ⌃⌥⎋ 随时释放输入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("停止", action: stop)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .padding(6)
    }
}

