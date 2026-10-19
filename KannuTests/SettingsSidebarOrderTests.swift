//
//  SettingsSidebarOrderTests.swift
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

/// Brain's sidebar, top to bottom: AI Agents, then Productivity right under it (David: "bring
/// productivity settings to just below the ai section"), then General and Appearance under a
/// "General" header of their own — unlabelled, under Tasks, they read as part of Productivity.
///
/// The section order is `SettingsTabGroup`'s case order; search jumps to the first match in
/// `availableTabs`' order, so that list must follow the same order. The view is not in the logic
/// target, so this reads the source.
final class SettingsSidebarOrderTests: XCTestCase {
    private static let path = "Kannu/components/Settings/SettingsView.swift"

    private static func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The text between `start` and the first `end` after it.
    private static func slice(_ source: String, from start: String, to end: String) throws -> String {
        let open = try XCTUnwrap(source.range(of: start), "\(start) not found")
        let close = try XCTUnwrap(source.range(of: end, range: open.upperBound..<source.endIndex), "\(end) not found")
        return String(source[open.upperBound..<close.lowerBound])
    }

    func testProductivityComesRightAfterAIAgents() throws {
        let groups = try Self.slice(try Self.source(), from: "private enum SettingsTabGroup", to: "var id: String")
        let cases = groups.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("case ") }
            .map { String($0.dropFirst(5)) }
        XCTAssertEqual(cases, ["agents", "productivity", "core", "mediaAndDisplay", "system",
                               "utilities", "developer", "integrations", "info"])
    }

    func testGeneralAndAppearanceHaveAHeader() throws {
        let source = try Self.source()
        XCTAssertTrue(source.contains(#"case .core:             return String(localized: "General")"#),
                      "unlabelled under Productivity, General and Appearance read as part of it")
    }

    /// Search jumps to the first match in `availableTabs`, so it lists the tabs in sidebar order.
    func testSearchFollowsTheSidebarOrder() throws {
        let list = try Self.slice(try Self.source(), from: "let ordered: [SettingsTab] = [", to: "]")
        let tabs = list.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(".") }
            .map { String($0.dropFirst().prefix { $0.isLetter || $0.isNumber }) }
        func index(_ tab: String) throws -> Int { try XCTUnwrap(tabs.firstIndex(of: tab), "\(tab) is not listed") }
        XCTAssertLessThan(try index("llmUsage"), try index("timer"), "AI Agents first")
        XCTAssertLessThan(try index("timer"), try index("notes"))
        XCTAssertLessThan(try index("notes"), try index("general"), "Productivity before General")
        XCTAssertLessThan(try index("appearance"), try index("media"), "General before Media & Display")
    }
}
