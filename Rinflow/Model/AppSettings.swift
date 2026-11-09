// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The user's preferences, saved as JSON in the user defaults. Defaults as
/// on Windows (`agent/src/settings.rs`).
struct AppSettings: Codable, Equatable, Sendable {
    /// Pauses input in both directions, keeping device connections alive.
    var sharing = true
    /// Explicit opt-in, matching Windows. Includes copied files.
    var clipboard = false
    var switchDelay = 0.15
    var cornerGuard = true
    var pauseInFullscreen = false
    /// Only paired devices may connect: others pair first.
    var pairedOnly = true
    /// What a PC's modifier keys play as when it drives this Mac (the core's
    /// `modifier_map`): Mac style by default, Ctrl as ⌘ so Ctrl+C copies.
    var modifierMap = ModifierMap.mac
    /// When a peer that drove this Mac moves its pointer away, the cursor is
    /// hidden where it was left, until this Mac's own mouse moves.
    var hideCursorOnLeave = true
    /// ⌃⌥⇧ (or ⌃⌥) with an arrow key moves the pointer to the device on that side.
    var switchHotkeys = true
    var switchModifiers: SwitchModifiers = .controlOptionShift
    /// While one of the other devices is in use, this Mac's display stays on
    /// and it does not lock for being idle.
    var keepAwake = true
    /// Locking this Mac locks the other devices, and theirs lock it.
    var lockSync = false
    /// Where to look for devices besides the network's multicast.
    var manualAddresses: [String] = []
    /// How this Mac's mouse feels on each peer it drives, by device ID.
    var peerInput: [String: PeerInput] = [:]
    var language: AppLanguage = .system
    /// Light, dark, or as the system is (`theme` on Windows too).
    var theme: AppTheme = .system

    init() {}

    /// Missing keys keep their defaults, so older saved settings still load,
    /// and so does a damaged or unknown value (a newer version wrote it):
    /// that one setting falls back, never all of them.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        sharing = values.lossy(.sharing) ?? defaults.sharing
        clipboard = values.lossy(.clipboard) ?? defaults.clipboard
        switchDelay = min(2, max(0, values.lossy(.switchDelay, as: Double.self).flatMap { $0.isFinite ? $0 : nil } ?? defaults.switchDelay))
        cornerGuard = values.lossy(.cornerGuard) ?? defaults.cornerGuard
        pauseInFullscreen = values.lossy(.pauseInFullscreen) ?? defaults.pauseInFullscreen
        pairedOnly = values.lossy(.pairedOnly) ?? defaults.pairedOnly
        // Before per-key choices, a switch: on was Mac style, off kept keys.
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
        modifierMap = values.lossy(.modifierMap)
            ?? legacy?.lossy(.shortcutRemap, as: Bool.self).map { $0 ? .mac : .keep }
            ?? defaults.modifierMap
        hideCursorOnLeave = values.lossy(.hideCursorOnLeave) ?? defaults.hideCursorOnLeave
        switchHotkeys = values.lossy(.switchHotkeys) ?? defaults.switchHotkeys
        switchModifiers = values.lossy(.switchModifiers) ?? defaults.switchModifiers
        keepAwake = values.lossy(.keepAwake) ?? defaults.keepAwake
        lockSync = values.lossy(.lockSync) ?? defaults.lockSync
        manualAddresses = values.lossy(.manualAddresses, as: LossyArray<String>.self)?.elements ?? []
        peerInput = values.lossy(.peerInput, as: [String: Lossy<PeerInput>].self)?
            .compactMapValues(\.value) ?? [:]
        language = values.lossy(.language) ?? defaults.language
        theme = values.lossy(.theme) ?? defaults.theme
    }

    private enum LegacyKeys: String, CodingKey {
        case shortcutRemap
    }

    func input(for peerID: String) -> PeerInput {
        peerInput[peerID] ?? PeerInput()
    }

    private static let key = "rinflow.settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return AppSettings()
        }
        return settings
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

extension KeyedDecodingContainer {
    /// The value under `key`, or nil when it is missing or cannot be read.
    func lossy<T: Decodable>(_ key: Key, as type: T.Type = T.self) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

/// One value of a saved collection: nil when it cannot be read, so the
/// others still load.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// A key a PC's modifier plays as on this Mac (the core's `remap::Modifier`,
/// by position: `super` is ⌘ here and the Windows key on a PC).
enum ModifierTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case control
    case command = "super"
    case option = "alt"
    case shift
    case none

    var id: String { rawValue }
}

/// What each modifier key of a PC driving this Mac plays as: the core's
/// `ModifierMap`, sent as is (`{"super":…,"control":…,"alt":…}`), the same
/// choices as on Windows (`modifier_map`).
struct ModifierMap: Codable, Equatable, Sendable {
    /// The Windows key.
    var windows: ModifierTarget
    var control: ModifierTarget
    var alt: ModifierTarget

    /// Ctrl plays as ⌘ (Ctrl+C copies) and the Windows key as ⌃: the core's
    /// `SWAP`.
    static let mac = ModifierMap(windows: .control, control: .command, alt: .option)
    /// Keys keep their position: the Windows key is ⌘ (`KEEP`).
    static let keep = ModifierMap(windows: .command, control: .control, alt: .option)

    init(windows: ModifierTarget, control: ModifierTarget, alt: ModifierTarget) {
        self.windows = windows
        self.control = control
        self.alt = alt
    }

    /// A key that cannot be read falls back to its Mac-style choice.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        windows = values.lossy(.windows) ?? Self.mac.windows
        control = values.lossy(.control) ?? Self.mac.control
        alt = values.lossy(.alt) ?? Self.mac.alt
    }

    enum CodingKeys: String, CodingKey {
        case windows = "super"
        case control
        case alt
    }
}

/// The modifiers of the switch shortcuts, with the arrow keys.
enum SwitchModifiers: String, Codable, CaseIterable, Identifiable, Sendable {
    /// ⌃⌥⇧, which few programs use with the arrow keys.
    case controlOptionShift
    case controlOption

    var id: String { rawValue }

    var symbols: String {
        switch self {
        case .controlOptionShift: "⌃⌥⇧"
        case .controlOption: "⌃⌥"
        }
    }
}

/// Pointer and scrolling on one peer, applied by this Mac as it drives it:
/// it tracks the pointer there, so the peer must not change the motion.
struct PeerInput: Codable, Equatable, Sendable {
    static let pointerSpeeds = 0.25...4.0
    static let scrollSpeeds = 0.25...5.0

    var pointerSpeed = 1.0
    var scrollSpeed = 1.0
    /// Scrolls the other way (natural scrolling on one side only).
    var invertScroll = false

    init() {}

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let pointer: Double = values.lossy(.pointerSpeed) ?? 1
        let scroll: Double = values.lossy(.scrollSpeed) ?? 1
        pointerSpeed = pointer.isFinite ? min(Self.pointerSpeeds.upperBound, max(Self.pointerSpeeds.lowerBound, pointer)) : 1
        scrollSpeed = scroll.isFinite ? min(Self.scrollSpeeds.upperBound, max(Self.scrollSpeeds.lowerBound, scroll)) : 1
        invertScroll = values.lossy(.invertScroll) ?? false
    }

    var isDefault: Bool { self == PeerInput() }
}

/// The language of Rinflow's own text; applies after a restart.
/// The app's appearance. Applied to the whole app through
/// `NSApplication.appearance` (all windows, menus, sheets and alerts);
/// `system` leaves it nil so the app follows System Settings live.
enum AppTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }
}

enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case chinese = "zh-CN"
    case english = "en-US"
    case japanese = "ja-JP"

    var id: String { rawValue }

    /// What the bundle should prefer, or nil to follow the system.
    var appleLanguages: [String]? {
        switch self {
        case .system: nil
        case .chinese: ["zh-Hans"]
        case .english: ["en"]
        case .japanese: ["ja"]
        }
    }

    /// Makes the next start use this language (`AppleLanguages`).
    func apply() {
        if let languages = appleLanguages {
            UserDefaults.standard.set(languages, forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }
}

/// Checks for addresses typed by the user, as on Windows: the core resolves
/// and reports the rest ("unresolved").
enum ManualAddress {
    /// The core's limit.
    static let maximum = 32

    /// Why `text` cannot be added to `existing`, or nil when it can.
    static func problem(with text: String, existing: [String]) -> String? {
        let address = text.trimmingCharacters(in: .whitespaces)
        if address.isEmpty {
            return String(localized: "请输入 IP 地址或设备名称")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:[]%"))
        guard address.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }),
              address.count <= 253
        else {
            return String(localized: "“\(address)”不是有效的地址：请输入 IP 地址或设备名称")
        }
        if existing.contains(where: { $0.caseInsensitiveCompare(address) == .orderedSame }) {
            return String(localized: "这个地址已经添加过了")
        }
        if existing.count >= maximum {
            return String(localized: "最多添加 \(maximum) 个地址")
        }
        return nil
    }
}
