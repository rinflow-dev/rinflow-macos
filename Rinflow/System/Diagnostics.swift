// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import OSLog

/// Anonymous figures about how this Mac's connections hold up, summed here
/// and sent to api.rinflow.com about once an hour, only while the user allows
/// it (`AppSettings.diagnostics`, asked by the welcome sheet).
///
/// Counts, times and the core's fixed reason codes, by the other device's
/// platform: no device names or IDs, no addresses, nothing typed or copied.
/// The install ID is random and dropped when the user turns this off. The
/// server adds the country and keeps no IP (rinflow-site,
/// console/src/lib/diagnostics.ts, which checks every field).
@MainActor
final class Diagnostics {
    /// What one report carries besides where it comes from.
    struct Figures: Codable, Equatable, Sendable {
        var peers: [PeerFigures] = []
        var reasons: [ReasonCount] = []

        var isEmpty: Bool { peers.isEmpty && reasons.isEmpty }

        mutating func merge(_ other: Figures) {
            for figures in other.peers { update(figures.platform) { $0.merge(figures) } }
            for reason in other.reasons { count(reason) }
        }

        mutating func update(_ platform: String, _ change: (inout PeerFigures) -> Void) {
            if let index = peers.firstIndex(where: { $0.platform == platform }) {
                change(&peers[index])
            } else {
                var figures = PeerFigures(platform: platform)
                change(&figures)
                peers.append(figures)
            }
        }

        mutating func count(_ reason: ReasonCount) {
            if let index = reasons.firstIndex(where: { $0.sameKind(as: reason) }) {
                reasons[index].count += reason.count
            } else {
                reasons.append(reason)
            }
        }
    }

    /// Sessions with devices of one platform. Sums, except the worsts.
    struct PeerFigures: Codable, Equatable, Sendable {
        var platform: String
        var sessions = 0.0
        /// Seconds this Mac drove such a device (one `input_latency` each).
        var drivingSeconds = 0.0
        var latencySamples = 0.0
        /// Over all samples: the mean is this divided by `latencySamples`.
        var latencyMsSum = 0.0
        var latencyWorstMs = 0.0
        /// Seconds in which the link held input up (one `link_quality` each).
        var troubleSeconds = 0.0
        var sentPackets = 0.0
        var lostPackets = 0.0
        var inputBatches = 0.0
        var inputLate = 0.0
        var inputWorstMs = 0.0
        var staleRepeats = 0.0
        var roundTripWorstMs = 0.0
        /// Seconds after which motion was paced.
        var paced = 0.0

        mutating func merge(_ other: PeerFigures) {
            sessions += other.sessions
            drivingSeconds += other.drivingSeconds
            latencySamples += other.latencySamples
            latencyMsSum += other.latencyMsSum
            latencyWorstMs = max(latencyWorstMs, other.latencyWorstMs)
            troubleSeconds += other.troubleSeconds
            sentPackets += other.sentPackets
            lostPackets += other.lostPackets
            inputBatches += other.inputBatches
            inputLate += other.inputLate
            inputWorstMs = max(inputWorstMs, other.inputWorstMs)
            staleRepeats += other.staleRepeats
            roundTripWorstMs = max(roundTripWorstMs, other.roundTripWorstMs)
            paced += other.paced
        }
    }

    /// How often an event ended with a reason code, by the peer's platform
    /// (empty for an error of this Mac's own).
    struct ReasonCount: Codable, Equatable, Sendable {
        var event: String
        var code: String
        var peer: String
        var count = 1.0

        func sameKind(as other: ReasonCount) -> Bool {
            event == other.event && code == other.code && peer == other.peer
        }
    }

    /// The body of one POST, in snake case.
    struct Report: Codable, Equatable, Sendable {
        var version = 1
        var install: String
        var platform = "macos"
        var app: String
        var build: String
        var os: String
        var arch: String
        var peers: [PeerFigures]
        var reasons: [ReasonCount]
    }

    /// The events whose reason codes are counted.
    static let countedReasons: Set<String> = ["disconnected", "pairing_ended", "error", "files_failed"]
    nonisolated static let endpoint = URL(string: "https://api.rinflow.com/v1/diagnostics")!

    /// Off until the settings say otherwise. Turning it off drops what was
    /// summed and the install ID.
    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled { start() } else { forget() }
        }
    }

    private(set) var figures = Figures()
    /// Delivers a report: false to keep its figures for the next one.
    private let send: (Report) async -> Bool
    private let defaults: UserDefaults
    private var timer: Task<Void, Never>?
    private static let pendingKey = "rinflow.diagnostics.pending"
    private static let installKey = "rinflow.diagnostics.install"
    private nonisolated static let log = Logger(subsystem: "com.rinflow.mac", category: "diagnostics")

    init(defaults: UserDefaults = .standard, send: @escaping (Report) async -> Bool = Diagnostics.post) {
        self.defaults = defaults
        self.send = send
        // What the last run summed but did not send.
        if let data = defaults.data(forKey: Self.pendingKey),
           let pending = try? JSONDecoder().decode(Figures.self, from: data)
        {
            figures = pending
        }
        defaults.removeObject(forKey: Self.pendingKey)
    }

    /// Adds what a core event tells about the link. `platform`: the peer's.
    func record(_ event: CoreEventEnvelope, platform: String?) {
        guard enabled else { return }
        let platform = event.peer?.platform ?? platform ?? "unknown"
        switch event.event {
        case "connected":
            figures.update(platform) { $0.sessions += 1 }
        case "input_latency":
            let samples = event.samples ?? 0
            figures.update(platform) {
                $0.drivingSeconds += 1
                $0.latencySamples += samples
                $0.latencyMsSum += (event.ms ?? 0) * samples
                $0.latencyWorstMs = max($0.latencyWorstMs, event.worstMs ?? 0)
            }
        case "link_quality":
            figures.update(platform) {
                $0.troubleSeconds += 1
                $0.sentPackets += event.sentPackets ?? 0
                $0.lostPackets += event.lostPackets ?? 0
                $0.inputBatches += event.inputBatches ?? 0
                $0.inputLate += event.inputLate ?? 0
                $0.inputWorstMs = max($0.inputWorstMs, event.inputWorstMs ?? 0)
                $0.staleRepeats += event.staleRepeats ?? 0
                $0.roundTripWorstMs = max($0.roundTripWorstMs, event.roundTripWorstMs ?? 0)
                $0.paced += event.paced == true ? 1 : 0
            }
        case let name where Self.countedReasons.contains(name):
            let peer = event.peerID == nil && event.peer == nil ? "" : platform
            figures.count(ReasonCount(event: name, code: (event.reasonCode ?? .other).rawValue, peer: peer))
        default:
            break
        }
    }

    /// Sends what was summed since the last report. What does not get
    /// through is kept for the next one.
    func flush() async {
        guard enabled, !figures.isEmpty else { return }
        let sending = figures
        figures = Figures()
        if await send(report(of: sending)) { return }
        // Turned off meanwhile: forgotten, not put back.
        guard enabled else { return }
        var kept = sending
        kept.merge(figures)
        figures = kept
    }

    /// At quit: the figures wait for the next run.
    func save() {
        guard enabled, !figures.isEmpty, let data = try? JSONEncoder().encode(figures) else { return }
        defaults.set(data, forKey: Self.pendingKey)
    }

    func report(of figures: Figures) -> Report {
        let install = defaults.string(forKey: Self.installKey) ?? {
            let id = UUID().uuidString.lowercased()
            defaults.set(id, forKey: Self.installKey)
            return id
        }()
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        return Report(
            install: install,
            app: info?["CFBundleShortVersionString"] as? String ?? "",
            build: info?["CFBundleVersion"] as? String ?? "",
            os: "\(os.majorVersion).\(os.minorVersion)",
            arch: arch,
            peers: figures.peers,
            reasons: figures.reasons
        )
    }

    /// A minute after launch (what the last run left), then every hour.
    private func start() {
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                await self?.flush()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private func forget() {
        timer?.cancel()
        timer = nil
        figures = Figures()
        defaults.removeObject(forKey: Self.pendingKey)
        defaults.removeObject(forKey: Self.installKey)
    }

    /// The report as sent: snake case, keys sorted.
    nonisolated static func encode(_ report: Report) -> Data? {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(report)
    }

    /// Delivered, or refused for good (a 4xx: sending it again would not
    /// help); kept only when the network or the server failed. Debug builds
    /// log the report instead of sending it.
    nonisolated static func post(_ report: Report) async -> Bool {
        guard let body = encode(report) else { return true }
        #if DEBUG
        log.notice("diagnostics, not sent by debug builds: \(String(decoding: body, as: UTF8.self), privacy: .public)")
        return true
        #else
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(status) { log.error("diagnostics refused: \(status)") }
            return status < 500
        } catch {
            log.error("diagnostics not sent: \(error.localizedDescription, privacy: .public)")
            return false
        }
        #endif
    }
}
