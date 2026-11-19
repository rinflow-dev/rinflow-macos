// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

/// Shows each of this Mac's displays its number for a few seconds, as
/// Identify does in Windows' display settings: `first` on the first display,
/// then on in the order of `AppModel.localDisplays` (the order the core and
/// peers know them in). From 1 when the user asks here, from what a peer
/// gives when its user asks there.
@MainActor
final class DisplayIdentifier {
    private var panels: [NSPanel] = []
    private var expiry: DispatchWorkItem?

    func show(first: Int) {
        dismiss()
        for (index, screen) in NSScreen.screens.filter({ $0.displayID != nil }).enumerated() {
            panels.append(Self.panel(number: first + index, on: screen))
        }
        let expiry = DispatchWorkItem { [weak self] in self?.dismiss() }
        self.expiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: expiry)
    }

    func dismiss() {
        expiry?.cancel()
        expiry = nil
        for panel in panels { panel.orderOut(nil) }
        panels = []
    }

    /// In the bottom right corner of every screen, clear of the Dock.
    private static func panel(number: Int, on screen: NSScreen) -> NSPanel {
        let size = NSSize(width: DisplayNumber.side, height: DisplayNumber.side)
        let frame = screen.visibleFrame
        let margin: CGFloat = 24
        let panel = NSPanel(
            contentRect: NSRect(x: frame.maxX - size.width - margin, y: frame.minY + margin,
                                width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: DisplayNumber(number: number))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.orderFrontRegardless()
        return panel
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// A white number on a translucent dark square, as Windows shows it.
private struct DisplayNumber: View {
    static let side: CGFloat = 260
    let number: Int

    var body: some View {
        Text(verbatim: "\(number)")
            .font(.system(size: 170, weight: .regular))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: Self.side, height: Self.side)
            .background(Color.black.opacity(0.45), in: .rect(cornerRadius: 6))
    }
}
