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

/// Brain › Tasks › Task list, pinned in the source the way `LaunchGateRulesTests` pins the launch:
///
/// - Rows reorder by real drag and drop. `ForEach.onMove` never drags inside a grouped `Form` on
///   macOS (the user's "there should be drag and drop"), so each row is `draggable` and a
///   `dropDestination`, and the drop goes through `TasksManager.move(_:onto:filter:)`, which honours
///   the filters. ⋯ › Move to Top / Up / Down stay.
/// - Task reminders ask macOS for notifications only from the user's first schedule, never at
///   launch, and Kannu never starts a timer on its own.
final class TaskListRulesTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let settingsPath = "Kannu/components/Settings/TasksSettings.swift"
    private static let managerPath = "Kannu/managers/Tasks/TasksManager.swift"
    private static let remindersPath = "Kannu/managers/Tasks/TaskReminders.swift"

    // MARK: - Drag and drop

    func testRowsDragAndDropInsteadOfOnMove() throws {
        XCTAssertEqual(Self.dragProblems(in: try Self.read(Self.settingsPath)), [])
    }

    func testTheDragScannerCatchesPlantedOffenders() {
        let good = Self.code("""
            ForEach(rows) { task in
                draggableRow(task, filter: filter)
            }
            taskRow(task, filter: filter)
                .draggable(dragPayload(for: task.id))
                .dropDestination(for: String.self) { items, _ in
                    manager.move(id, onto: task.id, filter: filter)
                    return true
                } isTargeted: { _ in }
            Button("Move to Top") { manager.moveToTop(task.id) }
            Button("Move Up") { manager.moveUp(task.id, filter: filter) }
            Button("Move Down") { manager.moveDown(task.id, filter: filter) }
            """)
        XCTAssertEqual(Self.dragProblems(in: good), [])
        XCTAssertEqual(Self.dragProblems(in: good + ".onMove { offsets, destination in }\n"),
                       ["the task rows still use onMove, which never drags inside a Form"])
        XCTAssertEqual(Self.dragProblems(in: good.replacingOccurrences(of: ".draggable(", with: ".onTapGesture(")),
                       ["the task rows are not draggable"])
        XCTAssertEqual(Self.dragProblems(in: good.replacingOccurrences(of: ".dropDestination(for: String.self)", with: ".onDrop(of: [])")),
                       ["the task rows take no drop"])
        XCTAssertEqual(Self.dragProblems(in: good.replacingOccurrences(of: "manager.move(id, onto: task.id, filter: filter)", with: "manager.move(id, onto: task.id)")),
                       ["a drop does not pass the filters"])
        XCTAssertEqual(Self.dragProblems(in: good.replacingOccurrences(of: "Button(\"Move Up\") { manager.moveUp(task.id, filter: filter) }", with: "")),
                       ["⋯ › Move Up is gone or ignores the filters"])
        // Prose about onMove is not a use of it.
        XCTAssertEqual(Self.dragProblems(in: good + Self.code("// .onMove never drags here\n")), [])
    }

    // MARK: - Reminders

    func testNotificationPermissionIsAskedOnlyFromTheFirstSchedule() throws {
        var sources: [String: String] = [:]
        for path in try Self.swiftFiles(under: "Kannu") { sources[path] = try Self.read(path) }
        XCTAssertGreaterThan(sources.count, 100, "the scan read almost nothing — check the path, not the rule")
        XCTAssertEqual(Self.permissionProblems(in: sources), [])
    }

    func testThePermissionScannerCatchesPlantedOffenders() {
        let reminders = Self.code("""
            static func requestPermission() async -> Permission {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            }
            """)
        let manager = Self.code("""
                func setSchedule(_ date: Date?, for taskID: UUID) {
                    Task { _ = await TaskReminders.requestPermission() }
                }

                func checkReminderPermission() {
                    Task { _ = await TaskReminders.permission() }
                }
            """)
        let good = [Self.remindersPath: reminders, Self.managerPath: manager]
        XCTAssertEqual(Self.permissionProblems(in: good), [])

        var elsewhere = good
        elsewhere["Kannu/KannuApp.swift"] = "center.requestAuthorization(options: [.alert, .sound]) { _, _ in }\n"
        XCTAssertEqual(Self.permissionProblems(in: elsewhere), ["Kannu/KannuApp.swift asks for notification permission"])

        var atAppear = good
        atAppear[Self.managerPath] = manager.replacingOccurrences(of: "await TaskReminders.permission()",
                                                                  with: "await TaskReminders.requestPermission()")
        XCTAssertEqual(Self.permissionProblems(in: atAppear), ["requestPermission() is called outside setSchedule"])

        var never = good
        never[Self.managerPath] = manager.replacingOccurrences(of: "_ = await TaskReminders.requestPermission()", with: "")
        XCTAssertEqual(Self.permissionProblems(in: never), ["setSchedule never asks: a reminder could never show"])
    }

    /// Start is the user's click on the reminder: the delegate starts the task only for the Start
    /// action, and nothing in the reminders file starts a timer by itself.
    func testOnlyTheStartActionStartsATask() throws {
        let reminders = try Self.read(Self.remindersPath)
        XCTAssertEqual(Self.occurrences(of: "startFromReminder(", in: reminders), 1)
        let startCall = try XCTUnwrap(reminders.range(of: "TasksManager.shared.startFromReminder("))
        let guardAction = try XCTUnwrap(reminders.range(of: "if response.action == TaskReminders.startActionID"))
        XCTAssertLessThan(guardAction.lowerBound, startCall.lowerBound, "a task starts without the Start action")
        XCTAssertFalse(reminders.contains("startTimer("), "the reminders file starts a timer itself")
        XCTAssertFalse(reminders.contains(".start("), "the reminders file starts a task itself")
    }

    /// The wiring the reviewer's findings turned on, read from the real sources:
    /// - a resend only adds, so scheduling one task never clears another's reminder on screen;
    /// - after the file is read, Kannu checks with macOS instead of trusting the file, and turning
    ///   tasks off takes every reminder back;
    /// - "Show all in Brain" and a reminder's click open the Task list itself, and a Start that
    ///   cannot start falls back to it.
    func testRemindersAndTheTaskListLinkAreWired() throws {
        let manager = try Self.read(Self.managerPath)
        let reminders = try Self.read(Self.remindersPath)
        let settings = try Self.read(Self.settingsPath)
        let menu = try Self.read("Kannu/components/Notch/TaskSourceMenu.swift")
        let resend = try XCTUnwrap(Self.functionBody("resendReminders", in: manager))
        XCTAssertTrue(resend.contains("TaskReminderPlan.resend("), "a resend can take reminders back again")
        XCTAssertFalse(resend.contains("TaskReminderPlan.changes(from: [:]"), "a resend can take reminders back again")
        let check = try XCTUnwrap(Self.functionBody("checkReminderPermission", in: manager))
        XCTAssertTrue(check.contains("TaskReminders.held()") && check.contains("TaskReminderPlan.reconcile("),
                      "the permission check no longer compares with what macOS holds")
        XCTAssertFalse(check.contains("wasBlocked"), "reminders are resent only after a blocked state again")
        XCTAssertTrue(try XCTUnwrap(Self.functionBody("apply", in: manager)).contains("checkReminderPermission()"),
                      "nothing checks with macOS after the file is read")
        XCTAssertTrue(settings.contains("if !isOn { TaskReminders.withdrawAll() }"), "turning tasks off leaves reminders waiting")
        XCTAssertTrue(menu.contains("case .taskList: return SettingsDeepLink.tasksListOpenID"),
                      "Show all in Brain lands on the row, not the Task list")
        XCTAssertTrue(settings.contains("showsTaskList = id == SettingsDeepLink.tasksListOpenID"),
                      "the Task list's deep link does not open it")
        XCTAssertTrue(reminders.contains("otherwise: { TasksBrainDestination.taskList.open() },"),
                      "a Start that cannot start is a silent no-op")
        let failed = try XCTUnwrap(manager.range(of: "loadState = .failed(reason)"))
        XCTAssertTrue(manager[failed.upperBound...].prefix(200).contains("pending.otherwise()"),
                      "a Start clicked before a failed load is dropped")
    }

    /// The notification's completion runs after the click is answered (CodeRabbit on #86: it ran
    /// first, so macOS took the response as handled while the start had not happened yet), and
    /// Tasks off empties the reminder baseline along with macOS, so Tasks on sends every reminder
    /// again instead of only the ones that changed since.
    func testAReminderIsCompletedAfterItsAnswerAndTasksOffEmptiesTheBaseline() throws {
        let manager = try Self.read(Self.managerPath)
        let reminders = try Self.read(Self.remindersPath)
        // The delegate completes another app's notification on arrival, and hands a reminder's on.
        XCTAssertEqual(Self.occurrences(of: "completionHandler()", in: reminders), 1, "a reminder is completed on arrival")
        XCTAssertTrue(reminders.contains("else {\n            completionHandler()\n            return\n        }"),
                      "the one completion on arrival is not the other-notification branch")
        XCTAssertTrue(reminders.contains("completion: completionHandler)"), "the completion never reaches the answer")
        XCTAssertTrue(reminders.contains("completion: response.completion\n"), "Start's completion never reaches TasksManager")
        XCTAssertTrue(reminders.contains("TasksBrainDestination.taskList.open()\n            response.completion()"),
                      "a click on the banner is completed before the Task list opens")
        // TasksManager completes after the start, the fallback or the load's failure, and completes
        // a click it discards for a later one.
        let start = try XCTUnwrap(Self.functionBody("startFromReminder", in: manager))
        XCTAssertTrue(start.contains("pendingReminderStart?.completion()\n            pendingReminderStart = (taskID, otherwise, completion)"),
                      "a replaced waiting click is never completed")
        XCTAssertTrue(start.contains("otherwise()\n            completion()"), "a failed load's fallback is not followed by the completion")
        XCTAssertTrue(start.contains("if !start(taskID) { otherwise() }\n            completion()"), "the completion runs before the start")
        XCTAssertTrue(try XCTUnwrap(Self.functionBody("apply", in: manager))
                        .contains("if !start(pending.taskID) { pending.otherwise() }\n            pending.completion()"),
                      "a click that waited for the file is not completed after its start")
        let failed = try XCTUnwrap(manager.range(of: "loadState = .failed(reason)"))
        XCTAssertTrue(manager[failed.upperBound...].prefix(300).contains("pending.otherwise()\n                pending.completion()"),
                      "a click that waited for a failed load is not completed after its fallback")
        // Tasks off: the baseline follows macOS; Tasks on: the reminders are sent again.
        let toggle = try XCTUnwrap(manager.range(of: "Defaults.publisher(.enableTasks, options: [])"),
                                   "TasksManager no longer watches the Tasks switch")
        let reaction = manager[toggle.upperBound...].prefix(600)
        XCTAssertTrue(reaction.contains("reminderBaseline = [:]"),
                      "Tasks off leaves the baseline full: after Tasks on, the next save sends only what changed")
        let resent = try XCTUnwrap(reaction.range(of: "checkReminderPermission()"),
                                   "Tasks on waits for the Task list to send the reminders again")
        // Tasks on also restores the baseline, ahead of the resend: left empty, the next save counts
        // every reminder as changed and takes a fired one off the screen (TaskReminderPlanTests).
        let restored = try XCTUnwrap(reaction.range(of: "reminderBaseline = TaskReminderPlan.wanted(self.tasks)"),
                                     "Tasks on leaves the baseline empty: the next save takes back a reminder that fired")
        XCTAssertLessThan(restored.lowerBound, resent.lowerBound, "the baseline is restored after the resend, not before it")
        // Off and on again within a moment: the removal, computed first, must land before the resend
        // reads what macOS holds, so both run on the one chain and neither in a Task of its own.
        let check = try XCTUnwrap(Self.functionBody("checkReminderPermission", in: manager))
        XCTAssertTrue(check.contains("TaskReminders.serially { [weak self] in"), "the resend runs outside the reminder chain")
        XCTAssertFalse(check.contains("Task {"), "the resend runs in a Task of its own, racing withdrawAll")
        let withdraw = try XCTUnwrap(Self.functionBody("withdrawAll", in: reminders))
        XCTAssertTrue(withdraw.contains("serially {"), "withdrawAll runs outside the reminder chain")
        XCTAssertFalse(withdraw.contains("Task {"), "withdrawAll runs in a Task of its own, racing the resend")
        // With the baseline empty and Tasks off, a save must not send the whole list back.
        XCTAssertTrue(try XCTUnwrap(Self.functionBody("syncReminders", in: manager))
                        .contains("Defaults[.enableTasks] ? TaskReminderPlan.wanted(tasks) : [:]"),
                      "a save with Tasks off sends every reminder again")
    }

    // MARK: - Rules

    static func dragProblems(in source: String) -> [String] {
        var problems: [String] = []
        if source.contains(".onMove") {
            problems.append("the task rows still use onMove, which never drags inside a Form")
        }
        if !source.contains(".draggable(") {
            problems.append("the task rows are not draggable")
        }
        if !source.contains(".dropDestination(for: String.self)") {
            problems.append("the task rows take no drop")
        }
        if !source.contains("manager.move(id, onto: task.id, filter: filter)") {
            problems.append("a drop does not pass the filters")
        }
        if !source.contains("Button(\"Move Up\") { manager.moveUp(task.id, filter: filter) }")
            || !source.contains("Button(\"Move Down\") { manager.moveDown(task.id, filter: filter) }")
            || !source.contains("Button(\"Move to Top\")") {
            problems.append("⋯ › Move Up is gone or ignores the filters")
        }
        return problems
    }

    /// `requestAuthorization(options:` only in TaskReminders.swift; `requestPermission()` called
    /// only inside `TasksManager.setSchedule`, which must call it.
    static func permissionProblems(in sources: [String: String]) -> [String] {
        var problems: [String] = []
        for (path, source) in sources.sorted(by: { $0.key < $1.key })
        where path != remindersPath && source.contains("requestAuthorization(options:") {
            problems.append("\(path) asks for notification permission")
        }
        for (path, source) in sources.sorted(by: { $0.key < $1.key }) where path != remindersPath {
            let calls = occurrences(of: "TaskReminders.requestPermission()", in: source)
            guard calls > 0 else { continue }
            let inSchedule = path == managerPath
                ? occurrences(of: "TaskReminders.requestPermission()", in: functionBody("setSchedule", in: source) ?? "")
                : 0
            if calls > inSchedule {
                problems.append("requestPermission() is called outside setSchedule")
            }
        }
        if let manager = sources[managerPath],
           !(functionBody("setSchedule", in: manager)?.contains("TaskReminders.requestPermission()") ?? false) {
            problems.append("setSchedule never asks: a reminder could never show")
        }
        return problems
    }

    // MARK: - Helpers

    private static func read(_ path: String) throws -> String {
        code(try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8))
    }

    private static func swiftFiles(under directory: String) throws -> [String] {
        let root = repoRoot.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var paths: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            paths.append(String(url.path.dropFirst(repoRoot.path.count + 1)))
        }
        return paths
    }

    /// A function's body: from its declaration to the next member declaration at the same indent.
    private static func functionBody(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "func \(name)(") else { return nil }
        let rest = text[start.upperBound...]
        let ends = ["\n    func ", "\n    private func ", "\n    static func ", "\n    @discardableResult"]
            .compactMap { rest.range(of: $0)?.lowerBound }
        return String(rest[..<(ends.min() ?? rest.endIndex)])
    }

    /// Source with comment lines dropped, so prose about a rule never trips it.
    private static func code(_ text: String) -> String {
        text.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("/*")
        }.joined(separator: "\n") + "\n"
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
