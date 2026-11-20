// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

@MainActor
final class ControlHUDController {
    private var panel: Popup?
    /// What the panel shows: the same again keeps it as it is. By the
    /// device's ID, as two devices may have one name.
    private var shown: Shown?
    private struct Shown: Equatable {
        let peerID: String
        let name: String
        let platform: String?
    }
    /// A short message (why the pointer stayed), apart from the control
    /// HUD so that ending the control does not take it away.
    private var noticePanel: Popup?
    private var noticeExpiry: DispatchWorkItem?

    /// `platform` picks the device's symbol, as in the arrangement.
    func show(peerID: String, name: String, platform: String?, stop: @escaping @MainActor () -> Void) {
        let next = Shown(peerID: peerID, name: name, platform: platform)
        guard next != shown || panel == nil else { return }
        dismiss()
        shown = next
        panel = Popup(ControlHUDView(
            peerName: name, symbol: ArrangedDevice.symbol(for: platform), stop: stop
        ))
    }

    /// Shows `message` for a few seconds.
    func notice(_ message: String) {
        noticeExpiry?.cancel()
        noticePanel?.hide()
        noticePanel = Popup(NoticeView(message: message))
        let expiry = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.noticePanel?.hide()
                self?.noticePanel = nil
            }
        }
        noticeExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: expiry)
    }

    func dismiss() {
        panel?.hide()
        panel = nil
        shown = nil
    }
}

/// A panel at the top middle of the screen whose content pops in and out
/// the way system banners do. The window stays put; only its content moves,
/// on Core Animation's clock: grown from the top edge with a spring, and
/// drawn back into it.
@MainActor
private final class Popup {
    @Observable
    final class State {
        var shown = false
    }

    private let panel: NSPanel
    private let state = State()

    init(_ content: some View) {
        let hostingView = NSHostingView(rootView: PopIn(state: state, content: content))
        let size = hostingView.fittingSize
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        let visible = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 14))
        panel.orderFrontRegardless()
        // After the first frame, drawn hidden, so the change animates.
        DispatchQueue.main.async { [state] in
            withAnimation(.spring(response: 0.42, dampingFraction: 0.68)) { state.shown = true }
        }
    }

    func hide() {
        let panel = panel
        withAnimation(.spring(response: 0.26, dampingFraction: 1), completionCriteria: .removed) {
            state.shown = false
        } completion: {
            panel.orderOut(nil)
        }
    }
}

private struct PopIn<Content: View>: View {
    let state: Popup.State
    let content: Content

    var body: some View {
        content
            .scaleEffect(state.shown ? 1 : 0.6, anchor: .top)
            .offset(y: state.shown ? 0 : -12)
            .opacity(state.shown ? 1 : 0)
    }
}

/// A capsule: the device's symbol, who is being controlled, and the way
/// back (the release shortcut, also a button).
private struct ControlHUDView: View {
    let peerName: String
    let symbol: String
    let stop: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.accentColor, in: .circle)

            HStack(spacing: 6) {
                Text("正在控制").foregroundStyle(.secondary)
                Text(peerName).fontWeight(.semibold).lineLimit(1)
            }
            .font(.system(size: 14))

            Button(action: stop) {
                HStack(spacing: 4) {
                    Text(verbatim: "⌃⌥Esc")
                    Text("返回")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.1), in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .help("释放输入，回到这台 Mac")
        }
        .padding(.leading, 6)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay { Capsule().fill(Color.black.opacity(0.3)) }
                .overlay { Capsule().strokeBorder(.white.opacity(0.1)) }
        }
        .environment(\.colorScheme, .dark)
        .fixedSize()
        // Room for the shadow inside the borderless panel.
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .padding(14)
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
        .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
        .padding(14)
    }
}
