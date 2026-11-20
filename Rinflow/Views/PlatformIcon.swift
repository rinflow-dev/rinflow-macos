// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The logo of the system a device runs (the platform it announces), or, for
/// `unknown` (a KVM and the like), a box on the network. While the device is
/// there, each is in the colors it is known by: Windows and Android (template
/// images) in their brand color, Tux in its own, and the one-color ones (the
/// Apple logo, the box) in the label's. While it is not, all are gray. Each
/// is sized so that all look about as large as one another at `size`.
struct PlatformIcon: View {
    let platform: String?
    var size: CGFloat = 17
    var isOnline = true

    var body: some View {
        switch platform {
        case "macos": Image(systemName: "apple.logo").font(.system(size: size + 2)).foregroundStyle(tint(.primary))
        case "windows": logo("PlatformWindows", side: size - 2).foregroundStyle(tint(Self.windowsBlue))
        case "linux": logo("PlatformLinux", side: size + 3).saturation(isOnline ? 1 : 0).opacity(isOnline ? 1 : 0.5)
        case "android": logo("PlatformAndroid", side: size + 1).foregroundStyle(tint(Self.androidGreen))
        default: Image(systemName: "rectangle.connected.to.line.below").font(.system(size: size)).foregroundStyle(tint(.primary))
        }
    }

    private static let windowsBlue = Color(red: 0, green: 0x78 / 255, blue: 0xD4 / 255)
    private static let androidGreen = Color(red: 0x3D / 255, green: 0xDC / 255, blue: 0x84 / 255)

    private func tint(_ style: some ShapeStyle) -> AnyShapeStyle {
        isOnline ? AnyShapeStyle(style) : AnyShapeStyle(.secondary)
    }

    private func logo(_ name: String, side: CGFloat) -> some View {
        Image(name).resizable().scaledToFit().frame(width: side, height: side)
    }
}
