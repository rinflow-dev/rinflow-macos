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

final class DamagedSettingsTests: XCTestCase {
    func testADamagedSettingFallsBackAloneAndTheOthersLoad() throws {
        let damaged = Data(#"""
        {"clipboard":"yes","pairedOnly":false,"switchDelay":"slow","manualAddresses":["pc.local",7],
         "peerInput":{"pc":{"pointerSpeed":2},"tv":{"pointerSpeed":"fast"},"mini":42}}
        """#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: damaged)
        XCTAssertFalse(settings.clipboard)
        XCTAssertFalse(settings.pairedOnly)
        XCTAssertEqual(settings.switchDelay, AppSettings().switchDelay)
        XCTAssertEqual(settings.manualAddresses, ["pc.local"])
        XCTAssertEqual(settings.input(for: "pc").pointerSpeed, 2)
        // A damaged field of a peer keeps that peer's other fields.
        XCTAssertEqual(settings.input(for: "tv"), PeerInput())
        XCTAssertNil(settings.peerInput["mini"])
    }

    func testOneDamagedPairedDeviceDoesNotForgetTheOthers() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "rinflow-tests-\(UUID().uuidString)"))
        defaults.set(Data(#"""
        [{"peer_id":"pc","fingerprint":"aa"},{"peer_id":3},{"peer_id":"mac","fingerprint":"bb"}]
        """#.utf8), forKey: "trusted")
        let peers = LossyArray<TrustedPeer>.load("trusted", from: defaults)
        XCTAssertEqual(peers.map(\.peerID), ["pc", "mac"])
        XCTAssertTrue(LossyArray<TrustedPeer>.load("missing", from: defaults).isEmpty)
        defaults.set(Data("not json".utf8), forKey: "garbage")
        XCTAssertTrue(LossyArray<TrustedPeer>.load("garbage", from: defaults).isEmpty)
    }
}

final class ModifierMapTests: XCTestCase {
    func testThePresetsAreTheCoresSwapAndKeepInItsJSON() throws {
        // rinflow-core remap.rs ModifierMap::SWAP / ::KEEP.
        let swap = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ModifierMap.mac)) as? [String: String]
        XCTAssertEqual(swap, ["super": "control", "control": "super", "alt": "alt"])
        let keep = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ModifierMap.keep)) as? [String: String]
        XCTAssertEqual(keep, ["super": "super", "control": "control", "alt": "alt"])
        XCTAssertEqual(AppSettings().modifierMap, .mac)
    }

    func testEachKeyCanBeChosenAndSurvivesRelaunch() throws {
        var settings = AppSettings()
        settings.modifierMap = ModifierMap(windows: .none, control: .command, alt: .shift)
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.modifierMap, settings.modifierMap)
    }

    func testTheFormerSwitchBecomesAPresetAndADamagedKeyFallsBack() throws {
        let off = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"shortcutRemap":false}"#.utf8))
        XCTAssertEqual(off.modifierMap, .keep)
        let on = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"shortcutRemap":true}"#.utf8))
        XCTAssertEqual(on.modifierMap, .mac)
        let damaged = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"modifierMap":{"super":"hyper","control":"control"}}"#.utf8)
        )
        XCTAssertEqual(damaged.modifierMap, ModifierMap(windows: .control, control: .control, alt: .option))
    }
}

final class CoreReasonTests: XCTestCase {
    func testCodesDecodeAndUnknownOnesAreOther() throws {
        let event = try JSONDecoder().decode(CoreEventEnvelope.self, from: Data(
            #"{"event":"disconnected","peer_id":"pc","reason":"heartbeat timeout","reason_code":"heartbeat_timeout"}"#.utf8
        ))
        XCTAssertEqual(event.reasonCode, .heartbeatTimeout)
        let newer = try JSONDecoder().decode(CoreEventEnvelope.self, from: Data(
            #"{"event":"disconnected","peer_id":"pc","reason":"warp drive failed","reason_code":"warp_failed"}"#.utf8
        ))
        XCTAssertEqual(newer.reasonCode, .other)
    }

    func testOrderlyEndsSayNothingAndEveryOtherCodeHasWords() {
        let quiet: Set<CoreReason> = [
            .localRequest, .peerClosed, .peerDisconnected, .goingToSleep, .coreStopped, .replacedConnection,
            .pairingDeclined, .remoteReset, .takenOverByAnotherDevice, .takenBackLocally, .remoteControlOff,
            .takenOver, .revoked, .done, .cancelled, .replacedByNewerCopy, .filesGone, .fileOperationEnded,
        ]
        for code in CoreReason.allCases {
            let message = code.message(in: .session)
            if quiet.contains(code) {
                XCTAssertNil(message, code.rawValue)
            } else {
                XCTAssertFalse(message?.isEmpty ?? true, code.rawValue)
            }
        }
        XCTAssertEqual(CoreReason.other.message(in: .files), CoreReason.Context.files.fallback)
    }

    /// Every code the core sends (its `src/reason.rs`) is known here.
    func testEveryCodeOfTheCoreIsKnown() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "rinflow-core/src/reason.rs")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            throw XCTSkip("rinflow-core is not next to rinflow-macos")
        }
        let tables = text.components(separatedBy: "#[cfg(test)]")[0]
        let pattern = try NSRegularExpression(pattern: #"\(\s*[^()]*?,\s*"([a-z_]+)"\s*\)"#)
        let codes = pattern.matches(in: tables, range: NSRange(tables.startIndex..., in: tables)).compactMap {
            Range($0.range(at: 1), in: tables).map { String(tables[$0]) }
        }
        XCTAssertGreaterThan(codes.count, 40)
        for code in Set(codes) {
            XCTAssertNotNil(CoreReason(rawValue: code), "the core's code \(code) has no words here")
        }
    }
}
