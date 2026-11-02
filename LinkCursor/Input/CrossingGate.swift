// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// When a push against a portal crosses, as on Windows (`edge.rs`): the
/// pointer must be pushed `distance` points past the edge and the switch
/// delay must be up. A push that went far enough crosses when the delay is
/// up even if the pointer holds still meanwhile (the caller's timer asks
/// `isDue`); a short one is dropped after `release` without pushing. After
/// the pointer comes back, pushes are ignored for `cooldown` (no bounce
/// straight out again), then skip the resistance until `warm` is up.
struct CrossingGate {
    enum Step: Equatable {
        case none
        /// A new push began: ask `isDue` again once the delay is up.
        case began
        case cross
    }

    static let distance = 30.0
    static let release = 0.25
    static let warm = 20.0
    static let cooldown = 0.25

    private(set) var portal: Portal?
    private var began = 0.0
    private var lastPush = 0.0
    private var pushed = 0.0
    private var warmUntil = -Double.infinity
    private var coolUntil = -Double.infinity

    mutating func reset() {
        portal = nil
        pushed = 0
    }

    /// The pointer came back from a peer at `time`.
    mutating func returned(at time: TimeInterval) {
        reset()
        coolUntil = time + Self.cooldown
        warmUntil = time + Self.warm
    }

    /// A motion against `candidate` (nil: no portal) by `amount` points
    /// outward.
    mutating func push(_ candidate: Portal?, by amount: Double, at time: TimeInterval,
                       delay: TimeInterval) -> Step {
        guard let candidate else {
            reset()
            return .none
        }
        if time < coolUntil {
            reset()
            return .none
        }
        if time < warmUntil {
            return amount > 0 ? .cross : .none
        }
        var step = Step.none
        if portal != candidate || time - lastPush > Self.release || time < lastPush {
            guard amount > 0 else {
                reset()
                return .none
            }
            portal = candidate
            began = time
            pushed = 0
            step = .began
        }
        if amount > 0 { lastPush = time }
        pushed = max(0, pushed + amount)
        return isDue(at: time, delay: delay) ? .cross : step
    }

    func isDue(at time: TimeInterval, delay: TimeInterval) -> Bool {
        portal != nil && pushed >= Self.distance && time - began >= delay
    }
}
