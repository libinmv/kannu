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

/// Which colour a task shows (strictly its first tag's; its integration's only with no tags), and how
/// tag colours are kept in tasks.json.
final class TaskColorTests: XCTestCase {
    private let integrations: [TaskSource: TaskColor] = [.local: .white, .jira: .blue, .gitlab: .orange]

    private func integration(_ source: TaskSource) -> TaskColor {
        TaskColoring.integration(for: source, local: .white, jira: .blue, gitlab: .orange)
    }

    // MARK: - Which colour

    func testATaskWithNoTagsTakesItsIntegrationsColour() {
        for (source, expected) in integrations {
            XCTAssertEqual(integration(source), expected, "\(source)")
            XCTAssertEqual(TaskColoring.color(tags: [], tagColors: ["urgent": .red], integration: integration(source)),
                           expected, "\(source)")
        }
    }

    func testTheFirstTagGivesTheColour() {
        let colors: [String: TaskColor] = ["urgent": .red, "writing": .green]
        XCTAssertEqual(TaskColoring.color(tags: ["urgent", "writing"], tagColors: colors, integration: .orange), .red)
        XCTAssertEqual(TaskColoring.color(tags: ["writing", "urgent"], tagColors: colors, integration: .orange), .green)
    }

    func testAnUncolouredFirstTagIsGlassEvenWhenALaterTagHasAColour() {
        let colors: [String: TaskColor] = ["urgent": .red]
        XCTAssertEqual(TaskColoring.color(tags: ["plain", "urgent"], tagColors: colors, integration: .orange), .glass,
                       "strictly the first tag: never the second tag's colour, never the integration's")
        XCTAssertEqual(TaskColoring.color(tags: ["plain"], tagColors: [:], integration: .blue), .glass)
    }

    func testTheKeyIgnoresCaseAndALeadingHash() {
        XCTAssertEqual(TaskColoring.key(for: "#Urgent"), "urgent")
        XCTAssertEqual(TaskColoring.key(for: "  ##Deep   Work "), "deep work")
        XCTAssertEqual(TaskColoring.key(for: "#"), "")
        XCTAssertEqual(TaskColoring.key(for: "   "), "")
        XCTAssertEqual(TaskColoring.color(tags: ["URGENT"], tagColors: ["urgent": .red], integration: .glass), .red)
        XCTAssertEqual(TaskColoring.color(tags: ["#Deep Work"], tagColors: [TaskColoring.key(for: "deep work"): .teal],
                                          integration: .glass), .teal)
    }

    func testEveryColourHasItsOwnName() {
        let names = TaskColor.allCases.map(\.localizedName)
        XCTAssertFalse(names.contains(where: \.isEmpty))
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(TaskColor.allCases.first, .glass, "glass, today's look, leads the presets")
        XCTAssertEqual(Set(TaskColor.allCases.map(\.id)).count, TaskColor.allCases.count)
    }

    // MARK: - Storage

    func testTagColoursReadBack() throws {
        let file = TasksFile(tasks: [TaskItem(title: "Write", createdAt: Date(timeIntervalSince1970: 0), tags: ["Urgent"])],
                             drafts: [], tagColors: ["urgent": .orange, "deep work": .teal])
        let data = try TasksFile.makeEncoder().encode(file)
        XCTAssertEqual(try TasksFile.makeDecoder().decode(TasksFile.self, from: data), file)
    }

    func testAFileWrittenBeforeTagColoursStillReads() throws {
        let json = """
        {"version": 1, "drafts": [], "tasks": [
          {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "title": "Old", "tags": ["urgent"]}
        ]}
        """
        let file = try TasksFile.makeDecoder().decode(TasksFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.tasks.count, 1)
        XCTAssertEqual(file.tagColors, [:])
    }

    func testUnknownColoursAreDroppedAndKeysCleaned() throws {
        let json = """
        {"version": 1, "drafts": [], "tasks": [], "tagColors":
          {"urgent": "orange", "later": "chartreuse", "#Deep Work": "teal", "plain": "glass", "#": "red"}}
        """
        let file = try TasksFile.makeDecoder().decode(TasksFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.tagColors, ["urgent": .orange, "deep work": .teal])
    }

    func testOddTagColoursNeverCostTheFile() throws {
        for odd in ["\"x\"", "[1, 2]", "7", "{\"urgent\": 3}", "null"] {
            let json = """
            {"version": 1, "drafts": [], "tagColors": \(odd), "tasks": [
              {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "title": "Kept", "tags": ["urgent"]}
            ]}
            """
            let file = try TasksFile.makeDecoder().decode(TasksFile.self, from: Data(json.utf8))
            XCTAssertEqual(file.tasks.map(\.title), ["Kept"], odd)
            XCTAssertEqual(file.tasks.first?.tags, ["urgent"], odd)
            XCTAssertEqual(file.tagColors, [:], odd)
        }
    }

    /// One bad value costs only its own tag: the good colours beside it survive the load.
    func testOneBadTagColourKeepsTheOthers() throws {
        let json = """
        {"version": 1, "drafts": [], "tasks": [], "tagColors": {"urgent": 3, "work": "red", "home": null}}
        """
        let file = try TasksFile.makeDecoder().decode(TasksFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.tagColors, ["work": .red])
    }
}
