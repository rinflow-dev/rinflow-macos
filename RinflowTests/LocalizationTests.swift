// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest

/// The String Catalogs. Xcode (on build) and `make i18n` sync them with the
/// strings the code uses; these tests make sure each one is translated.
/// The source language needs its own translated entries too: without them
/// Xcode builds no Chinese table, and Chinese falls back to English, the
/// development region. `make i18n` adds them.
final class LocalizationTests: XCTestCase {
    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Rinflow/Resources")
    private static let source = "zh-Hans"
    private static let translations = ["en", "ja"]

    func testEveryStringIsTranslatedWithTheSamePlaceholders() throws {
        for name in ["Localizable", "InfoPlist"] {
            let url = Self.resources.appending(path: "\(name).xcstrings")
            let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
            XCTAssertEqual(catalog.sourceLanguage, Self.source, name)
            XCTAssertFalse(catalog.strings.isEmpty, name)

            for (key, entry) in catalog.strings where entry.shouldTranslate != false {
                XCTAssertNotEqual(entry.extractionState, "stale", "\(name): no longer used, delete it: \(key)")
                let original = entry.localizations?[Self.source]?.units.first?.value ?? key
                let expected = Self.placeholders(in: original)

                for language in [Self.source] + Self.translations {
                    let units = entry.localizations?[language]?.units ?? []
                    XCTAssertFalse(units.isEmpty, "\(name): no \(language) for \(key)")
                    var used = Set<String>()
                    for unit in units {
                        XCTAssertEqual(unit.state, "translated", "\(name): \(language) for \(key)")
                        let found = Self.placeholders(in: unit.value)
                        // A plural case may leave the number out ("a file").
                        XCTAssertTrue(found.isSubset(of: expected), "\(name): \(language) placeholders of \(key)")
                        used.formUnion(found)
                    }
                    if !units.isEmpty {
                        XCTAssertEqual(used, expected, "\(name): \(language) placeholders of \(key)")
                    }
                }
            }
        }
    }

    func testEveryLanguageOfferedIsInTheCatalog() {
        let catalogued = Set([Self.source] + Self.translations)
        for language in AppLanguage.allCases {
            for code in language.appleLanguages ?? [] {
                XCTAssertTrue(catalogued.contains(code), "\(language) is offered without a translation")
            }
        }
    }

    func testPlaceholdersKeepTheirPosition() {
        XCTAssertEqual(Self.placeholders(in: "%@ 想发送 %lld 个文件"), ["1@", "2lld"])
        XCTAssertEqual(Self.placeholders(in: "Receiving %2$@ from %1$@"), ["1@", "2@"])
        XCTAssertEqual(Self.placeholders(in: "100%% · %.2f×"), ["1.2f"])
    }

    /// Each argument as its position and type: "%@ %lld" and "%1$@ %2$lld"
    /// are the same, "%2$@ %1$@" swaps two strings.
    private static func placeholders(in text: String) -> Set<String> {
        let pattern = #/%(?:(\d+)\$)?(%|@|ll[du]|l?[du]|\.?\d*f|s)/#
        var next = 0
        var found = Set<String>()
        for match in text.matches(of: pattern) where match.2 != "%" {
            next += 1
            let position = match.1.flatMap { Int($0) } ?? next
            found.insert("\(position)\(match.2)")
        }
        return found
    }
}

private struct Catalog: Decodable {
    let sourceLanguage: String
    let strings: [String: Entry]

    struct Entry: Decodable {
        let shouldTranslate: Bool?
        let extractionState: String?
        let localizations: [String: Localization]?
    }

    struct Localization: Decodable {
        let stringUnit: StringUnit?
        let variations: [String: [String: Localization]]?

        /// The text, or each case of its variations (plural, device).
        var units: [StringUnit] {
            (stringUnit.map { [$0] } ?? [])
                + (variations ?? [:]).values.flatMap { $0.values.flatMap(\.units) }
        }
    }

    struct StringUnit: Decodable {
        let state: String
        let value: String
    }
}
