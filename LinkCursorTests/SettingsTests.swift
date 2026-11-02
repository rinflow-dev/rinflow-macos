// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest

final class SettingsTests: XCTestCase {
    func testOlderPartialPeerPreferencesKeepOtherSettings() throws {
        let data = Data(#"{"clipboard":true,"peerInput":{"pc":{"pointerSpeed":2}}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(settings.clipboard)
        XCTAssertEqual(settings.input(for: "pc").pointerSpeed, 2)
        XCTAssertEqual(settings.input(for: "pc").scrollSpeed, 1)
        XCTAssertFalse(settings.input(for: "pc").invertScroll)
    }

    func testInvalidPersistedSpeedsAreClampedBeforeUse() throws {
        let data = Data(#"{"pointerSpeed":1e100,"scrollSpeed":-10}"#.utf8)
        let input = try JSONDecoder().decode(PeerInput.self, from: data)
        XCTAssertEqual(input.pointerSpeed, PeerInput.pointerSpeeds.upperBound)
        XCTAssertEqual(input.scrollSpeed, PeerInput.scrollSpeeds.lowerBound)
    }

    func testOldSettingsDoNotSilentlyOptIntoClipboardSharing() throws {
        let old = Data(#"{"keepAwake":false,"manualAddresses":["pc.local"]}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertFalse(settings.clipboard)
        XCTAssertTrue(settings.sharing)
        XCTAssertFalse(settings.keepAwake)
        XCTAssertEqual(settings.manualAddresses, ["pc.local"])
    }

    func testSharingPreferencesSurviveRelaunch() throws {
        var settings = AppSettings()
        settings.clipboard = true
        settings.sharing = false
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings)
    }

    func testThemeFollowsTheSystemUntilChosenAndUsesTheWindowsValues() throws {
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).theme, .system)
        var settings = AppSettings()
        settings.theme = .dark
        let encoded = try JSONEncoder().encode(settings)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""theme":"dark""#))
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: encoded).theme, .dark)
    }

    func testAnUnknownThemeFallsBackWithoutResettingOtherSettings() throws {
        let newer = Data(#"{"theme":"sepia","clipboard":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: newer)
        XCTAssertEqual(settings.theme, .system)
        XCTAssertTrue(settings.clipboard)
    }
}

final class ModifierMapTests: XCTestCase {
    func testUsingTheMacShortcutsIsTheCoresSwapAndOffKeepsPositions() {
        // linkcursor-core remap.rs ModifierMap::SWAP / ::KEEP.
        XCTAssertEqual(AppSettings.modifierMap(followMacShortcuts: true),
                       ["super": "control", "control": "super", "alt": "alt"])
        XCTAssertEqual(AppSettings.modifierMap(followMacShortcuts: false),
                       ["super": "super", "control": "control", "alt": "alt"])
    }
}
