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

    /// CodeRabbit on #108: the user's own names came from Jira and GitLab only, so a GitHub task
    /// showed the user's own login as its person. One list now, from every source, in both places.
    func testTheUsersOwnNamesComeFromEverySourceInOnePlace() throws {
        let settings = try String(contentsOf: Self.repoRoot.appendingPathComponent("Kannu/managers/Tasks/TaskSourceSettings.swift"),
                                  encoding: .utf8)
        let names = try XCTUnwrap(settings.range(of: "static var selfNames: Set<String> {")
            .map { String(settings[$0.upperBound...].prefix(400)) }, "TaskSource.selfNames is gone")
        XCTAssertTrue(names.contains("allCases.compactMap { $0.accountNameKey") && names.contains("Defaults[.githubUsername]"),
                      "selfNames no longer covers every source's account")
        let page = try String(contentsOf: Self.repoRoot.appendingPathComponent("Kannu/components/Settings/TaskDetailPage.swift"),
                              encoding: .utf8)
        for (name, text) in [("TimerSideColumn", try Self.column()), ("TaskDetailPage", page)] {
            XCTAssertTrue(text.contains("selfNames: TaskSource.selfNames"), "\(name) does not use TaskSource.selfNames")
            XCTAssertFalse(text.contains("static var selfNames"), "\(name) keeps its own list of names again")
        }
    }

    func testDeleteIsLocalOnlyAndGoesThroughTheManager() throws {
        let card = try Self.declaration("private struct TimerTaskDetail", in: try Self.column())
        XCTAssertTrue(card.contains("manager.delete(task.id)"), "delete must go through the manager")
        XCTAssertTrue(card.contains("if summary.canDelete"), "the trash shows only when the summary allows (local tasks)")
        XCTAssertTrue(card.contains("manager.browseURL(for: task)"), "a remote task opens in its browser instead")
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
        XCTAssertTrue(card.contains(#".hoverTooltip(String(localized: "Status: \(summary.status.name)")"#),
                      "the status word is the pill's tooltip, named as a status")
        for colour in ["case .toDo: return .yellow", "case .inProgress: return .green", "case .closed: return .red"] {
            XCTAssertTrue(card.contains(colour), "missing \(colour)")
        }
        XCTAssertTrue(card.contains("manager.archive(task.id)"), "the card archives at once")
    }

    func testTheIconButtonsCarryTooltipsAndTheExpandRespectsReducedMotion() throws {
        let column = try Self.column()
        let card = try Self.declaration("private struct TimerTaskDetail", in: column)
        // "Edit Task", in title case (docs/TOOLTIPS.md), the same words as the pencils on the
        // running card and beside a task picked in the session bar: one string for one action.
        for tooltip in ["\"Close\"", "\"Delete task\"", "\"Archive\"", "\"Edit Task\""] {
            XCTAssertTrue(card.contains(tooltip), "missing tooltip text \(tooltip)")
        }
        XCTAssertGreaterThanOrEqual(card.components(separatedBy: ".hoverTooltip(").count - 1, 6,
                                    "the pencil, the ×, the key pill, archive, trash and open-in each carry a hover tooltip")
        XCTAssertTrue(card.contains("edit()"), "the pencil opens the left panel's task form")
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
        XCTAssertTrue(card.contains("HoverRevealText(summary.title, font: .system(size: 13, weight: .semibold), lines: 2)"),
                      "the card's title is summary.title alone, two lines, sliding up when longer")
        XCTAssertTrue(card.contains("summary.shortKey"), "the key shows as its own short chip")
        XCTAssertTrue(card.contains(".fixedSize(horizontal: false, vertical: true)"),
                      "a two-line title must not collapse (no notch title protects itself)")
        XCTAssertTrue(card.contains(".zIndex(1)"), "the top row paints above the chips so the × tooltip is never covered")
        let page = try Self.declaration("private struct TimerTasksPage", in: column)
        XCTAssertTrue(page.contains("HoverRevealText(task.title"), "the row's title is the title alone too")
    }

    func testClippedTextSlidesIntoViewAndThePillIsALabel() throws {
        // David: clipped text showed nothing on hover; it slides now. The pill's bare "Open"
        // tooltip read as an action that did nothing: it says "Status:" and is not a button.
        let column = try Self.column()
        let card = try Self.declaration("private struct TimerTaskDetail", in: column)
        XCTAssertTrue(card.contains(#"String(localized: "Status: \(summary.status.name)")"#), "the pill's tooltip names the status as one")
        XCTAssertFalse(card.contains(".hoverTooltip(summary.status.name"), "never the bare status word")
        XCTAssertTrue(card.contains("HoverRevealText(timeText(summary)"), "the time beside Start slides when clipped")
        let factCell = try Self.declaration("private struct FactCell", in: column)
        XCTAssertTrue(factCell.contains("HoverRevealText(fact.text"), "a clipped fact slides into view")
        XCTAssertFalse(factCell.contains("Text(verbatim: fact.text)"))
        let page = try Self.declaration("private struct TimerTasksPage", in: column)
        XCTAssertTrue(page.contains("isActive: isHovered"), "the row's one hover drives both its lines")
        XCTAssertEqual(page.components(separatedBy: "HoverRevealText(").count - 1, 2, "title and caption")
    }

    func testANeverTimedLocalTaskShowsItsNote() throws {
        // David: a local task with no time showed nothing between its title and Start; it says
        // so in grey now, where the facts go, and gives way before them.
        let card = try Self.declaration("private struct TimerTaskDetail", in: try Self.column())
        XCTAssertTrue(card.contains("factGrid(summary.facts, note: summary.note)"), "the card shows the summary's note")
        XCTAssertTrue(card.contains(".foregroundStyle(.tertiary)"), "the note is muted, not an alert")
    }

    func testTheCardIsContainedWhateverItsWords() throws {
        // A long label once widened the card past the column and pushed the × and the open icon
        // off the notch; a two-line title must never push Start out of the page either.
        let card = try Self.declaration("private struct TimerTaskDetail", in: try Self.column())
        XCTAssertTrue(card.contains(".frame(width: width, height: height"),
                      "the card is exactly the column's width and the page's height")
        XCTAssertTrue(card.contains("let width: CGFloat"), "the column's width comes in: the golden split of the notch")
        XCTAssertTrue(card.contains("ViewThatFits(in: .horizontal)"), "the chip row gives way instead of overflowing")
        XCTAssertTrue(card.contains("ViewThatFits(in: .vertical)"), "the fact grid fits the height left over")
        XCTAssertFalse(card.contains("TaskColorDot("),
                       "no dot: it drew nothing for plain glass yet indented the title past the chips")
    }

    /// David: the "linked MRs" fact opens a list of them, with back on the left, close on the right,
    /// and each one clickable through.
    func testTheLinkedMergeRequestsPage() throws {
        let column = try Self.column()
        let card = try Self.declaration("private struct TimerTaskDetail", in: column)
        XCTAssertTrue(card.contains("case .linkedMergeRequests:"), "the fact with the action is a button")
        XCTAssertTrue(card.contains(#".hoverTooltip(String(localized: "Show linked merge requests")"#))
        XCTAssertTrue(card.contains("TimerLinkedMRsPage("), "the page swaps in for the card, in its frame")
        XCTAssertTrue(card.contains("back: { showLinkedMRs(false) }") && card.contains("close: close"),
                      "Back returns to the card; Close returns to the list")

        let page = try Self.declaration("private struct TimerLinkedMRsPage", in: column)
        XCTAssertTrue(page.contains("@ObservedObject var manager: TasksManager") && !page.contains("TasksManager.shared"),
                      "the page reads the manager it is handed")
        XCTAssertTrue(page.contains("manager.linkedMergeRequests(for: task.id)"))
        let back = try XCTUnwrap(page.range(of: "Button(action: back)"))
        let close = try XCTUnwrap(page.range(of: "Button(action: close)"))
        XCTAssertLessThan(back.lowerBound, close.lowerBound, "Back on the left, Close on the right")
        XCTAssertTrue(page.contains(#".hoverTooltip(String(localized: "Back")"#) && page.contains(#".hoverTooltip(String(localized: "Close")"#))
        XCTAssertTrue(page.contains("NSWorkspace.shared.open(url)"), "each merge request opens in the browser")
        XCTAssertTrue(page.contains("ScrollView(.vertical)") && !page.contains("List {"), "a ScrollView, never a List")
        XCTAssertTrue(page.contains("attempt += 1"), "a failed load can be tried again")
    }

    /// David: closing a card brought the list back at the top, "not acceptable". The list stays in
    /// the tree under the card (and the Log page), hidden and inert, so its scroll offset survives.
    func testClosingACardKeepsTheListsPlace() throws {
        let page = try Self.declaration("private struct TimerTasksPage", in: try Self.column())
        XCTAssertTrue(page.contains("ZStack(alignment: .topLeading) {"), "the card draws over the list, not instead of it")
        XCTAssertTrue(page.contains(".opacity(isCovered ? 0 : 1)"), "the covered list is hidden, not removed")
        XCTAssertTrue(page.contains(".allowsHitTesting(!isCovered)"), "the covered list takes no clicks or hovers")
        XCTAssertTrue(page.contains(".accessibilityHidden(isCovered)"), "VoiceOver skips the covered list")
        XCTAssertFalse(page.contains("} else {\n            VStack(alignment: .leading, spacing: M.sideToolbarSpacing)"),
                       "the list is an else branch again: it would be rebuilt at the top")
        XCTAssertTrue(page.contains("hoveredRowID = nil"), "no row slides its text under the card")
    }

    func testATaskLeavingTheListCollapsesTheCard() throws {
        let page = try Self.declaration("private struct TimerTasksPage", in: try Self.column())
        XCTAssertTrue(page.contains("expandedTaskID = nil"), "nothing clears the expanded task")
        XCTAssertTrue(page.contains(".onChange(of: manager.activeTasks.map(\\.id))"),
                      "the page must watch the list for the expanded task leaving it")
    }
}
