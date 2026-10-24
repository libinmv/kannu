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

/// The notch's task form, read from the source because it is a SwiftUI view: the bell beside a
/// reminder turns that task's notification on or off, what was typed is kept while the form is
/// closed, and each text box has a clear button (David, 2026-10-23).
final class TaskFormWiringTests: XCTestCase {
    private static func form() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Kannu/components/Notch/TimerTaskForm.swift"), encoding: .utf8)
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// `TasksManager.swift`, comments removed: Add's and Save's bodies live there, shared with a
    /// preset clicked while the form shows and a typed name the form held.
    private static func manager() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Kannu/managers/Tasks/TasksManager.swift"), encoding: .utf8)
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The text from `start` to the next member at the same indent: enough to scope a pin to one
    /// function or property without parsing Swift.
    private static func body(_ start: String, in text: String) throws -> String {
        let range = try XCTUnwrap(text.range(of: start), "\(start) went away; update this test")
        let rest = text[range.upperBound...]
        let ends = ["\n    private func ", "\n    private var ", "\n    func ", "\n    var ", "\n    @MainActor",
                    "\n    static func ", "\n    private static func ", "\n    @discardableResult"]
        let end = ends.compactMap { rest.range(of: $0)?.lowerBound }.min() ?? rest.endIndex
        return String(rest[..<end])
    }

    func testTheBellTogglesThisTasksNotification() throws {
        let form = try Self.form()
        let toggle = try Self.body("private var notificationToggle: some View {", in: form)
        XCTAssertTrue(toggle.contains("draft.notifies.toggle()"), "the bell no longer turns this task's notification on and off")
        XCTAssertTrue(toggle.contains(".focusable(false)"), "a bell that takes focus releases the notch")
        XCTAssertTrue(toggle.contains("manager.notificationsDenied"), "orange must follow macOS's answer, not what the list wants")
        // Add and Save are the manager's (`addTask(from:)`, `applyEdits`), one path for the form's
        // buttons, a preset clicked while the form shows, and a typed name the form held.
        let manager = try Self.manager()
        XCTAssertTrue(try Self.body("func applyEdits(", in: manager).contains("case .notifies(let notifies): setReminderNotifies(notifies, for: id)"),
                      "Save no longer applies the bell")
        XCTAssertTrue(try Self.body("private func save() {", in: form).contains("manager.applyEdits(draft, to: id)"),
                      "Save no longer goes through the shared edit")
        XCTAssertTrue(try Self.body("func addTask(from draft: TaskFormDraft)", in: manager).contains("insertTask(from: draft)"),
                      "the notch's Add no longer goes through the add Brain shares")
        let insert = try Self.body("func insertTask(from draft: TaskFormDraft)", in: manager)
        let mute = try XCTUnwrap(insert.range(of: "setReminderNotifies(false, for: id)"), "Add no longer applies a bell turned off")
        let schedule = try XCTUnwrap(insert.range(of: "setSchedule(reminder, for: id)"))
        XCTAssertLessThan(mute.lowerBound, schedule.lowerBound, "mute first, so a muted reminder is never sent and taken back")
        XCTAssertTrue(try Self.body("private func add(andStart: Bool) {", in: form).contains("manager.addTask(from: draft)"),
                      "Add no longer goes through the shared add")
    }

    /// Brain's New Task adds through `insertTask` alone (David, 2026-10-24): a task half-typed in the
    /// notch stays kept, and the notch's Show local stays as the user left it.
    func testBrainsNewTaskLeavesTheNotchsFormAlone() throws {
        let insert = try Self.body("func insertTask(from draft: TaskFormDraft)", in: try Self.manager())
        XCTAssertFalse(insert.contains("forgetFormDraft("), "Brain's add would discard what the notch's form holds")
        XCTAssertFalse(insert.contains("showLocalTasks()"), "Brain's add would flip the notch's Show local")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sheet = try String(contentsOf: root.appendingPathComponent("Kannu/components/Settings/NewTaskSheet.swift"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(sheet.contains("manager.insertTask(from:"), "New Task no longer adds through insertTask")
        XCTAssertFalse(sheet.contains("addTask(from:"), "New Task must not use the notch's add")
    }

    func testWhatWasTypedIsKeptWhileTheFormIsClosed() throws {
        let form = try Self.form()
        XCTAssertTrue(form.contains(".onChange(of: draft) { _, typed in manager.keepFormDraft(typed) }"),
                      "the draft is no longer kept as it is typed")
        XCTAssertTrue(form.contains("TaskFormDraft.newTask(bar: TimerManager.shared.typedSessionName, kept: manager.keptFormDraft(editing: nil))"),
                      "a new task's form no longer opens on what was typed, and the bar's text")
        XCTAssertTrue(form.contains("manager.keptFormDraft(editing: id)"), "an edit no longer opens on its unsaved draft")
        XCTAssertTrue(try Self.body("func addTask(from draft: TaskFormDraft)", in: try Self.manager()).contains("forgetFormDraft(editing: nil)"),
                      "Add no longer forgets the new task's draft")
        XCTAssertTrue(try Self.body("private func save() {", in: form).contains("manager.forgetFormDraft(editing: id)"),
                      "Save no longer forgets the edit's draft")
        let dismiss = try Self.body("private func dismiss() {", in: form)
        XCTAssertTrue(dismiss.contains("if case .edit(let id) = mode { manager.forgetFormDraft(editing: id) }"),
                      "an edit's × or Escape no longer drops its draft")
        XCTAssertFalse(dismiss.contains("forgetFormDraft(editing: nil)"), "a new task's × must keep what was typed")
        XCTAssertFalse(form.contains(".onExitCommand(perform: close)"),
                       "Escape bypasses dismiss(), so an edit's draft would come back after Escape")
        XCTAssertTrue(try Self.body("private func exitTitle() {", in: form).contains("dismiss()"),
                      "Escape in the title no longer leaves the form once its list is closed")
    }

    /// The bar and a new task's title are one text (David, 2026-10-23): the form keeps its opening
    /// draft at once, writes its title back to the bar as it is typed, and the bar takes it back
    /// however the form closes; Add empties it.
    func testTheBarAndANewTasksTitleAreOneText() throws {
        let form = try Self.form()
        let appear = try XCTUnwrap(SwiftModifierScan.modifiers(".onAppear", in: form).first, "the form's onAppear went away")
        XCTAssertTrue(appear.contains("manager.keepFormDraft(draft)") && appear.contains("TaskFormDraft.barText(draft.title)"),
                      "the opening draft is not kept at once, or the bar does not show its title")
        let title = try XCTUnwrap(SwiftModifierScan.modifiers(".onChange", in: form).first { $0.hasPrefix(".onChange(of: draft.title)") },
                                  "the title no longer goes back to the bar as it is typed")
        XCTAssertTrue(title.contains("if draft.isNew { TimerManager.shared.typedSessionName = TaskFormDraft.barText(title) }"))
        XCTAssertTrue(try Self.body("private func add(andStart: Bool) {", in: form).contains("TimerManager.shared.typedSessionName = \"\""),
                      "Add leaves the added title in the bar")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let notch = try String(contentsOf: root.appendingPathComponent("Kannu/components/Notch/NotchTimerView.swift"), encoding: .utf8)
        let copies = SwiftModifierScan.modifiers(".onChange", in: notch).filter { $0.hasPrefix(".onChange(of: taskForm)") }
        XCTAssertEqual(copies.count, 1, "one copy-back for every way the form closes")
        XCTAssertTrue(copies.first?.contains("if form == nil { pendingSessionName = timerManager.typedSessionName }") ?? false,
                      "a closing form no longer gives the bar its text back")
    }

    func testEachTextBoxHasAClearButton() throws {
        let form = try Self.form()
        XCTAssertTrue(form.contains("clearButton(label: String(localized: \"Clear Title\"))"))
        XCTAssertTrue(form.contains("clearButton(label: String(localized: \"Clear Tags\"))"))
        let clear = try Self.body("private func clearButton(", in: form)
        XCTAssertTrue(clear.contains(".focusable(false)"), "a clear button that takes focus releases the notch")
        XCTAssertTrue(clear.contains(".hoverTooltip(label, edge: .below)") && clear.contains(".accessibilityLabel(Text(verbatim: label))"),
                      "the tooltip doubles as the accessibility label (docs/TOOLTIPS.md)")
    }

    /// The timer tab's session-name bar keeps a half-typed name while the notch is closed and has
    /// its own clear button (David, 2026-10-23).
    func testTheSessionNameSurvivesTheNotchClosing() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let notch = try String(contentsOf: root.appendingPathComponent("Kannu/components/Notch/NotchTimerView.swift"), encoding: .utf8)
        XCTAssertTrue(notch.contains("timerManager.typedSessionName = pendingSessionName"), "the typed name is no longer kept")
        // Scoped to onAppear: the form's copy-back says the same words, and would hide its loss.
        XCTAssertTrue(SwiftModifierScan.modifiers(".onAppear", in: notch).contains { $0.contains("pendingSessionName = timerManager.typedSessionName") },
                      "the tab no longer reopens on it")
        let field = try Self.body("private var sessionNameField: some View {", in: notch)
        XCTAssertTrue(field.contains("pendingSessionName = \"\"") && field.contains(".focusable(false)"),
                      "the session-name bar's clear button is gone or takes focus")
    }
}
