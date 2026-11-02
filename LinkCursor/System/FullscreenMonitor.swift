// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ApplicationServices

/// Samples the frontmost window outside the input tap. Accessibility is
/// already required for input sharing; screen recording is not requested.
@MainActor
final class FullscreenMonitor {
    var changed: ((Bool) -> Void)?
    private var timer: Timer?
    private var previous = false
    private var reading = false
    private var revision = 0

    func setEnabled(_ enabled: Bool) {
        revision += 1
        timer?.invalidate()
        timer = nil
        guard enabled else { publish(false); return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        guard !reading, let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(id.uint32Value)
        }
        reading = true
        let generation = revision
        Task { [weak self] in
            let fullscreen = await Task.detached(priority: .utility) {
                Self.readFullscreen(pid: pid, displays: displays)
            }.value
            guard let self else { return }
            self.reading = false
            guard self.revision == generation else { return }
            self.publish(fullscreen)
        }
    }

    private nonisolated static func readFullscreen(pid: pid_t, displays: [CGRect]) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return false }
        let window = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, 0.1)
        var fullscreen: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreen) == .success,
           (fullscreen as? Bool) == true {
            return true
        }
        // Borderless games may not set AXFullScreen. Compare their frame
        // with each display rather than with the combined desktop bounds.
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return false }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
        else { return false }
        return displays.contains { bounds in
            abs(position.x - bounds.minX) < 2 && abs(position.y - bounds.minY) < 2
                && abs(size.width - bounds.width) < 2 && abs(size.height - bounds.height) < 2
        }
    }

    private func publish(_ value: Bool) {
        guard value != previous else { return }
        previous = value
        changed?(value)
    }
}
