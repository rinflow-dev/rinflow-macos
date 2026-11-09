// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

@MainActor
final class ControlHUDController {
    private var panel: NSPanel?
    /// A short message (why the pointer stayed), apart from the control
    /// HUD so that ending the control does not take it away.
    private var noticePanel: NSPanel?
    private var noticeExpiry: DispatchWorkItem?

    func show(peerName: String, stop: @escaping @MainActor () -> Void) {
        dismiss()
        panel = Self.present(ControlHUDView(peerName: peerName, stop: stop), size: NSSize(width: 360, height: 74))
    }

    /// Shows `message` for a few seconds.
    func notice(_ message: String) {
        noticeExpiry?.cancel()
        noticePanel?.orderOut(nil)
        noticePanel = Self.present(NoticeView(message: message), size: NSSize(width: 420, height: 74))
        let expiry = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.noticePanel?.orderOut(nil)
                self?.noticePanel = nil
            }
        }
        noticeExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: expiry)
    }

    private static func present(_ content: some View, size: NSSize) -> NSPanel {
        let hostingView = NSHostingView(rootView: content)
        let fitting = hostingView.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: max(size.height, fitting.height)),
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
        return panel
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

private struct NoticeView: View {
    let message: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(width: 388, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .padding(6)
    }
}
