// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import Sparkle

/// Updates from the GitHub releases, with Sparkle 2.
///
/// The disk images are built one per architecture, and a Sparkle feed holds
/// one build per version, so each architecture has its feed
/// (`appcast-arm64.xml`, `appcast-x64.xml`, written by
/// scripts/package-release.sh), chosen when this app is compiled. Sparkle
/// installs an update only if it is signed with the EdDSA key whose public
/// half is in Info.plist (`SUPublicEDKey`) and by the same Developer ID,
/// which also keeps the Accessibility permission, bound to that signature.
@Observable
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    /// Debug builds, and builds without a public key, never update.
    let isAvailable: Bool
    /// Sparkle keeps this in the user defaults itself.
    var automaticallyChecks = false {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    init(enabled: Bool = true) {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        #if DEBUG
        isAvailable = false
        #else
        isAvailable = enabled && !key.isEmpty
        #endif
        super.init()
        guard isAvailable else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil
        )
        self.controller = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// `RinflowFeedURL` in the user defaults tries a feed before it is
    /// released (docs/release-checklist.md); its updates must still be
    /// signed with the key.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "RinflowFeedURL") ?? Self.feedURL
    }

    /// The latest release's feed for this build's architecture.
    nonisolated static let feedURL: String = {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x64"
        #endif
        return "https://github.com/rinflow-dev/rinflow-macos/releases/latest/download/appcast-\(architecture).xml"
    }()

    /// "0.0.1 (123)": the version and the build Sparkle compares.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
