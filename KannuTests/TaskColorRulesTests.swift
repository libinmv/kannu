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

/// Where a task's colour shows is view code, so it is read from the source (the
/// `TimerSideColumnRulesTests` idiom):
///
/// - the notch popover's Up next rows and its Now card, and the timer tab's Tasks page rows, draw
///   their background through `TaskGlassBackground(color: manager.color(of: task))` — no bare
///   `Color.white.opacity` fill is left on them, or that row would ignore the task's colour;
/// - Brain's task rows lead with a `TaskColorDot` of the same colour, once a listed task has one;
/// - `TaskColorViews.swift` never uses `.help(`: its views sit in the notch, where it never renders
///   (docs/TOOLTIPS.md);
/// - the Tags sheet's pills reorder — by drag and drop through `TaskTagEditing.moving`, by a
///   right-click "Move to Front" menu, and by the same move as a named VoiceOver action — since the
///   first tag gives the task its colour; and its Done saves the colours picked there with the
///   tags, Cancel neither.
///
/// Each detector has a planted-offender test, so a scanner that stops matching fails instead of
/// passing vacuously.
final class TaskColorRulesTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root
    static let popoverPath = "Kannu/components/Notch/TasksPopover.swift"
    static let sideColumnPath = "Kannu/components/Notch/TimerSideColumn.swift"
    static let settingsPath = "Kannu/components/Settings/TasksSettings.swift"
    static let viewsPath = "Kannu/components/Tasks/TaskColorViews.swift"
    static let tagsSheetPath = "Kannu/components/Settings/TaskTagsSheet.swift"

    static let tinted = "TaskGlassBackground(color: manager.color(of: task)"
    static let bareFills = [".fill(Color.white.opacity(", ".background(Color.white.opacity("]

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - The rules, on the real sources

    func testThePopoverRowsAndTheNowCardShowTheTaskColour() throws {
        let popover = try Self.read(Self.popoverPath)
        XCTAssertEqual(Self.glassProblems(in: popover, function: "func upNextRow("), [])
        XCTAssertEqual(Self.glassProblems(in: popover, function: "func nowSection(", base: "0.08"), [])
    }

    func testTheTimerTaskRowsShowTheTaskColour() throws {
        let column = try Self.read(Self.sideColumnPath)
        XCTAssertEqual(Self.glassProblems(in: column, function: "func row(_ task: TaskItem"), [])
    }

    func testBrainTaskRowsLeadWithTheTaskColourDot() throws {
        let settings = try Self.read(Self.settingsPath)
        XCTAssertEqual(Self.dotProblems(in: settings), [])
    }

    func testTheColourViewsNeverUseHelp() throws {
        XCTAssertEqual(Self.helpCalls(in: try Self.read(Self.viewsPath)), [],
                       "TaskColorViews.swift uses .help( — use .hoverTooltip or an accessibility label")
    }

    func testTheTagsSheetReordersItsPillsAndSavesColoursOnDone() throws {
        XCTAssertEqual(Self.tagsSheetProblems(in: try Self.read(Self.tagsSheetPath)), [])
    }

    // MARK: - Planted offenders

    func testTheGlassScannerCatchesPlantedOffenders() {
        let bare = """
            private func upNextRow(_ task: TaskItem) -> some View {
                HStack { Text("a") }
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
            }
            """
        XCTAssertEqual(Self.glassProblems(in: bare, function: "func upNextRow("),
                       ["func upNextRow( does not use \(Self.tinted))", "func upNextRow( keeps a bare .fill(Color.white.opacity("])
        let card = """
            private func nowSection(_ task: TaskItem, isPaused: Bool) -> some View {
                VStack { Text("a") }
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            """
        XCTAssertEqual(Self.glassProblems(in: card, function: "func nowSection(", base: "0.08").count, 2)
        let wrongBase = """
            private func nowSection(_ task: TaskItem, isPaused: Bool) -> some View {
                VStack { Text("a") }.background(TaskGlassBackground(color: manager.color(of: task)))
            }
            """
        XCTAssertEqual(Self.glassProblems(in: wrongBase, function: "func nowSection(", base: "0.08"),
                       ["func nowSection( does not use \(Self.tinted), base: 0.08)"])
        let good = """
            private func row(_ task: TaskItem, tooltipEdge: HoverTooltipEdge) -> some View {
                HStack { Text("a") }.background(TaskGlassBackground(color: manager.color(of: task)))
            }
            private func statusRow(_ text: String) -> some View {
                Text(text).background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
            }
            """
        XCTAssertEqual(Self.glassProblems(in: good, function: "func row(_ task: TaskItem"), [])
        XCTAssertEqual(Self.glassProblems(in: good, function: "func missing("), ["func missing( not found"])
    }

    func testTheDotScannerCatchesPlantedOffenders() {
        let plain = """
            private func taskLabel(_ task: TaskItem, now: Date) -> some View {
                SettingsRowLabel(Text(verbatim: task.title), description: progressText(for: task, now: now))
            }
            """
        XCTAssertEqual(Self.dotProblems(in: plain), ["taskLabel has no TaskColorDot(color: manager.color(of: task))"])
        let dotted = """
            private func taskLabel(_ task: TaskItem, now: Date) -> some View {
                HStack { TaskColorDot(color: manager.color(of: task)); SettingsRowLabel(Text(task.title)) }
            }
            """
        XCTAssertEqual(Self.dotProblems(in: dotted), [])
    }

    func testTheHelpScannerCatchesPlantedOffenders() {
        XCTAssertEqual(Self.helpCalls(in: "Circle()\n    .help(\"Orange\")"), ["2"])
        XCTAssertEqual(Self.helpCalls(in: "// never .help(\"x\")\n * .help(\"y\")"), [])
    }

    func testTheTagsSheetScannerCatchesPlantedOffenders() {
        let pill = """
            private func pill(_ tag: String, at index: Int) -> some View {
                HStack { Text(tag) }
                    .draggable(tag)
                    .dropDestination(for: String.self) { items, _ in
                        tags = TaskTagEditing.moving(items[0], to: index, in: tags); return true
                    }
                    .contextMenu { Button("Move to Front") { } }
                    .accessibilityAction(named: Text("Move to Front")) { }
            }
            """
        let cancel = "Button(\"Cancel\", role: .cancel) { dismiss() }\n"
        let done = "Button(\"Done\") {\n    manager.setTags(tags, for: id)\n    manager.setTagColors(picks)\n    dismiss()\n}\n"
        XCTAssertEqual(Self.tagsSheetProblems(in: pill + cancel + done), [])

        let undraggable = pill.replacingOccurrences(of: ".draggable(tag)", with: "")
        XCTAssertEqual(Self.tagsSheetProblems(in: undraggable + cancel + done), ["pill has no .draggable(tag)"])
        let noMenu = pill.replacingOccurrences(of: "Button(\"Move to Front\") { }", with: "")
        XCTAssertEqual(Self.tagsSheetProblems(in: noMenu + cancel + done), ["pill has no Button(\"Move to Front\")"])
        let noAction = pill.replacingOccurrences(of: ".accessibilityAction(named: Text(\"Move to Front\")) { }", with: "")
        XCTAssertEqual(Self.tagsSheetProblems(in: noAction + cancel + done),
                       ["pill has no .accessibilityAction(named: Text(\"Move to Front\"))"])
        let noDrop = pill.replacingOccurrences(of: ".dropDestination(for: String.self)", with: ".onDrop(of: [])")
        XCTAssertEqual(Self.tagsSheetProblems(in: noDrop + cancel + done),
                       ["pill has no .dropDestination(for: String.self)"])

        let tagsOnly = done.replacingOccurrences(of: "    manager.setTagColors(picks)\n", with: "")
        XCTAssertEqual(Self.tagsSheetProblems(in: pill + cancel + tagsOnly), ["Done does not call setTagColors("])
        let savingCancel = "Button(\"Cancel\", role: .cancel) { manager.setTagColors(picks); dismiss() }\n"
        XCTAssertEqual(Self.tagsSheetProblems(in: pill + savingCancel + done), ["Cancel calls setTagColors("])
        XCTAssertEqual(Self.tagsSheetProblems(in: ""),
                       ["func pill( not found", "Button(\"Done\") not found", "Button(\"Cancel\" not found"])
    }
}

// MARK: - Scanners

extension TaskColorRulesTests {
    /// The braces of the first function whose declaration contains `function`, matched by depth.
    static func body(of function: String, in source: String) -> Substring? {
        guard let declaration = source.range(of: function),
              let open = source.range(of: "{", range: declaration.upperBound..<source.endIndex) else { return nil }
        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return source[open.lowerBound...index] }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// What keeps a task row from showing its colour: no `TaskGlassBackground` of the task's colour
    /// (at `base`, when the row has its own), or a bare white fill left beside it.
    static func glassProblems(in source: String, function: String, base: String? = nil) -> [String] {
        guard let body = body(of: function, in: source) else { return ["\(function) not found"] }
        let expected = base.map { "\(tinted), base: \($0))" } ?? "\(tinted))"
        var problems: [String] = []
        if !body.contains(expected) { problems.append("\(function) does not use \(expected)") }
        problems += bareFills.filter { body.contains($0) }.map { "\(function) keeps a bare \($0)" }
        return problems
    }

    /// Brain's task label without the colour dot.
    static func dotProblems(in source: String) -> [String] {
        let dot = "TaskColorDot(color: manager.color(of: task))"
        guard let body = body(of: "func taskLabel(", in: source) else { return ["taskLabel not found"] }
        return body.contains(dot) ? [] : ["taskLabel has no \(dot)"]
    }

    /// What keeps the Tags sheet's pills from reordering, or its colour picks from being saved with
    /// the tags on Done — or lets Cancel save either.
    static func tagsSheetProblems(in source: String) -> [String] {
        var problems: [String] = []
        if let pill = body(of: "func pill(", in: source) {
            let reorder = [
                ".draggable(tag)", ".dropDestination(for: String.self)", "TaskTagEditing.moving(", "Button(\"Move to Front\")",
                ".accessibilityAction(named: Text(\"Move to Front\"))",
            ]
            problems += reorder.filter { !pill.contains($0) }.map { "pill has no \($0)" }
        } else {
            problems.append("func pill( not found")
        }
        let saves = ["setTags(", "setTagColors("]
        if let done = body(of: "Button(\"Done\")", in: source) {
            problems += saves.filter { !done.contains($0) }.map { "Done does not call \($0)" }
        } else {
            problems.append("Button(\"Done\") not found")
        }
        if let cancel = body(of: "Button(\"Cancel\"", in: source) {
            problems += saves.filter { cancel.contains($0) }.map { "Cancel calls \($0)" }
        } else {
            problems.append("Button(\"Cancel\" not found")
        }
        return problems
    }

    /// Line numbers of `.help(` on a line that is not a comment (the pre-commit hook's rule).
    static func helpCalls(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard line.contains(".help("), !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { return nil }
            return String(index + 1)
        }
    }
}

// MARK: - The running timer's accent

/// The running timer's accent is the timed task's colour, ahead of the preset's: every accent site
/// reads `TimerManager.sessionAccent`, and none outside `TimerManager` looks the preset's colour up
/// itself (`activePreset?.color`, an `activePresetColor` helper, a `$0.id == presetId` lookup) — a
/// site that did would show the preset's colour over a coloured task. `TimerManager` clears the
/// session's tint wherever a session ends or a Clock-app timer takes over, so the next session
/// never inherits it. `NotchTimerView` re-locks its accent whenever `sessionAccent` changes (a new
/// tint, a new preset, or a session with neither) without reaching for `TasksManager`.
extension TaskColorRulesTests {
    static let timerManagerPath = "Kannu/managers/TimerManager.swift"
    static let notchTimerPath = "Kannu/components/Notch/NotchTimerView.swift"
    static let accentSitePaths = [
        notchTimerPath,
        "Kannu/components/Timer/TimerLiveActivity.swift",
        "Kannu/ContentView.swift",
        "Kannu/components/Timer/TimerIconAnimation.swift",
        "Kannu/components/Timer/TimerPopover.swift",
        "Kannu/components/Notch/MinimalisticMusicPlayerView.swift",
        "Kannu/components/LockScreen/LockScreenTimerWidget.swift",
    ]
    static let presetColorReads = ["activePreset?.color", "activePreset!.color", "activePresetColor", "$0.id == presetId"]

    func testNoAccentSiteOutsideTimerManagerReadsThePresetColour() throws {
        let appRoot = Self.repoRoot.appendingPathComponent("Kannu")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))
        var scanned = 0
        var problems: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            guard !url.path.hasSuffix("/" + Self.timerManagerPath) else { continue }
            scanned += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            problems += Self.presetColorProblems(in: source, path: url.lastPathComponent)
        }
        XCTAssertGreaterThan(scanned, 50, "the scan found too few Swift files to mean anything")
        XCTAssertEqual(problems, [])
    }

    func testEveryAccentSiteReadsTheSessionAccent() throws {
        for path in Self.accentSitePaths {
            XCTAssertTrue(try Self.read(path).contains("timerManager.sessionAccent"), "\(path) does not read sessionAccent")
        }
        let notchTimer = try Self.read(Self.notchTimerPath)
        XCTAssertTrue(notchTimer.contains(".onChange(of: timerManager.sessionAccent)"), "NotchTimerView does not re-lock on sessionAccent")
        XCTAssertFalse(notchTimer.contains("TasksManager"), "NotchTimerView mentions TasksManager")
    }

    func testTimerManagerClearsTheSessionTint() throws {
        XCTAssertEqual(Self.sessionTintProblems(in: try Self.read(Self.timerManagerPath)), [])
    }

    func testThePresetColourScannerCatchesPlantedOffenders() {
        let helper = "private var activePresetColor: Color? {\n"
            + "    guard let presetId = timerManager.activePresetId else { return nil }\n"
            + "    return timerPresets.first { $0.id == presetId }?.color\n}"
        XCTAssertEqual(Self.presetColorProblems(in: helper, path: "A.swift"),
                       ["A.swift:1 reads activePresetColor", "A.swift:3 reads $0.id == presetId"])
        XCTAssertEqual(Self.presetColorProblems(in: "return timerManager.activePreset?.color ?? .white", path: "B.swift"),
                       ["B.swift:1 reads activePreset?.color"])
        XCTAssertEqual(Self.presetColorProblems(in: "// never activePreset?.color\n/// nor activePresetColor", path: "C.swift"), [])
        XCTAssertEqual(Self.presetColorProblems(in: "return timerManager.sessionAccent ?? timerManager.timerColor", path: "D.swift"), [])
    }

    func testTheSessionTintScannerCatchesPlantedOffenders() {
        let start = "func startTimer(duration: TimeInterval, tint: Color? = nil) { activePresetId = nil; sessionTint = tint }\n"
        let adopt = "func adoptExternalTimer(name: String) { activePresetId = nil; sessionTint = nil }\n"
        let reset = "private func resetTimer() { activePresetId = nil; sessionTint = nil }\n"
        let update = "func updateSessionTint(_ tint: Color?, session: UUID) { guard session == sessionID else { return }; sessionTint = tint }\n"
        XCTAssertEqual(Self.sessionTintProblems(in: start + adopt + reset + update), [])

        let keepsOnStart = start.replacingOccurrences(of: "; sessionTint = tint", with: "")
        XCTAssertEqual(Self.sessionTintProblems(in: keepsOnStart + adopt + reset + update),
                       ["func startTimer( does not set sessionTint = tint"])
        let keepsOnAdopt = adopt.replacingOccurrences(of: "; sessionTint = nil", with: "")
        XCTAssertEqual(Self.sessionTintProblems(in: start + keepsOnAdopt + reset + update),
                       ["func adoptExternalTimer( does not set sessionTint = nil"])
        let keepsOnReset = reset.replacingOccurrences(of: "; sessionTint = nil", with: "")
        XCTAssertEqual(Self.sessionTintProblems(in: start + adopt + keepsOnReset + update),
                       ["private func resetTimer( does not set sessionTint = nil"])
        let anySession = update.replacingOccurrences(of: "guard session == sessionID else { return }; ", with: "")
        XCTAssertEqual(Self.sessionTintProblems(in: start + adopt + reset + anySession),
                       ["func updateSessionTint( does not check session == sessionID"])
        XCTAssertEqual(Self.sessionTintProblems(in: "").count, 4)
    }

    /// Lines outside comments that look the preset's colour up instead of reading `sessionAccent`.
    static func presetColorProblems(in source: String, path: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().flatMap { index, line -> [String] in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { return [] }
            return presetColorReads.filter { line.contains($0) }.map { "\(path):\(index + 1) reads \($0)" }
        }
    }

    /// Where `TimerManager` would let one session's tint outlive it, or land on another session.
    static func sessionTintProblems(in source: String) -> [String] {
        let rules: [(function: String, needle: String, problem: String)] = [
            ("func startTimer(", "sessionTint = tint", "does not set sessionTint = tint"),
            ("func adoptExternalTimer(", "sessionTint = nil", "does not set sessionTint = nil"),
            ("private func resetTimer(", "sessionTint = nil", "does not set sessionTint = nil"),
            ("func updateSessionTint(", "session == sessionID", "does not check session == sessionID"),
        ]
        return rules.compactMap { rule in
            guard let body = body(of: rule.function, in: source) else { return "\(rule.function) not found" }
            return body.contains(rule.needle) ? nil : "\(rule.function) \(rule.problem)"
        }
    }
}
