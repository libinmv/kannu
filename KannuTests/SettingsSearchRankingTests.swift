/*
 * Kannu (കണ്ണ്)
 * Copyright (C) 2024-2026 Kannu Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import XCTest

/// Brain's search: a search for "color" offered eight rows in index order, seven of them Devices and
/// HUD, so Notch fill color came last or not at all, and "colour" never found it.
final class SettingsSearchRankingTests: XCTestCase {
    private typealias Rank = SettingsSearchRanking.Rank

    func testEitherSpellingOfColourFindsBoth() {
        XCTAssertEqual(SettingsSearchRanking.rank(title: "Notch fill color", keywords: [], query: "colour"), .titleWord)
        XCTAssertEqual(SettingsSearchRanking.rank(title: "Solid colour", keywords: [], query: "color"), .titleWord)
        XCTAssertEqual(SettingsSearchRanking.rank(title: "Tag colours", keywords: [], query: "Color"), .titleWordPrefix)
    }

    func testRanksFromTitleWordToKeyword() {
        XCTAssertEqual(SettingsSearchRanking.rank(title: "Notch fill color", keywords: [], query: "color"), .titleWord)
        XCTAssertEqual(SettingsSearchRanking.rank(title: "Color-coded battery display", keywords: [], query: "color"), .titleWord)
        XCTAssertEqual(SettingsSearchRanking.rank(title: "Use colored gauges", keywords: [], query: "color"), .titleWordPrefix)
        XCTAssertEqual(SettingsSearchRanking.rank(title: "Multicolor glow", keywords: [], query: "color"), .titleSubstring)
        XCTAssertEqual(SettingsSearchRanking.rank(title: "Timer tint", keywords: ["accent color"], query: "color"), .keyword)
        XCTAssertNil(SettingsSearchRanking.rank(title: "Launch at login", keywords: ["startup"], query: "color"))
        XCTAssertNil(SettingsSearchRanking.rank(title: "Launch at login", keywords: [], query: "   "))
        XCTAssertLessThan(Rank.titleWord, Rank.keyword)
    }

    func testRankedPutsBetterMatchesFirstAndKeepsTheRestInOrder() {
        let items = ["Timer tint|accent color", "Use colored gauges|", "Slider color|", "Launch at login|", "Notch fill color|"]
        let ranked = SettingsSearchRanking.ranked(items, query: "color",
                                                  title: { String($0.split(separator: "|", omittingEmptySubsequences: false)[0]) },
                                                  keywords: { [String($0.split(separator: "|", omittingEmptySubsequences: false)[1])] })
        XCTAssertEqual(ranked, ["Slider color|", "Notch fill color|", "Use colored gauges|", "Timer tint|accent color"])
    }

    /// Against the real index in `SettingsView`: both spellings put Notch fill color among the rows
    /// the list shows before it scrolls.
    func testNotchFillColorIsOfferedForColorAndColour() throws {
        let entries = try Self.indexEntries()
        XCTAssertGreaterThan(entries.count, 50, "the index parse found too few entries")
        for query in ["color", "colour", "notch colour"] {
            let titles = SettingsSearchRanking.ranked(entries, query: query, title: \.title, keywords: \.keywords).map(\.title)
            let position = try XCTUnwrap(titles.firstIndex(of: "Notch fill color"), "\(query): not offered")
            XCTAssertLessThan(position, 8, "\(query): Notch fill color is row \(position + 1) of \(titles)")
        }
    }

    /// The suggestions are no longer cut to a fixed count; a long list scrolls.
    func testSuggestionsAreNotTruncated() throws {
        let source = try Self.settingsSource()
        XCTAssertEqual(try Self.suggestionsBody(source).contains("prefix("), false)
        let old = "    private var searchSuggestions: [SettingsSearchEntry] {\n"
            + "        Array(searchEntries(matching: searchText).filter { $0.tab != .downloads }.prefix(8))\n    }\n"
        XCTAssertEqual(try Self.suggestionsBody(old).contains("prefix("), true, "the check misses the old cap")
    }

    /// `searchSuggestions`' body, up to the property's closing brace at its own indent.
    private static func suggestionsBody(_ source: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: "private var searchSuggestions: [SettingsSearchEntry] {"))
        let end = try XCTUnwrap(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        return source[start.upperBound..<end.lowerBound]
    }

    // MARK: - The index, read from SettingsView

    private struct Entry { let title: String; let keywords: [String] }

    private static func settingsSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Kannu/components/Settings/SettingsView.swift"), encoding: .utf8)
    }

    private static func indexEntries() throws -> [Entry] {
        let source = try settingsSource()
        let pattern = try NSRegularExpression(pattern: #"SettingsSearchEntry\(tab: \.\w+, title: "([^"]+)", keywords: \[([^\]]*)\]"#)
        let quoted = try NSRegularExpression(pattern: #""([^"]*)""#)
        return pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
            guard let title = Range(match.range(at: 1), in: source),
                  let list = Range(match.range(at: 2), in: source) else { return nil }
            let keywordText = String(source[list])
            let keywords = quoted.matches(in: keywordText, range: NSRange(keywordText.startIndex..., in: keywordText))
                .compactMap { Range($0.range(at: 1), in: keywordText).map { String(keywordText[$0]) } }
            return Entry(title: String(source[title]), keywords: keywords)
        }
    }
}
