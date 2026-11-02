// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import OSLog
import UserNotifications

/// Tells the user when files arrived (`files_received`); clicking the
/// notification shows them in Finder.
@MainActor
final class TransferNotifications: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let log = Logger(subsystem: "com.linkcursor.mac", category: "notifications")
    private nonisolated static let pathsKey = "paths"

    private var center: UNUserNotificationCenter? {
        // Unbundled builds (a bare executable) have no notification center.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func start() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Self.log.error("notifications not allowed: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                Self.log.info("notifications declined by the user")
            }
        }
    }

    func filesReceived(from peerName: String, paths: [String]) {
        guard let center, !paths.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "已收到来自 \(peerName) 的文件")
        let first = URL(fileURLWithPath: paths[0]).lastPathComponent
        content.body = paths.count == 1
            ? first
            : String(localized: "\(first) 等 \(paths.count) 项，已保存到“下载/LinkCursor”")
        content.sound = .default
        content.userInfo = [Self.pathsKey: paths]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let paths = response.notification.request.content.userInfo[Self.pathsKey] as? [String] ?? []
        Task { @MainActor in
            let urls = paths.map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if urls.isEmpty {
                NSWorkspace.shared.open(RustCore.downloadDirectory)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }
        completionHandler()
    }

    /// Shown even while LinkCursor is in front.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
