//
//  SwiftModifierScan.swift
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

/// Reads SwiftUI modifiers out of a view's source, for the rules tests that pin a view's wiring
/// without building it (`TimerNamingRulesTests`, `TimerLifecycleRulesTests`).
enum SwiftModifierScan {
    /// Each use of a modifier: its name, its balanced argument list if any, then its trailing closure if any.
    static func modifiers(_ name: String, in text: String) -> [String] {
        var found: [String] = []
        var searchStart = text.startIndex
        while let range = text.range(of: name, range: searchStart..<text.endIndex) {
            var index = range.upperBound
            for (open, close) in [(Character("("), Character(")")), (Character("{"), Character("}"))] {
                var probe = index
                while probe < text.endIndex, text[probe] == " " { probe = text.index(after: probe) }
                guard probe < text.endIndex, text[probe] == open else { continue }
                var depth = 0
                repeat {
                    if text[probe] == open { depth += 1 } else if text[probe] == close { depth -= 1 }
                    probe = text.index(after: probe)
                } while probe < text.endIndex && depth > 0
                index = probe
            }
            found.append(String(text[range.lowerBound..<index]))
            searchStart = range.upperBound
        }
        return found
    }
}
