//
//  TimerLifecycleRulesTests.swift
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

/// `TimerManager`, the Clock-app bridge and the notch timer view are not in the logic target, so the
/// timer's lifecycle rules are read from their source (the `TimerNamingRulesTests` idiom). Each rule
/// is a bug that was in the code once, or a shape the fix would have had without it: a stop's delayed
/// smooth close ending the session started inside its 3 s, a close that cancels and re-arms on every
/// repeated completion report (a finished Clock timer is reported each second while it rings, so such
/// a close would never fire), a finished Clock timer's close leaving the session `.external` (so Start
/// stayed disabled), a Clock timer restarted inside that close's 3 s closed or ended by it, the
/// finished alarm looping on under a new session, a countdown tick ringing after a stop, and a focused
/// name field holding the notch open after a click into another app.
final class TimerLifecycleRulesTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root
    private static let managerPath = "Kannu/managers/TimerManager.swift"
    private static let bridgePath = "Kannu/managers/SystemTimerBridge.swift"
    private static let notchPath = "Kannu/components/Notch/NotchTimerView.swift"

    func testTheTimerManagerClosesAndTicksOnlyTheSessionItWasToldTo() throws {
        XCTAssertEqual(Self.managerProblems(in: try Self.source(Self.managerPath)), [])
    }

    func testTheBridgeDelayedCleanupEndsOnlyTheFinishedTimer() throws {
        XCTAssertEqual(Self.bridgeProblems(in: try Self.source(Self.bridgePath)), [])
    }

    func testTheNotchDropsTheNameFieldFocusWhenTheFieldCannotBeUsed() throws {
        XCTAssertEqual(Self.notchProblems(in: try Self.source(Self.notchPath)), [])
    }

    /// The close as it was on HEAD before the rules: a bare `asyncAfter` block.
    private static let staleClose = """
        private func scheduleSmoothClose() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                withAnimation(.easeInOut(duration: 1.0)) { self.isTimerActive = false }
            }
        }
        """

    /// A close that is cancellable and session-checked but cancels and re-arms on every call.
    private static let rearmingClose = """
        private func scheduleSmoothClose() {
            cancelSmoothClose()
            let session = sessionID
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.sessionID == session else { return }
                if self.activeSource == .external { self.resetTimer() } else { self.isTimerActive = false }
            }
            smoothCloseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
        }
        """

    private static let keptClose = rearmingClose.replacingOccurrences(
        of: "cancelSmoothClose()",
        with: "if smoothCloseWork != nil, smoothCloseSession == sessionID { return }; cancelSmoothClose()"
    )

    func testTheScannerCatchesPlantedManagerOffenders() {
        let planted = """
            // func startTimer(in a comment) { }
            func startTimer(duration: TimeInterval, name: String = "Timer", preset: TimerPreset? = nil) {
                timerInstance?.invalidate()
                withAnimation(.smooth) { isTimerActive = true }
                sessionID = UUID()
                timerInstance = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    Task { @MainActor in
                        if self.remainingTime == 0 { self.playTimerSound() }
                    }
                }
            }
            func resumeTimer() {
                timerInstance = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    guard let self, self.sessionID == session else { return }
                    Task { @MainActor in
                        if self.remainingTime == 0 { self.playTimerSound() }
                    }
                }
            }
            func adoptExternalTimer(name: String, remaining: TimeInterval) {
                soundPlayer?.stop()
                activeSource = .external
            }
            func updateExternalTimer(remaining: TimeInterval) {
                remainingTime = remaining
            }
            private func cancelSmoothClose() {
                smoothCloseWork = nil
            }

            """ + Self.staleClose
        XCTAssertEqual(Self.managerProblems(in: planted), [
            "scheduleSmoothClose is not a cancellable DispatchWorkItem",
            "scheduleSmoothClose's block does not check the session it was armed for",
            "scheduleSmoothClose does not keep its work item",
            "scheduleSmoothClose does not dispatch its work item",
            "scheduleSmoothClose re-arms a close already pending for the session",
            "scheduleSmoothClose's block leaves a finished Clock timer's session external",
            "cancelSmoothClose does not cancel the work item",
            "startTimer( does not cancel a pending smooth close",
            "adoptExternalTimer( does not cancel a pending smooth close",
            "adoptExternalTimer( does not give the session a new id",
            "startTimer( does not stop the finished alarm",
            "updateExternalTimer( does not cancel the finished timer's pending close",
            "a countdown closure does not check the session inside its main-actor job",
            "a countdown closure does not check the session inside its main-actor job",
        ])
        let fixed = planted
            .replacingOccurrences(of: "timerInstance?.invalidate()", with: "timerInstance?.invalidate(); soundPlayer?.stop(); cancelSmoothClose()")
            .replacingOccurrences(of: "if self.remainingTime == 0", with: "guard self.sessionID == session else { return }\nif self.remainingTime == 0")
            .replacingOccurrences(of: "activeSource = .external", with: "cancelSmoothClose(); activeSource = .external; sessionID = UUID()")
            .replacingOccurrences(of: "remainingTime = remaining", with: "if remaining > 0 { cancelSmoothClose() }; remainingTime = remaining")
            .replacingOccurrences(of: "smoothCloseWork = nil", with: "smoothCloseWork?.cancel(); smoothCloseWork = nil")
            .replacingOccurrences(of: Self.staleClose, with: Self.keptClose)
        XCTAssertEqual(Self.managerProblems(in: fixed), [])
        XCTAssertEqual(Self.managerProblems(in: fixed.replacingOccurrences(of: Self.keptClose, with: Self.rearmingClose)), [
            "scheduleSmoothClose re-arms a close already pending for the session",
        ])
    }

    func testTheScannerCatchesAPlantedBridgeOffender() {
        let planted = """
            private func clearLogState(triggerSmoothClose: Bool) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                    if TimerManager.shared.isExternalTimerActive {
                        TimerManager.shared.endExternalTimer(triggerSmoothClose: false)
                    }
                }
            }
            """
        XCTAssertEqual(Self.bridgeProblems(in: planted), [
            "the delayed cleanup ends whatever Clock timer is running, not only the finished one",
        ])
        let fixed = planted.replacingOccurrences(of: "isExternalTimerActive {", with: "isExternalTimerActive, TimerManager.shared.isFinished {")
        XCTAssertEqual(Self.bridgeProblems(in: fixed), [])
    }

    func testTheScannerCatchesPlantedNotchOffenders() {
        let planted = """
            .onChange(of: timerManager.isTimerActive) { _, isActive in
                if isActive { lockAccentColorIfNeeded() } else { isRenamingSession = false }
            }
            .onChange(of: focusedNameField) { previous, current in
                vm.setAutoCloseSuppression(current != nil, token: nameEditingToken)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
                if note.object is KannuWindow { commitRename() }
            }
            """
        XCTAssertEqual(Self.notchProblems(in: planted), [
            "a click into another app leaves the name field focused, so the notch never auto-closes",
            "a stopped timer leaves the name field focused",
            "a timer starting or stopping leaves the task form in the composer's place",
        ])
        let fixed = planted
            .replacingOccurrences(of: "{ _, isActive in", with: "{ _, isActive in\n    taskForm = nil")
            .replacingOccurrences(of: "isRenamingSession = false", with: "isRenamingSession = false; focusedNameField = nil")
            .replacingOccurrences(of: "commitRename() }", with: "commitRename(); focusedNameField = nil }")
        XCTAssertEqual(Self.notchProblems(in: fixed), [])
    }

    // MARK: - Rules

    private static func managerProblems(in text: String) -> [String] {
        let source = code(text)
        var problems: [String] = []
        if let close = functionBody(named: "scheduleSmoothClose(", in: source) {
            if !close.contains("DispatchWorkItem") {
                problems.append("scheduleSmoothClose is not a cancellable DispatchWorkItem")
            }
            if !close.contains("sessionID == session") {
                problems.append("scheduleSmoothClose's block does not check the session it was armed for")
            }
            if !close.contains("smoothCloseWork = work") {
                problems.append("scheduleSmoothClose does not keep its work item")
            }
            if !close.contains("execute: work") {
                problems.append("scheduleSmoothClose does not dispatch its work item")
            }
            // A pending close for the same session must be kept, so the guard precedes the cancel.
            let rearms: Bool
            if let pendingGuard = close.range(of: "smoothCloseSession == sessionID")?.lowerBound {
                rearms = close.range(of: "cancelSmoothClose()").map { $0.lowerBound < pendingGuard } ?? false
            } else {
                rearms = true
            }
            if rearms {
                problems.append("scheduleSmoothClose re-arms a close already pending for the session")
            }
            if !close.contains("resetTimer()") {
                problems.append("scheduleSmoothClose's block leaves a finished Clock timer's session external")
            }
        } else {
            problems.append("scheduleSmoothClose( not found")
        }
        if let cancel = functionBody(named: "cancelSmoothClose(", in: source) {
            if !cancel.contains(".cancel()") {
                problems.append("cancelSmoothClose does not cancel the work item")
            }
        } else {
            problems.append("cancelSmoothClose( not found")
        }
        let starts = ["startTimer(", "adoptExternalTimer("].compactMap { name -> (String, String)? in
            guard let body = functionBody(named: name, in: source) else {
                problems.append("\(name) not found")
                return nil
            }
            return (name, body)
        }
        for (name, body) in starts where !body.contains("cancelSmoothClose()") {
            problems.append("\(name) does not cancel a pending smooth close")
        }
        for (name, body) in starts where !body.contains("sessionID = UUID()") {
            problems.append("\(name) does not give the session a new id")
        }
        for (name, body) in starts where name == "startTimer(" && !body.contains("soundPlayer?.stop()") {
            problems.append("\(name) does not stop the finished alarm")
        }
        if let update = functionBody(named: "updateExternalTimer(", in: source) {
            if !update.contains("cancelSmoothClose()") {
                problems.append("updateExternalTimer( does not cancel the finished timer's pending close")
            }
        } else {
            problems.append("updateExternalTimer( not found")
        }
        let countdowns = trailingClosures(after: "Timer.scheduledTimer(", in: source)
        if countdowns.isEmpty {
            problems.append("no countdown closure found")
        }
        // The stop can land between the tick firing and its queued main-actor job running, so the
        // check has to be inside that job, not in the Timer callback around it.
        for countdown in countdowns {
            let job = taskBodies(in: countdown).first ?? countdown
            if !job.contains("sessionID == session") {
                problems.append("a countdown closure does not check the session inside its main-actor job")
            }
        }
        return problems
    }

    private static func bridgeProblems(in text: String) -> [String] {
        guard let cleanup = functionBody(named: "clearLogState(", in: code(text)) else {
            return ["clearLogState( not found"]
        }
        return cleanup.contains("isFinished")
            ? []
            : ["the delayed cleanup ends whatever Clock timer is running, not only the finished one"]
    }

    private static func notchProblems(in text: String) -> [String] {
        let source = code(text)
        var problems: [String] = []
        let resigns = modifiers(".onReceive", in: source).filter { $0.contains("didResignKeyNotification") }
        if resigns.isEmpty {
            problems.append("no didResignKeyNotification observer found")
        }
        for _ in resigns.filter({ !$0.contains("focusedNameField = nil") }) {
            problems.append("a click into another app leaves the name field focused, so the notch never auto-closes")
        }
        let stops = modifiers(".onChange", in: source).filter { $0.hasPrefix(".onChange(of: timerManager.isTimerActive)") }
        if stops.isEmpty {
            problems.append("no isTimerActive observer found")
        }
        for _ in stops.filter({ !$0.contains("focusedNameField = nil") }) {
            problems.append("a stopped timer leaves the name field focused")
        }
        for _ in stops.filter({ !$0.contains("taskForm = nil") }) {
            problems.append("a timer starting or stopping leaves the task form in the composer's place")
        }
        return problems
    }

    // MARK: - Scanning

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The balanced body of the first `func` whose name starts with `opener` (which ends in "(").
    private static func functionBody(named opener: String, in text: String) -> String? {
        guard let range = text.range(of: "func " + opener) else { return nil }
        let afterParameters = closingParenthesis(from: range.upperBound, in: text)
        guard let open = text[afterParameters...].firstIndex(of: "{") else { return nil }
        return balancedBraces(from: open, in: text)
    }

    /// Each call of `opener` (which ends in "(") that carries a trailing closure: that closure.
    private static func trailingClosures(after opener: String, in text: String) -> [String] {
        var found: [String] = []
        var searchStart = text.startIndex
        while let range = text.range(of: opener, range: searchStart..<text.endIndex) {
            var probe = closingParenthesis(from: range.upperBound, in: text)
            while probe < text.endIndex, text[probe] == " " { probe = text.index(after: probe) }
            if probe < text.endIndex, text[probe] == "{" {
                found.append(balancedBraces(from: probe, in: text))
            }
            searchStart = range.upperBound
        }
        return found
    }

    /// The balanced body of each `Task { ... }` in `text`.
    private static func taskBodies(in text: String) -> [String] {
        var found: [String] = []
        var searchStart = text.startIndex
        while let range = text.range(of: "Task {", range: searchStart..<text.endIndex) {
            let open = text.index(before: range.upperBound)
            found.append(balancedBraces(from: open, in: text))
            searchStart = range.upperBound
        }
        return found
    }

    /// From just inside an opening parenthesis, the index after its matching close.
    private static func closingParenthesis(from start: String.Index, in text: String) -> String.Index {
        var depth = 1
        var index = start
        while index < text.endIndex, depth > 0 {
            if text[index] == "(" { depth += 1 } else if text[index] == ")" { depth -= 1 }
            index = text.index(after: index)
        }
        return index
    }

    /// From an opening brace, through its matching close.
    private static func balancedBraces(from open: String.Index, in text: String) -> String {
        var depth = 0
        var index = open
        repeat {
            if text[index] == "{" { depth += 1 } else if text[index] == "}" { depth -= 1 }
            index = text.index(after: index)
        } while index < text.endIndex && depth > 0
        return String(text[open..<index])
    }

    /// Each use of a modifier: its name, its balanced argument list if any, then its trailing closure if any.
    private static func modifiers(_ name: String, in text: String) -> [String] {
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
