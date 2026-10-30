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
    /// A PC driving this Mac uses its own shortcuts: Ctrl plays as ⌘ (Ctrl+C
    /// copies), instead of keeping its position as Control. The core's
    /// `shortcut_remap`.
    var shortcutRemap = true
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

    /// Missing keys keep their defaults, so older saved settings still load.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        sharing = try values.decodeIfPresent(Bool.self, forKey: .sharing) ?? defaults.sharing
        clipboard = try values.decodeIfPresent(Bool.self, forKey: .clipboard) ?? defaults.clipboard
        switchDelay = min(2, max(0, try values.decodeIfPresent(Double.self, forKey: .switchDelay) ?? defaults.switchDelay))
        cornerGuard = try values.decodeIfPresent(Bool.self, forKey: .cornerGuard) ?? defaults.cornerGuard
        pauseInFullscreen = try values.decodeIfPresent(Bool.self, forKey: .pauseInFullscreen) ?? defaults.pauseInFullscreen
        pairedOnly = try values.decodeIfPresent(Bool.self, forKey: .pairedOnly) ?? defaults.pairedOnly
        shortcutRemap = try values.decodeIfPresent(Bool.self, forKey: .shortcutRemap) ?? defaults.shortcutRemap
        hideCursorOnLeave = try values.decodeIfPresent(Bool.self, forKey: .hideCursorOnLeave)
            ?? defaults.hideCursorOnLeave
        switchHotkeys = try values.decodeIfPresent(Bool.self, forKey: .switchHotkeys) ?? defaults.switchHotkeys
        switchModifiers = try values.decodeIfPresent(SwitchModifiers.self, forKey: .switchModifiers)
            ?? defaults.switchModifiers
        keepAwake = try values.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? defaults.keepAwake
        lockSync = try values.decodeIfPresent(Bool.self, forKey: .lockSync) ?? defaults.lockSync
        manualAddresses = try values.decodeIfPresent([String].self, forKey: .manualAddresses) ?? []
        peerInput = try values.decodeIfPresent([String: PeerInput].self, forKey: .peerInput) ?? [:]
        language = try values.decodeIfPresent(AppLanguage.self, forKey: .language) ?? defaults.language
        // A value this version does not know (a newer one wrote it) falls
        // back to the system's, instead of resetting every setting.
        theme = (try? values.decodeIfPresent(AppTheme.self, forKey: .theme)) ?? defaults.theme
    }

    func input(for peerID: String) -> PeerInput {
        peerInput[peerID] ?? PeerInput()
    }

    private static let key = "linkcursor.settings"

    /// "Use the Mac's shortcuts": a PC's Ctrl plays as ⌘ and its Windows key
    /// as Control (the core's `ModifierMap::SWAP`, what the former
    /// `shortcut_remap` did); otherwise keys keep their position (`KEEP`).
    static func modifierMap(followMacShortcuts: Bool) -> [String: String] {
        followMacShortcuts
            ? ["super": "control", "control": "super", "alt": "alt"]
            : ["super": "super", "control": "control", "alt": "alt"]
    }

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
        let pointer = try values.decodeIfPresent(Double.self, forKey: .pointerSpeed) ?? 1
        let scroll = try values.decodeIfPresent(Double.self, forKey: .scrollSpeed) ?? 1
        pointerSpeed = pointer.isFinite ? min(Self.pointerSpeeds.upperBound, max(Self.pointerSpeeds.lowerBound, pointer)) : 1
        scrollSpeed = scroll.isFinite ? min(Self.scrollSpeeds.upperBound, max(Self.scrollSpeeds.lowerBound, scroll)) : 1
        invertScroll = try values.decodeIfPresent(Bool.self, forKey: .invertScroll) ?? false
    }

    var isDefault: Bool { self == PeerInput() }
}

/// The language of LinkCursor's own text; applies after a restart.
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

    var id: String { rawValue }

    /// What the bundle should prefer, or nil to follow the system.
    var appleLanguages: [String]? {
        switch self {
        case .system: nil
        case .chinese: ["zh-Hans"]
        case .english: ["en"]
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
