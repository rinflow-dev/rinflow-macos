// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The logo of the system a device runs (the platform it announces), or, for
/// `unknown` (a KVM and the like), a box on the network. Template images, so
/// they take the foreground style like SF Symbols. Each is sized so that all
/// look about as large as one another at `size`.
struct PlatformIcon: View {
    let platform: String?
    var size: CGFloat = 17

    var body: some View {
        switch platform {
        case "macos": Image(systemName: "apple.logo").font(.system(size: size + 2))
        case "windows": logo("PlatformWindows", side: size - 2)
        case "linux": logo("PlatformLinux", side: size + 1)
        case "android": logo("PlatformAndroid", side: size + 1)
        default: Image(systemName: "rectangle.connected.to.line.below").font(.system(size: size))
        }
    }

    private func logo(_ name: String, side: CGFloat) -> some View {
        Image(name).resizable().scaledToFit().frame(width: side, height: side)
    }
}
