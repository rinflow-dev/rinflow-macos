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
