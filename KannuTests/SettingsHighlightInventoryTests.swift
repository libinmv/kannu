//
//  SettingsHighlightInventoryTests.swift
//  KannuTests
//
//  Copyright (C) 2026 Kannu contributors
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import XCTest

/// Settings search lands on a row through its highlight id: the search entry names an id, and the
/// row registers the same id with `.settingsHighlight(id:)`. A mismatch fails silently — the result
/// scrolls nowhere — and two entries had drifted that way unnoticed. The Settings views are not
/// compiled into the logic target, so the pairing is read from the source.
///
/// The counts are pinned on purpose: reworking a tab's layout must keep every registration, so a
/// changed number has to be a deliberate edit here, not a row that lost its modifier.
final class SettingsHighlightInventoryTests: XCTestCase {
    private struct HighlightID: Hashable, CustomStringConvertible {
        /// nil when the registering view receives its id builder from a parent (a closure).
        let tab: String?
        let title: String
        var description: String { "\(tab ?? "?")-\(title)" }
    }

    private struct Entry {
        let tab: String
        let title: String
        let highlight: HighlightID?
    }

    private struct Inventory {
        var entries: [Entry] = []
        var registrations: [HighlightID: Int] = [:]
        var deepLinks: [String: HighlightID] = [:]
    }

    private static let settingsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Kannu/components/Settings", isDirectory: true)

    private static let indexStart = "    private var settingsSearchIndex: [SettingsSearchEntry] {"

    // MARK: - Pinned

    func testCountsArePinned() throws {
        let inventory = try Self.inventory()
        XCTAssertEqual(inventory.entries.count, 199, "search entries")
        XCTAssertEqual(inventory.registrations.values.reduce(0, +), 250, "row registrations")
        XCTAssertEqual(inventory.registrations.count, 244, "distinct registered ids")
    }

    func testOnlyTheKnownRowsTakeTheirIdBuilderFromAParent() throws {
        let unattributed = try Self.inventory().registrations.keys.filter { $0.tab == nil }.map(\.title)
        XCTAssertEqual(Set(unattributed), ["Accent colour", "Device Picker Style"])
    }

    // MARK: - Pairing

    func testEverySearchEntryLandsOnARegisteredRow() throws {
        let inventory = try Self.inventory()
        let missing = inventory.entries.compactMap { entry -> String? in
            guard let id = entry.highlight else { return nil }
            let registered = inventory.registrations[id] != nil
                || inventory.registrations[HighlightID(tab: nil, title: id.title)] != nil
            return registered ? nil : "\(entry.tab): \"\(entry.title)\" → \(id)"
        }
        XCTAssertEqual(missing, [], "search entries whose highlight id no row registers")
    }

    func testEverySearchEntryNamesItsOwnTab() throws {
        let wrong = try Self.inventory().entries.compactMap { entry -> String? in
            guard let tab = entry.highlight?.tab, tab != entry.tab else { return nil }
            return "\(entry.tab): \"\(entry.title)\" → \(tab)"
        }
        XCTAssertEqual(wrong, [], "the id's tab prefix must match the tab the search opens")
    }

    func testEveryDeepLinkIsRegistered() throws {
        let inventory = try Self.inventory()
        XCTAssertFalse(inventory.deepLinks.isEmpty)
        for (name, id) in inventory.deepLinks {
            XCTAssertNotNil(inventory.registrations[id], "SettingsDeepLink.\(name) → \(id) is registered by no row")
        }
    }

    func testTheParserSeesEveryEntryAndRegistration() throws {
        // Guards the regexes themselves: a missed form would quietly shrink both sides.
        let sources = try Self.sources()
        let entryCalls = sources.values.map { $0.components(separatedBy: "SettingsSearchEntry(tab:").count - 1 }.reduce(0, +)
        let inventory = try Self.inventory()
        XCTAssertEqual(inventory.entries.count, entryCalls)
    }

    func testEverySearchEntryNamesARow() throws {
        // An entry without an id opens its tab and scrolls nowhere (the three Battery test entries did).
        let withoutRow = try Self.inventory().entries.filter { $0.highlight == nil }.map { "\($0.tab): \($0.title)" }
        XCTAssertEqual(withoutRow, [])
    }

    // MARK: - Parsing

    private static func sources() throws -> [String: String] {
        let files = try FileManager.default.contentsOfDirectory(at: settingsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var out: [String: String] = [:]
        for file in files {
            out[file.lastPathComponent] = try String(contentsOf: file, encoding: .utf8)
        }
        XCTAssertNotNil(out["SettingsView.swift"])
        return out
    }

    private static func inventory() throws -> Inventory {
        var inventory = Inventory()
        var sources = try sources()
        let settingsView = try XCTUnwrap(sources["SettingsView.swift"])

        // The search index registers nothing; parse it on its own and keep it out of the rows.
        let start = try XCTUnwrap(settingsView.range(of: indexStart))
        let end = try XCTUnwrap(settingsView.range(of: "\n    }\n", range: start.upperBound..<settingsView.endIndex))
        let index = String(settingsView[start.lowerBound..<end.lowerBound])
        sources["SettingsView.swift"] = String(settingsView[..<start.lowerBound]) + String(settingsView[end.lowerBound...])

        for match in matches(#"static let (\w+) = SettingsTab\.(\w+)\.highlightID\(for: "([^"]+)"\)"#, in: settingsView) {
            inventory.deepLinks[match[1]] = HighlightID(tab: match[2], title: match[3])
        }

        for match in matches(#"SettingsSearchEntry\(tab: \.(\w+), title: "([^"]*)", keywords: \[[^\]]*\], highlightID: ([^\n]*)\),?[ \t]*$"#,
                             in: index) {
            let expression = match[3]
            let highlight: HighlightID?
            if let id = matches(#"^SettingsTab\.(\w+)\.highlightID\(for: "([^"]+)"\)$"#, in: expression).first {
                highlight = HighlightID(tab: id[1], title: id[2])
            } else if let link = matches(#"^SettingsDeepLink\.(\w+)$"#, in: expression).first {
                highlight = try XCTUnwrap(inventory.deepLinks[link[1]], "unknown deep link \(link[1])")
            } else {
                XCTAssertEqual(expression, "nil", "unparsed highlight id for \"\(match[2])\"")
                highlight = nil
            }
            inventory.entries.append(Entry(tab: match[1], title: match[2], highlight: highlight))
        }

        // Each top-level declaration is a region; a type's own `highlightID(_:)` names its tab, and an
        // extension of that type shares it.
        var regions: [(type: String, body: String)] = []
        for text in sources.values {
            let declarations = matchRanges(#"^(?:private |fileprivate )?(?:final )?(?:struct|extension|class|enum) (\w+)"#,
                                           in: text, options: [.anchorsMatchLines])
            for (offset, declaration) in declarations.enumerated() {
                let bodyEnd = offset + 1 < declarations.count ? declarations[offset + 1].range.lowerBound : text.endIndex
                regions.append((declaration.name, String(text[declaration.range.lowerBound..<bodyEnd])))
            }
        }
        var tabByType: [String: String] = [:]
        let helper = #"func highlightID\(_ title: String\) -> String \{\s*(?:SettingsTab\.(\w+)\.highlightID\(for: title\)|"(\w+)-\\\(title\)")\s*\}"#
        for region in regions {
            if let match = matches(helper, in: region.body).first {
                tabByType[region.type] = match[1].isEmpty ? match[2] : match[1]
            }
        }

        for region in regions {
            let tab = tabByType[region.type]
            var found: [HighlightID] = []
            for match in matches(#"(?<![.\w])highlightID\("([^"]+)"\)"#, in: region.body) {
                found.append(HighlightID(tab: tab, title: match[1]))
            }
            for match in matches(#"highlightTitle: "([^"]+)""#, in: region.body) {
                found.append(HighlightID(tab: tab, title: match[1]))
            }
            for match in matches(#"highlightProvider\("([^"]+)"\)"#, in: region.body) {
                found.append(HighlightID(tab: nil, title: match[1]))
            }
            for match in matches(#"settingsHighlight\(id: SettingsTab\.(\w+)\.highlightID\(for: "([^"]+)"\)\)"#, in: region.body) {
                found.append(HighlightID(tab: match[1], title: match[2]))
            }
            for match in matches(#"settingsHighlight\(id: SettingsDeepLink\.(\w+)\)"#, in: region.body) {
                found.append(try XCTUnwrap(inventory.deepLinks[match[1]], "unknown deep link \(match[1])"))
            }
            for id in found {
                inventory.registrations[id, default: 0] += 1
            }
        }
        return inventory
    }

    /// Capture groups of every match (index 0 is the whole match; a group that did not take part is "").
    private static func matches(_ pattern: String, in text: String, options: NSRegularExpression.Options = [.anchorsMatchLines]) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            XCTFail("bad pattern \(pattern)")
            return []
        }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { result in
            (0..<result.numberOfRanges).map { group in
                Range(result.range(at: group), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    private static func matchRanges(_ pattern: String, in text: String,
                                    options: NSRegularExpression.Options) -> [(name: String, range: Range<String.Index>)] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            XCTFail("bad pattern \(pattern)")
            return []
        }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            guard let whole = Range(result.range, in: text), let name = Range(result.range(at: 1), in: text) else { return nil }
            return (String(text[name]), whole)
        }
    }
}
