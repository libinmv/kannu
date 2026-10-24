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

import Foundation

/// How well a Brain search matches a Settings row, so the rows that name what was typed come first.
/// Foundation only, so the test target compiles it.
enum SettingsSearchRanking {
    /// Lower is a better match.
    enum Rank: Int, Comparable {
        /// A word of the title is the query, or the title starts with it: "color" in "Notch fill color".
        case titleWord
        /// A word of the title starts with the query: "color" in "Use colored gauges".
        case titleWordPrefix
        /// The query is somewhere else in the title.
        case titleSubstring
        /// Only a keyword matches.
        case keyword

        static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Case and diacritics folded, and the British "colour" read as "color": the rows spell it both
    /// ways ("Notch fill color", "Solid colour"), and either spelling must find both.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "colour", with: "color")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nil when nothing matches.
    static func rank(title: String, keywords: [String], query: String) -> Rank? {
        let query = normalized(query)
        guard !query.isEmpty else { return nil }
        let title = normalized(title)
        let words = title.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if title.hasPrefix(query) || words.contains(query) { return .titleWord }
        if words.contains(where: { $0.hasPrefix(query) }) { return .titleWordPrefix }
        if title.contains(query) { return .titleSubstring }
        if keywords.contains(where: { normalized($0).contains(query) }) { return .keyword }
        return nil
    }

    /// The matching items, best rank first; items of equal rank keep their order.
    static func ranked<Item>(_ items: [Item], query: String,
                             title: (Item) -> String, keywords: (Item) -> [String]) -> [Item] {
        items.enumerated()
            .compactMap { offset, item in
                rank(title: title(item), keywords: keywords(item), query: query).map { (item, $0, offset) }
            }
            .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            .map(\.0)
    }
}
