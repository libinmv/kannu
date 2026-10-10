//
//  TimerSessionEventRulesTests.swift
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

/// A task's actual time is recorded from `TimerManager.sessionEvents`, so every way a session
/// starts, pauses, resumes or ends has to say so, in the right order. `TimerManager` and
/// `TasksManager` are not compiled into the logic target, so this reads their source (the
/// `TimerNamingRulesTests` idiom):
///
/// - every manual mutator emits;
/// - `.ended` is sent before `resetTimer()` (and, on a replace, before the new id is minted), so
///   it carries the ending session's id;
/// - a mirrored Clock-app timer never emits;
/// - nothing under `Kannu/managers/Tasks/` derives a start or a stop from `$isTimerActive` or
///   `$isPaused`, which coalesce (docs/REGRESSIONS.md entry 10).
final class TimerSessionEventRulesTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root
    private static let timerManagerPath = "Kannu/managers/TimerManager.swift"
    private static let tasksDirectory = "Kannu/managers/Tasks"

    private static func read(_ path: String) throws -> String {
        code(try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8))
    }

    // MARK: - The rules, on the real sources

    func testEveryManualMutatorEmitsInOrder() throws {
        XCTAssertEqual(Self.timerManagerProblems(in: try Self.read(Self.timerManagerPath)), [])
    }

    func testTasksNeverDeriveEventsFromPublishedFlags() throws {
        let folder = Self.repoRoot.appendingPathComponent(Self.tasksDirectory)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }
        XCTAssertTrue(files.contains("TasksManager.swift"), "the scan would be vacuous")
        var sources: [String: String] = [:]
        for name in files {
            sources[name] = try Self.read("\(Self.tasksDirectory)/\(name)")
        }
        XCTAssertEqual(Self.tasksProblems(in: sources), [])
    }

    // MARK: - The scanners catch planted offenders

    func testTheTimerScannerCatchesPlantedOffenders() {
        let planted = Self.code("""
            func startTimer(duration: TimeInterval) {
                sessionID = UUID()
                emit(.ended(.replaced))
                emit(.started)
            }
            func stopTimer() {
                if activeSource == .external { endExternalTimer(triggerSmoothClose: true); return }
                resetTimer()
                emit(.ended(.stopped))
            }
            func forceStopTimer() {
                if activeSource == .external { return }
                // emit(.ended(.stopped)) in a comment does not count
                resetTimer()
            }
            func pauseTimer() { isPaused = true }
            func resumeTimer() { isPaused = false; emit(.resumed) }
            func adoptExternalTimer(name: String) { emit(.started) }
            func updateExternalTimer(remaining: TimeInterval) {}
            func completeExternalTimer() {}
            func endExternalTimer(triggerSmoothClose: Bool) {}
            private func resetTimer() { sessionID = UUID() }
            private func emit(_ kind: TimerSessionEvent.Kind) {
                sessionEvents.send(TimerSessionEvent(kind: kind, session: sessionID, at: Date()))
            }
            """)
        let problems = Self.timerManagerProblems(in: planted)
        XCTAssertTrue(problems.contains { $0.hasPrefix("startTimer: .ended(.replaced)") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.hasPrefix("stopTimer: .ended") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.hasPrefix("forceStopTimer: never emits") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.hasPrefix("pauseTimer: never emits") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.hasPrefix("adoptExternalTimer: emits") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.hasPrefix("emit: not guarded") }, "\(problems)")
        XCTAssertFalse(problems.contains { $0.hasPrefix("resumeTimer") }, "resume is fine: \(problems)")
    }

    func testTheTasksScannerCatchesPlantedOffenders() {
        let planted = [
            "TasksManager.swift": Self.code("""
                // timer.$isTimerActive in a comment is fine
                timer.$isPaused.sink { paused in close() }
                timer.startTimer(duration: 60, name: task.title)
                """),
        ]
        let problems = Self.tasksProblems(in: planted)
        XCTAssertEqual(problems.filter { $0.contains("$isPaused") }.count, 1, "\(problems)")
        XCTAssertFalse(problems.contains { $0.contains("$isTimerActive") }, "comments are skipped: \(problems)")
        XCTAssertTrue(problems.contains { $0.contains("sessionEvents") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("TimerSessionName.resolved") }, "\(problems)")
    }

    // MARK: - Rules

    private static let manualMutators = ["startTimer", "stopTimer", "forceStopTimer", "pauseTimer", "resumeTimer"]
    private static let externalPaths = ["adoptExternalTimer", "updateExternalTimer", "completeExternalTimer",
                                        "endExternalTimer", "resetTimer"]

    static func timerManagerProblems(in source: String) -> [String] {
        var problems: [String] = []
        func index(of needle: String, in body: String) -> String.Index? { body.range(of: needle)?.lowerBound }

        for name in manualMutators {
            guard let body = functionBody(name, in: source) else {
                problems.append("\(name): not found")
                continue
            }
            if !body.contains("emit(.") { problems.append("\(name): never emits") }
        }

        if let body = functionBody("startTimer", in: source) {
            let mint = index(of: "sessionID = UUID()", in: body)
            let replaced = index(of: "emit(.ended(.replaced))", in: body)
            let started = index(of: "emit(.started)", in: body)
            if let mint, replaced.map({ $0 > mint }) ?? true {
                problems.append("startTimer: .ended(.replaced) must be sent before the new session id is minted")
            }
            if let mint, started.map({ $0 < mint }) ?? true {
                problems.append("startTimer: .started must be sent after the new session id is minted")
            }
        }

        for name in ["stopTimer", "forceStopTimer"] {
            guard let body = functionBody(name, in: source) else { continue }
            let ended = index(of: "emit(.ended(.stopped))", in: body)
            let reset = index(of: "resetTimer()", in: body)
            if let ended, let reset, ended > reset {
                problems.append("\(name): .ended must be sent before resetTimer(), which mints the next id")
            }
            // The Clock-app branch returns before anything is emitted.
            if let ended, let external = index(of: "return", in: body), external > ended {
                problems.append("\(name): emits before the external branch returns")
            }
        }

        for name in externalPaths {
            guard let body = functionBody(name, in: source) else { continue }
            if body.contains("emit(") || body.contains("sessionEvents") {
                problems.append("\(name): emits, but a Clock-app timer never has session events")
            }
        }

        if let body = functionBody("emit", in: source) {
            if !body.contains("guard activeSource == .manual") {
                problems.append("emit: not guarded by activeSource == .manual")
            }
            if !body.contains("sessionEvents.send(") {
                problems.append("emit: does not send on sessionEvents")
            }
        } else {
            problems.append("emit: not found")
        }
        return problems
    }

    static func tasksProblems(in sources: [String: String]) -> [String] {
        var problems: [String] = []
        for (name, source) in sources {
            for flag in ["$isTimerActive", "$isPaused"] where source.contains(flag) {
                problems.append("\(name): reads \(flag); use TimerManager.sessionEvents (REGRESSIONS entry 10)")
            }
        }
        let manager = sources["TasksManager.swift"] ?? ""
        if !manager.contains("sessionEvents") {
            problems.append("TasksManager.swift: does not subscribe to sessionEvents")
        }
        let starts = calls(of: "startTimer(", in: manager)
        if starts.isEmpty || starts.contains(where: { !$0.contains("TimerSessionName.resolved(") }) {
            problems.append("TasksManager.swift: a task's session must be named through TimerSessionName.resolved")
        }
        return problems.sorted()
    }

    // MARK: - Scanning

    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The braces of `func name(…) { … }`, balanced.
    private static func functionBody(_ name: String, in source: String) -> String? {
        guard let declaration = source.range(of: "func \(name)("),
              let open = source[declaration.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        repeat {
            if source[index] == "{" { depth += 1 } else if source[index] == "}" { depth -= 1 }
            index = source.index(after: index)
        } while index < source.endIndex && depth > 0
        return String(source[open..<index])
    }

    /// Each call that starts with `opener` (which ends in "("), through its balanced closing parenthesis.
    private static func calls(of opener: String, in text: String) -> [String] {
        var found: [String] = []
        var searchStart = text.startIndex
        while let range = text.range(of: opener, range: searchStart..<text.endIndex) {
            var depth = 1
            var index = range.upperBound
            while index < text.endIndex, depth > 0 {
                if text[index] == "(" { depth += 1 } else if text[index] == ")" { depth -= 1 }
                index = text.index(after: index)
            }
            found.append(String(text[range.lowerBound..<index]))
            searchStart = range.upperBound
        }
        return found
    }
}
