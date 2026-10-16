//
//  TimerTaskDetailRulesTests.swift
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

/// The timer tab's expanded task card is a view, not in the logic target, so its wiring is read
/// from the source (the `TimerSideColumnRulesTests` idiom). What is pinned, and why:
///
/// 1. The card takes the manager as a parameter and never spells `TasksManager.shared`: only
///    `TimerTasksPage` may, so the manager exists only while the Tasks page shows.
/// 2. Delete is offered only to a local task and goes through `manager.delete(`; a remote task
///    would come back on the next sync, so it gets an open-in link instead.
/// 3. Delete confirms inline, never with `.alert` or `confirmationDialog`: modals under the notch
///    have misbehaved before (docs/REGRESSIONS.md entry 14), and the notch is ambient.
/// 4. The ×, the trash and the open-in button are icon-only, so they carry hover tooltips
///    (docs/TOOLTIPS.md); the expand/collapse respects reduced motion like the page switch.
/// 5. A task that leaves the list (deleted, done, resynced away) collapses the card.
final class TimerTaskDetailRulesTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func column() throws -> String {
        let path = repoRoot.appendingPathComponent("Kannu/components/Notch/TimerSideColumn.swift")
        return code(try String(contentsOf: path, encoding: .utf8))
    }

    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// A column-0 declaration through its closing brace at column 0.
    private static func declaration(_ name: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: "\n\(name)"), "\(name) not found at column 0")
        let end = try XCTUnwrap(text.range(of: "\n}\n", range: start.upperBound..<text.endIndex),
                                "\(name) has no closing brace at column 0")
        return String(text[start.lowerBound..<end.upperBound])
    }

    func testTheCardTakesTheManagerAndNeverReadsShared() throws {
        let card = try Self.declaration("private struct TimerTaskDetail", in: try Self.column())
        XCTAssertTrue(card.contains("@ObservedObject var manager: TasksManager"),
                      "the card must receive the manager; TimerTasksPage owns the only .shared read")
        XCTAssertFalse(card.contains("TasksManager.shared"))
    }

    func testDeleteIsLocalOnlyAndGoesThroughTheManager() throws {
        let card = try Self.declaration("private struct TimerTaskDetail", in: try Self.column())
        XCTAssertTrue(card.contains("manager.delete(task.id)"), "delete must go through the manager")
        XCTAssertTrue(card.contains("if summary.canDelete"), "the trash shows only when the summary allows (local tasks)")
        XCTAssertTrue(card.contains("jiraBrowseURL(for:") && card.contains("gitlabBrowseURL(for:"),
                      "a remote task opens in its browser instead")
    }

    func testDeleteConfirmsInlineNeverWithAModal() throws {
        let column = try Self.column()
        XCTAssertFalse(column.contains(".alert("), "no .alert in the side column (REGRESSIONS entry 14)")
        XCTAssertFalse(column.contains("confirmationDialog("), "no confirmationDialog in the side column")
        let card = try Self.declaration("private struct TimerTaskDetail", in: column)
        XCTAssertTrue(card.contains("if confirmsDelete"), "the inline two-step confirm is gone")
        XCTAssertTrue(card.contains("role: .destructive"), "the final Delete is a destructive button")
    }

    func testStatusIsTheKeyPillsColourAndArchiveIsAtHand() throws {
        // David: the status is a colour, not a word — yellow to do, green in progress, red closed —
        // on the task number's pill; the word stays as its tooltip and what VoiceOver reads.
        let column = try Self.column()
        let card = try Self.declaration("private struct TimerTaskDetail", in: column)
        XCTAssertFalse(card.contains("SideChip(summary.status.name"), "no status chip: the key pill's colour is the status")
        XCTAssertTrue(card.contains("tint: Self.phaseColor(summary.status.phase)"), "the key pill takes the status colour")
        XCTAssertTrue(card.contains(".hoverTooltip(summary.status.name"), "the status word is the pill's tooltip")
        for colour in ["case .toDo: return .yellow", "case .inProgress: return .green", "case .closed: return .red"] {
            XCTAssertTrue(card.contains(colour), "missing \(colour)")
        }
        XCTAssertTrue(card.contains("manager.archive(task.id)"), "the card archives at once")
    }

    func testTheIconButtonsCarryTooltipsAndTheExpandRespectsReducedMotion() throws {
        let column = try Self.column()
        let card = try Self.declaration("private struct TimerTaskDetail", in: column)
        for tooltip in ["\"Close\"", "\"Delete task\"", "\"Archive\""] {
            XCTAssertTrue(card.contains(tooltip), "missing tooltip text \(tooltip)")
        }
        XCTAssertGreaterThanOrEqual(card.components(separatedBy: ".hoverTooltip(").count - 1, 5,
                                    "the ×, the key pill, archive, trash and open-in each carry a hover tooltip")
        let page = try Self.declaration("private struct TimerTasksPage", in: column)
        XCTAssertTrue(page.contains("accessibilityReduceMotion"), "the expand must respect reduced motion")
        XCTAssertTrue(page.contains("expandedTaskID"))
    }

    func testTheTitleIsNeverPrefixedByTheKey() throws {
        // A GitLab path key in front of the title ate both lines of the first card; the title is
        // the issue's own, and the key is a short chip of its own.
        let column = try Self.column()
        XCTAssertFalse(column.contains("sideKeyText"), "the key-prefixed text helper must stay gone")
        let card = try Self.declaration("private struct TimerTaskDetail", in: column)
        XCTAssertTrue(card.contains("Text(verbatim: summary.title)"), "the card's title is summary.title alone")
        XCTAssertTrue(card.contains("summary.shortKey"), "the key shows as its own short chip")
        XCTAssertTrue(card.contains(".fixedSize(horizontal: false, vertical: true)"),
                      "a two-line title must not collapse (no notch title protects itself)")
        XCTAssertTrue(card.contains(".zIndex(1)"), "the top row paints above the chips so the × tooltip is never covered")
        let page = try Self.declaration("private struct TimerTasksPage", in: column)
        XCTAssertTrue(page.contains("Text(verbatim: task.title)"), "the row's title is the title alone too")
    }

    func testTheCardIsContainedWhateverItsWords() throws {
        // A long label once widened the card past the column and pushed the × and the open icon
        // off the notch; a two-line title must never push Start out of the page either.
        let card = try Self.declaration("private struct TimerTaskDetail", in: try Self.column())
        XCTAssertTrue(card.contains(".frame(width: M.sideColumnWidth, height: height"),
                      "the card is exactly the column's width and the page's height")
        XCTAssertTrue(card.contains("ViewThatFits(in: .horizontal)"), "the chip row gives way instead of overflowing")
        XCTAssertTrue(card.contains("ViewThatFits(in: .vertical)"), "the fact grid fits the height left over")
        XCTAssertFalse(card.contains("TaskColorDot("),
                       "no dot: it drew nothing for plain glass yet indented the title past the chips")
    }

    func testATaskLeavingTheListCollapsesTheCard() throws {
        let page = try Self.declaration("private struct TimerTasksPage", in: try Self.column())
        XCTAssertTrue(page.contains("expandedTaskID = nil"), "nothing clears the expanded task")
        XCTAssertTrue(page.contains(".onChange(of: manager.activeTasks.map(\\.id))"),
                      "the page must watch the list for the expanded task leaving it")
    }
}
