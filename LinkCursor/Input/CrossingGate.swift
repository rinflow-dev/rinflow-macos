import Foundation

/// Requires a continuous push into the same portal. Resting at an edge or
/// moving away resets the delay, so ordinary menu/Dock use doesn't switch.
struct CrossingGate {
    private var portal: Portal?
    private var began = 0.0
    private var lastPush = 0.0

    mutating func reset() { portal = nil }

    mutating func allows(_ candidate: Portal?, at time: TimeInterval, delay: TimeInterval) -> Bool {
        guard let candidate else {
            reset()
            return false
        }
        if portal != candidate || time - lastPush > 0.25 || time < lastPush {
            portal = candidate
            began = time
        }
        lastPush = time
        return time - began >= delay
    }
}
