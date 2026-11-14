// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest

@MainActor
final class DiagnosticsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "DiagnosticsTests")
        defaults.removePersistentDomain(forName: "DiagnosticsTests")
    }

    private func event(_ json: String) throws -> CoreEventEnvelope {
        try JSONDecoder().decode(CoreEventEnvelope.self, from: Data(json.utf8))
    }

    private func diagnostics(sent: @escaping (Diagnostics.Report) -> Bool = { _ in true }) -> Diagnostics {
        let diagnostics = Diagnostics(defaults: defaults) { sent($0) }
        diagnostics.enabled = true
        return diagnostics
    }

    func testSumsTheLinkByPeerPlatformAndCountsReasons() throws {
        let diagnostics = diagnostics()
        diagnostics.record(try event(#"{"event":"input_latency","peer_id":"pc","ms":4,"worst_ms":9,"samples":10}"#), platform: "windows")
        diagnostics.record(try event(#"{"event":"input_latency","peer_id":"pc","ms":6,"worst_ms":30,"samples":10}"#), platform: "windows")
        diagnostics.record(try event(#"""
            {"event":"link_quality","peer_id":"pc","rtt_ms":12.5,"sent_packets":200,"lost_packets":3,
             "input_batches":50,"input_late":2,"input_worst_ms":41.5,"stale_repeats":1,"round_trip_worst_ms":60,"paced":true}
            """#), platform: "windows")
        diagnostics.record(try event(#"{"event":"disconnected","peer_id":"pc","reason":"x","reason_code":"heartbeat_timeout"}"#), platform: "windows")
        diagnostics.record(try event(#"{"event":"disconnected","peer_id":"pc","reason":"x","reason_code":"heartbeat_timeout"}"#), platform: "windows")
        diagnostics.record(try event(#"{"event":"error","message":"x","reason_code":"discovery_unavailable"}"#), platform: nil)
        // Nothing to learn from these.
        diagnostics.record(try event(#"{"event":"peer_down","peer_id":"pc"}"#), platform: "windows")

        let windows = try XCTUnwrap(diagnostics.figures.peers.first)
        XCTAssertEqual(diagnostics.figures.peers.count, 1)
        XCTAssertEqual(windows.platform, "windows")
        XCTAssertEqual(windows.drivingSeconds, 2)
        XCTAssertEqual(windows.latencySamples, 20)
        XCTAssertEqual(windows.latencyMsSum, 100)
        XCTAssertEqual(windows.latencyWorstMs, 30)
        XCTAssertEqual(windows.troubleSeconds, 1)
        XCTAssertEqual(windows.lostPackets, 3)
        XCTAssertEqual(windows.inputWorstMs, 41.5)
        XCTAssertEqual(windows.paced, 1)
        XCTAssertEqual(diagnostics.figures.reasons, [
            Diagnostics.ReasonCount(event: "disconnected", code: "heartbeat_timeout", peer: "windows", count: 2),
            Diagnostics.ReasonCount(event: "error", code: "discovery_unavailable", peer: ""),
        ])
    }

    func testSendsNothingWhileOff() async throws {
        var reports = 0
        let diagnostics = diagnostics { _ in reports += 1; return true }
        diagnostics.enabled = false
        diagnostics.record(try event(#"{"event":"error","message":"x","reason_code":"other"}"#), platform: nil)
        await diagnostics.flush()
        XCTAssertTrue(diagnostics.figures.isEmpty)
        XCTAssertEqual(reports, 0)
    }

    func testKeepsWhatDidNotGetThroughAndForgetsWhenTurnedOff() async throws {
        var delivered = false
        let diagnostics = diagnostics { _ in delivered }
        let error = try event(#"{"event":"error","message":"x","reason_code":"other"}"#)
        diagnostics.record(error, platform: nil)
        await diagnostics.flush()
        XCTAssertEqual(diagnostics.figures.reasons.first?.count, 1)

        diagnostics.record(error, platform: nil)
        delivered = true
        await diagnostics.flush()
        XCTAssertTrue(diagnostics.figures.isEmpty)

        diagnostics.record(error, platform: nil)
        let install = diagnostics.report(of: diagnostics.figures).install
        diagnostics.enabled = false
        XCTAssertTrue(diagnostics.figures.isEmpty)
        diagnostics.enabled = true
        XCTAssertNotEqual(diagnostics.report(of: .init()).install, install)
    }

    func testFiguresWaitForTheNextRun() throws {
        let first = diagnostics()
        first.record(try event(#"{"event":"connected","peer":{"id":"pc","name":"PC","platform":"linux","address":"10.0.0.2","port":42421}}"#), platform: nil)
        first.save()
        let next = Diagnostics(defaults: defaults) { _ in true }
        XCTAssertEqual(next.figures.peers.map(\.platform), ["linux"])
        XCTAssertEqual(next.figures.peers.first?.sessions, 1)
    }

    func testReportIsSnakeCase() throws {
        let diagnostics = diagnostics()
        diagnostics.record(try event(#"{"event":"input_latency","peer_id":"pc","ms":4,"worst_ms":9,"samples":10}"#), platform: "windows")
        let data = try XCTUnwrap(Diagnostics.encode(diagnostics.report(of: diagnostics.figures)))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["platform"] as? String, "macos")
        let peer = try XCTUnwrap((json["peers"] as? [[String: Any]])?.first)
        XCTAssertEqual(peer["latency_ms_sum"] as? Double, 40)
        XCTAssertEqual(peer["round_trip_worst_ms"] as? Double, 0)
    }

    func testDiagnosticsAreUnchosenInOlderSettings() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"clipboard":true}"#.utf8))
        XCTAssertNil(old.diagnostics)
        var chosen = AppSettings()
        chosen.diagnostics = false
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(chosen)).diagnostics, false)
    }
}
