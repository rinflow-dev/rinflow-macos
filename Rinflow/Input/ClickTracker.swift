// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Foundation

/// CGEvent mouse events do not infer double/triple clicks. Down and up
/// must carry the same click count, derived from time and position.
struct ClickTracker {
    private var button: UInt32?
    private var position = CGPoint.zero
    private var time = 0.0
    private var count: Int64 = 0
    private var active: [UInt32: Int64] = [:]

    mutating func click(button: UInt32, down: Bool, at point: CGPoint,
                        time now: TimeInterval, interval: TimeInterval) -> Int64 {
        guard down else { return active.removeValue(forKey: button) ?? 1 }
        if self.button == button, now >= time, now - time <= interval,
           abs(point.x - position.x) <= 4, abs(point.y - position.y) <= 4 {
            count = min(count + 1, 3)
        } else {
            count = 1
        }
        self.button = button
        position = point
        time = now
        active[button] = count
        return count
    }
}
