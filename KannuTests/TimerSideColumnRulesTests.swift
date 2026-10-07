//
//  TimerSideColumnRulesTests.swift
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

/// The timer tab's side column is a view, not in the logic target, so its wiring is read from the
/// source (the `TimerNamingRulesTests` idiom):
///
/// - `NotchTimerView` never touches `TasksManager`: the Tasks page is a child view of its own, and
///   only it reads `TasksManager.shared`, so the manager is never built while tasks are off;
/// - a task's ▶ does nothing more when `start` fails;
/// - every scroll-suppression token is `@State`: a plain `let` is minted again on each re-render, so
///   the release names a token that was never set and the notch's scroll gesture stays off;
/// - "connected", for the page the tab opens on, is a host being set: the column never reads Sync
///   Jira or Sync GitLab, which only decide what is fetched;
/// - the Tasks page refreshes a stale Jira or GitLab sync when it appears, as the popover does;
/// - no `.help(` in the new notch files (docs/REGRESSIONS.md entry 9).
///
/// Each detector has a planted-offender test, so a scanner that stops matching fails instead of
/// passing vacuously.
final class TimerSideColumnRulesTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root
    static let notchTimerPath = "Kannu/components/Notch/NotchTimerView.swift"
    static let sideColumnPath = "Kannu/components/Notch/TimerSideColumn.swift"
    static let swipeMonitorPath = "Kannu/components/Notch/HorizontalSwipeMonitor.swift"
    static let rulerPath = "Kannu/components/Timer/RulerTimerPicker.swift"

    private static func raw(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - The rules, on the real sources

    func testNotchTimerViewNeverTouchesTasksManager() throws {
        XCTAssertEqual(Self.tasksManagerUses(in: Self.code(try Self.raw(Self.notchTimerPath))), [])
    }

    func testOnlyTheTasksPageReadsTheManager() throws {
        let source = Self.code(try Self.raw(Self.sideColumnPath))
        XCTAssertEqual(Self.managerOwnerProblems(in: source), [])
    }

    func testATaskStartsOnlyWhenTheManagerSaysItDid() throws {
        let source = Self.code(try Self.raw(Self.sideColumnPath))
        XCTAssertTrue(source.contains("guard manager.start(task.id) else { return }"),
                      "a failed start must do nothing else (the typed name stays)")
    }

    func testScrollSuppressionTokensAreState() throws {
        for path in [Self.sideColumnPath, Self.rulerPath] {
            XCTAssertEqual(Self.tokenProblems(in: Self.code(try Self.raw(path))), [], path)
        }
    }

    func testConnectedMeansAHostIsSetNotThatSyncIsOn() throws {
        let source = Self.code(try Self.raw(Self.sideColumnPath))
        XCTAssertTrue(source.contains("Defaults[.jiraSiteHost]") && source.contains("Defaults[.gitlabHost]"),
                      "the column no longer reads the hosts: the scan is vacuous")
        XCTAssertEqual(Self.syncSwitchReads(in: source), [])
    }

    func testTheTasksPageRefreshesAStaleSyncOnAppear() throws {
        let source = Self.code(try Self.raw(Self.sideColumnPath))
        XCTAssertTrue(source.contains("manager.syncJiraIfStale()"), "the Tasks page shows a stale Jira order")
        XCTAssertTrue(source.contains("manager.syncGitLabIfStale()"), "the Tasks page shows a stale GitLab order")
    }

    func testTheNewNotchFilesNeverUseHelp() throws {
        for path in [Self.sideColumnPath, Self.swipeMonitorPath] {
            XCTAssertEqual(Self.helpCalls(in: try Self.raw(path)), [], "\(path): .help never renders in the notch")
        }
    }

    // MARK: - The scanners catch planted offenders

    func testTheTasksManagerScannerCatchesPlantedOffenders() {
        let good = Self.code("""
            // TasksManager in a comment is prose
            TimerSideColumn(page: $sidePage)
            """)
        XCTAssertEqual(Self.tasksManagerUses(in: good), [])
        XCTAssertEqual(Self.tasksManagerUses(in: Self.code("_ = TasksManager.shared.start(id)")).count, 1)
    }

    func testTheOwnerScannerCatchesPlantedOffenders() {
        let good = """
            struct TimerSideColumn: View {
                var body: some View { TimerTasksPage() }
            }

            private struct TimerTasksPage: View {
                @ObservedObject private var manager = TasksManager.shared
            }
            """
        XCTAssertEqual(Self.managerOwnerProblems(in: good), [])
        let eager = good.replacingOccurrences(of: "struct TimerSideColumn: View {",
                                              with: "struct TimerSideColumn: View {\n    @ObservedObject var m = TasksManager.shared")
        XCTAssertEqual(Self.managerOwnerProblems(in: eager).count, 1)
        let missing = good.replacingOccurrences(of: "TasksManager.shared", with: "Other.shared")
        XCTAssertEqual(Self.managerOwnerProblems(in: missing).count, 1, "no reader at all is vacuous")
    }

    func testTheTokenScannerCatchesPlantedOffenders() {
        XCTAssertEqual(Self.tokenProblems(in: "    @State private var scrollSuppressionToken = UUID()"), [])
        XCTAssertEqual(Self.tokenProblems(in: "    private let scrollSuppressionToken = UUID()").count, 1)
        XCTAssertEqual(Self.tokenProblems(in: "    private var scrollSuppressionToken = UUID()").count, 1)
        XCTAssertEqual(Self.tokenProblems(in: "    vm.set(true, token: scrollSuppressionToken)").count, 1,
                       "no declaration at all is vacuous")
    }

    func testTheSyncSwitchScannerCatchesPlantedOffenders() {
        let good = Self.code("""
            // Defaults[.jiraEnabled] in a comment is prose
            jiraConnected: !Defaults[.jiraSiteHost].isEmpty,
            """)
        XCTAssertEqual(Self.syncSwitchReads(in: good), [])
        let planted = Self.code("""
            jiraConnected: !Defaults[.jiraSiteHost].isEmpty && Defaults[.jiraEnabled],
            gitlabConnected: !Defaults[.gitlabHost].isEmpty && Defaults[.gitlabEnabled]
            @Default(.jiraEnabled) private var jiraEnabled
            """)
        XCTAssertEqual(Self.syncSwitchReads(in: planted).count, 3)
    }

    func testTheHelpScannerCatchesPlantedOffenders() {
        let planted = """
            // .help("in a comment") is prose
            /// `.help(...)` in a doc comment is prose
            Text("x").help("Never renders")
            """
        XCTAssertEqual(Self.helpCalls(in: planted), ["3"])
    }

    // MARK: - Scanning

    /// The source without comment lines.
    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("/*")
            }
            .joined(separator: "\n")
    }

    private static func tasksManagerUses(in code: String) -> [String] {
        code.split(separator: "\n").filter { $0.contains("TasksManager") }.map(String.init)
    }

    /// `TasksManager.shared` is read, and only inside `TimerTasksPage`, the view built only while the
    /// Tasks page shows. Top-level declarations start at column 0.
    private static func managerOwnerProblems(in code: String) -> [String] {
        var owner = ""
        var readers: [String] = []
        for line in code.split(separator: "\n") {
            if let first = line.first, !first.isWhitespace, line.contains("struct ") || line.contains("extension ") {
                owner = String(line)
            }
            if line.contains("TasksManager.shared") { readers.append(owner) }
        }
        if readers.isEmpty { return ["nothing reads TasksManager.shared: the scan is vacuous"] }
        return readers.filter { !$0.contains("struct TimerTasksPage") }.map { "read outside TimerTasksPage: \($0)" }
    }

    /// Every `scrollSuppressionToken` declaration is `@State var`, and there is one.
    private static func tokenProblems(in code: String) -> [String] {
        let declarations = code.split(separator: "\n").filter {
            $0.contains("scrollSuppressionToken") && ($0.contains(" let ") || $0.contains(" var "))
        }
        if declarations.isEmpty { return ["no scrollSuppressionToken declaration"] }
        return declarations.filter { !($0.contains("@State") && $0.contains(" var ")) }.map(String.init)
    }

    /// Lines that read Sync Jira or Sync GitLab. Those switches only decide what is fetched; whether
    /// a source is connected, for the page the tab opens on, is whether its host is set.
    private static func syncSwitchReads(in code: String) -> [String] {
        code.split(separator: "\n")
            .filter { $0.contains(".jiraEnabled") || $0.contains(".gitlabEnabled") }
            .map(String.init)
    }

    /// Line numbers of `.help(` on a line that is not a comment (the pre-commit hook's rule).
    private static func helpCalls(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard line.contains(".help("), !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { return nil }
            return String(index + 1)
        }
    }
}
