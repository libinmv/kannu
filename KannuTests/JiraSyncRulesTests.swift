//
//  JiraSyncRulesTests.swift
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

/// How `TasksManager` orders Jira's asynchronous work, read from the source (the
/// `IntegrationSecretRulesTests` idiom): the manager is not in the logic target.
///
/// - Refresh during a sync is kept, not dropped. A sync carries the filter it started with, so
///   Return or Reset on the issue filter while one runs would otherwise end with "Synced" for the
///   old filter and tasks marked gone against it. `finishJiraSync` runs the kept refresh, after it
///   has cleared the in-flight sync and published that sync's state (`refreshJira`'s guards read
///   both); Connect and Disconnect drop it with the sync they replace.
/// - Every write to `jiraSync` outside Connect, Disconnect and the sync's own start sits behind
///   `guard generation == jiraGeneration`, and every `finishJiraSync(` call passes the generation
///   its sync captured at the start, so a late answer — a 401 for a token that has since been
///   replaced — never marks the new sign-in refused.
/// - "Remove Token" refuses while a Connect is in flight: the display copies say disconnected
///   until the save lands, and a delete queued behind that save would take the new token with it.
///   The Connect itself re-checks cancellation and the generation right before the save, with no
///   await between the save and the display copies.
///
/// Each detector has a planted-offender test, so a scanner that stops matching fails instead of
/// passing vacuously.
final class JiraSyncRulesTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root
    private static let managerPath = "Kannu/managers/Tasks/TasksManager.swift"

    private static func manager() throws -> String {
        code(try String(contentsOf: repoRoot.appendingPathComponent(managerPath), encoding: .utf8))
    }

    // MARK: - The rules, on the real source

    func testARefreshDuringASyncIsKeptAndRunAfterIt() throws {
        XCTAssertEqual(Self.refreshProblems(in: try Self.manager()), [])
    }

    func testEverySyncStateWriteSitsBehindTheGenerationCheck() throws {
        XCTAssertEqual(Self.generationProblems(in: try Self.manager()), [])
    }

    func testRemoveTokenRefusesWhileAConnectIsInFlight() throws {
        XCTAssertEqual(Self.connectProblems(in: try Self.manager()), [])
    }

    // MARK: - The scanners catch planted offenders

    func testTheRefreshScannerCatchesPlantedOffenders() {
        let original = """
            func refreshJira(now: Date = Date()) {
                guard isJiraSyncOn, isReady, !isJiraSyncing else { return }
                syncJira(interactive: true, using: nil)
            }
            func connectJira(siteInput: String, email: String, token: String) async -> String? { jiraGeneration += 1 }
            func disconnectJira(removeTasks: Bool) { jiraGeneration += 1 }
            private func finishJiraSync(_ generation: Int, _ state: JiraSyncState) {
                guard generation == jiraGeneration else { return }
                jiraSync = state
            }
            """
        let problems = Self.refreshProblems(in: original)
        XCTAssertEqual(problems.count, 4, "the original shape: dropped, never run, kept across Connect and Disconnect: \(problems)")
        XCTAssertEqual(Self.refreshProblems(in: Self.fixedRefresh), [])
        // The kept refresh run while the sync it waited for still counts as in flight, or before
        // the ended sync's state is published: both pass a scanner that only looks for the calls.
        let beforeInFlight = Self.fixedRefresh
            .replacingOccurrences(of: "    refreshJira()\n", with: "")
            .replacingOccurrences(of: "    jiraSyncInFlight = nil\n", with: "    refreshJira()\n    jiraSyncInFlight = nil\n")
        XCTAssertEqual(Self.refreshProblems(in: beforeInFlight),
                       ["finishJiraSync: runs the kept refresh before jiraSyncInFlight = nil, jiraSync = state, pendingJiraRefresh = false"])
        let beforeState = Self.fixedRefresh
            .replacingOccurrences(of: "    refreshJira()\n", with: "")
            .replacingOccurrences(of: "    jiraSync = state\n", with: "    refreshJira()\n    jiraSync = state\n")
        XCTAssertEqual(Self.refreshProblems(in: beforeState),
                       ["finishJiraSync: runs the kept refresh before jiraSync = state, pendingJiraRefresh = false"])
        XCTAssertFalse(Self.refreshProblems(in: "func somethingElse() {}").isEmpty, "a missing function is a problem")
    }

    func testTheGenerationScannerCatchesPlantedOffenders() {
        let unguarded = """
            private func didFetchJira(_ outcome: SyncOutcome, failure: JiraClient.Failure?, host: String, generation: Int) {
                if case .http(.auth(let status)) = failure { jiraSync = .authFailed(status: status) }
            }
            private func finishJiraSync(_ generation: Int, _ state: JiraSyncState) {
                jiraSync = state
                guard generation == jiraGeneration else { return }
            }
            func connectJira(siteInput: String, email: String, token: String) async -> String? { jiraSync = .idle }
            private func syncJira(interactive: Bool, using known: JiraCredential?) { jiraSync = .syncing }
            """
        let problems = Self.generationProblems(in: unguarded)
        XCTAssertEqual(problems.count, 2, "the write with no check, and the check after the write: \(problems)")
        XCTAssertTrue(problems.contains { $0.hasPrefix("didFetchJira") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.hasPrefix("finishJiraSync") }, "\(problems)")
        XCTAssertEqual(Self.generationProblems(in: Self.fixedRefresh + Self.fixedFetch), [])
        XCTAssertFalse(Self.generationProblems(in: "func somethingElse() { jiraSync == .idle }").isEmpty, "a missing function is a problem")
        // A finish that compares the live generation with itself: the guard inside holds vacuously.
        for stale in ["jiraGeneration", "self.jiraGeneration"] {
            let vacuous = Self.fixedRefresh + Self.fixedFetch.replacingOccurrences(of: "finishJiraSync(generation,", with: "finishJiraSync(\(stale),")
            XCTAssertEqual(Self.generationProblems(in: vacuous), ["didFetchJira: finishes a sync with \(stale), not the generation it captured"])
        }
    }

    func testTheConnectScannerCatchesPlantedOffenders() {
        let original = """
            func connectJira(siteInput: String, email: String, token: String) async -> String? {
                let credential = JiraCredential(site: host, email: email, token: token)
                switch await JiraClient().verify(credential) {
                case .verified(let myself): verified = myself
                case .failed(let failure): return nil
                }
                guard !Task.isCancelled else { return String(localized: "Cancelled.") }
                guard await JiraCredentialStore.save(credential) else { return nil }
                Defaults[.jiraSiteHost] = host
                jiraGeneration += 1
                return nil
            }
            func retryRemovingJiraToken() {
                guard !isJiraConnected else { return }
                removeJiraToken()
            }
            """
        let problems = Self.connectProblems(in: original)
        XCTAssertEqual(problems.count, 4, "not counted, not uncounted, saved on a stale check, Remove Token not refusing: \(problems)")
        // The count moved past the verify: a Remove Token during the verify slips through.
        let late = Self.fixedConnect
            .replacingOccurrences(of: "jiraConnectsInFlight += 1\n", with: "")
            .replacingOccurrences(of: "guard !Task.isCancelled", with: "jiraConnectsInFlight += 1\n    guard !Task.isCancelled")
        XCTAssertEqual(Self.connectProblems(in: late), ["connectJira: counts itself in flight only after its first await"])
        XCTAssertEqual(Self.connectProblems(in: Self.fixedConnect), [])
        XCTAssertFalse(Self.connectProblems(in: "func somethingElse() {}").isEmpty, "a missing function is a problem")
    }

    // MARK: - Fixed shapes

    static let fixedRefresh = """
        func refreshJira(now: Date = Date()) {
            guard isJiraSyncOn, isReady else { return }
            guard !isJiraSyncing else {
                pendingJiraRefresh = true
                return
            }
            syncJira(interactive: true, using: nil)
        }
        func connectJira(siteInput: String, email: String, token: String) async -> String? {
            jiraGeneration += 1
            pendingJiraRefresh = false
            jiraSync = .idle
        }
        func disconnectJira(removeTasks: Bool) {
            jiraGeneration += 1
            pendingJiraRefresh = false
            jiraSync = .idle
        }
        private func finishJiraSync(_ generation: Int, _ state: JiraSyncState) {
            guard generation == jiraGeneration else { return }
            jiraSyncInFlight = nil
            jiraSync = state
            guard pendingJiraRefresh else { return }
            pendingJiraRefresh = false
            refreshJira()
        }
        private func syncJira(interactive: Bool, using known: JiraCredential?) { jiraSync = .syncing }

        """

    static let fixedFetch = """
        private func didFetchJira(_ outcome: SyncOutcome, failure: JiraClient.Failure?, host: String, generation: Int) {
            guard generation == jiraGeneration else { return }
            finishJiraSync(generation, .authFailed(status: 401))
        }
        """

    static let fixedConnect = """
        func connectJira(siteInput: String, email: String, token: String) async -> String? {
            let credential = JiraCredential(site: host, email: email, token: token)
            let generation = jiraGeneration
            jiraConnectsInFlight += 1
            defer { jiraConnectsInFlight -= 1 }
            switch await JiraClient().verify(credential) {
            case .verified(let myself): verified = myself
            case .failed(let failure): return nil
            }
            guard !Task.isCancelled, generation == jiraGeneration else { return String(localized: "Cancelled.") }
            guard await JiraCredentialStore.save(credential) else { return nil }
            Defaults[.jiraSiteHost] = host
            jiraGeneration += 1
            return nil
        }
        func retryRemovingJiraToken() {
            guard !isJiraConnected, jiraConnectsInFlight == 0 else { return }
            removeJiraToken()
        }
        """

    // MARK: - Scanners

    /// Refresh during a sync is kept in `pendingJiraRefresh`, run by `finishJiraSync` once the ended
    /// sync is out of flight and its state published, and dropped by Connect and Disconnect with the
    /// sync they replace.
    static func refreshProblems(in source: String) -> [String] {
        guard let refresh = functionBody("refreshJira", in: source) else { return ["refreshJira: not found"] }
        var problems: [String] = []
        if !refresh.contains("pendingJiraRefresh = true") {
            problems.append("refreshJira: drops a refresh asked during a sync")
        }
        if let finish = functionBody("finishJiraSync", in: source) {
            if let run = finish.range(of: "refreshJira("), finish.contains("pendingJiraRefresh = false") {
                // The kept refresh goes through `refreshJira`'s own guards, which read the sync this
                // finish is ending: still in flight, the refresh is kept again and stuck until some
                // later sync; still `.syncing`, the rate-limit guard passes, a new sync starts, and
                // `jiraSync = state` then overwrites its `.syncing` with the ended sync's result.
                let late = ["jiraSyncInFlight = nil", "jiraSync = state", "pendingJiraRefresh = false"].filter { statement in
                    guard let range = finish.range(of: statement) else { return true }
                    return range.lowerBound > run.lowerBound
                }
                if !late.isEmpty {
                    problems.append("finishJiraSync: runs the kept refresh before \(late.joined(separator: ", "))")
                }
            } else {
                problems.append("finishJiraSync: does not run the kept refresh")
            }
        } else {
            problems.append("finishJiraSync: not found")
        }
        for name in ["connectJira", "disconnectJira"] {
            guard let body = functionBody(name, in: source) else {
                problems.append("\(name): not found")
                continue
            }
            if !body.contains("pendingJiraRefresh = false") {
                problems.append("\(name): keeps a refresh asked for the setup it replaces")
            }
        }
        return problems
    }

    /// Functions that bump the generation themselves, or set `.syncing` synchronously at a sync's start.
    static let generationOwners = ["connectJira", "disconnectJira", "syncJira"]

    /// Every other function that writes `jiraSync` checks `guard generation == jiraGeneration` first,
    /// and every `finishJiraSync(` call passes the `generation` its caller captured when the sync
    /// started: `finishJiraSync`'s own check compares against that argument, so a caller passing the
    /// live `jiraGeneration` would make the check hold vacuously and let a late answer through.
    static func generationProblems(in source: String) -> [String] {
        let functions = allFunctions(in: source)
        var problems: [String] = []
        for required in ["didFetchJira", "finishJiraSync"] where !functions.contains(where: { $0.name == required }) {
            problems.append("\(required): not found")
        }
        let finishCall = try? NSRegularExpression(pattern: #"finishJiraSync\(\s*(\w+(?:\.\w+)?)\s*,"#)
        for function in functions {
            for match in finishCall?.matches(in: function.body, range: NSRange(function.body.startIndex..., in: function.body)) ?? [] {
                guard let argument = Range(match.range(at: 1), in: function.body).map({ String(function.body[$0]) }),
                      argument != "generation" else { continue }
                problems.append("\(function.name): finishes a sync with \(argument), not the generation it captured")
            }
            guard !generationOwners.contains(function.name), let write = function.body.range(of: "jiraSync = ") else { continue }
            if let check = function.body.range(of: "guard generation == jiraGeneration"), check.lowerBound < write.lowerBound { continue }
            problems.append("\(function.name): writes jiraSync without guard generation == jiraGeneration before it")
        }
        return problems
    }

    /// A Connect counts itself in flight before its first await and uncounts on every return; it
    /// re-checks cancellation and the generation in one guard right before the save; and Remove
    /// Token refuses while the count is above zero.
    static func connectProblems(in source: String) -> [String] {
        var problems: [String] = []
        if let retry = functionBody("retryRemovingJiraToken", in: source) {
            if !retry.contains("jiraConnectsInFlight == 0") {
                problems.append("retryRemovingJiraToken: does not refuse while a Connect is in flight")
            }
        } else {
            problems.append("retryRemovingJiraToken: not found")
        }
        guard let connect = functionBody("connectJira", in: source) else { return problems + ["connectJira: not found"] }
        if let count = connect.range(of: "jiraConnectsInFlight += 1") {
            if let firstAwait = connect.range(of: "await "), firstAwait.lowerBound < count.lowerBound {
                problems.append("connectJira: counts itself in flight only after its first await")
            }
        } else {
            problems.append("connectJira: does not count itself in flight")
        }
        if !connect.contains("defer { jiraConnectsInFlight -= 1 }") {
            problems.append("connectJira: never uncounts itself")
        }
        if let save = connect.range(of: "JiraCredentialStore.save(") {
            let lines = connect[..<save.lowerBound].components(separatedBy: "\n")
            let check = lines.last { $0.contains("guard ") && $0.contains("Task.isCancelled") }
            if check?.contains("generation == jiraGeneration") != true {
                problems.append("connectJira: saves without re-checking cancellation and the generation together")
            }
        } else {
            problems.append("connectJira: never saves the credential")
        }
        return problems
    }

    // MARK: - Scanning

    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// From the opening delimiter at `start` through its matching close.
    private static func balanced(from start: String.Index, in text: String, open: Character, close: Character) -> String {
        var depth = 0
        var index = start
        repeat {
            if text[index] == open { depth += 1 } else if text[index] == close { depth -= 1 }
            index = text.index(after: index)
        } while index < text.endIndex && depth > 0
        return String(text[start..<index])
    }

    private static func functionBody(_ name: String, in source: String) -> String? {
        guard let declaration = source.range(of: "func \(name)("),
              let open = source[declaration.upperBound...].firstIndex(of: "{") else { return nil }
        return balanced(from: open, in: source, open: "{", close: "}")
    }

    /// Every `func name(` in `source`, with its balanced body.
    private static func allFunctions(in source: String) -> [(name: String, body: String)] {
        guard let regex = try? NSRegularExpression(pattern: #"\bfunc\s+(\w+)\s*\("#) else { return [] }
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
            guard let range = Range(match.range, in: source), let nameRange = Range(match.range(at: 1), in: source),
                  let open = source[range.upperBound...].firstIndex(of: "{") else { return nil }
            return (String(source[nameRange]), balanced(from: open, in: source, open: "{", close: "}"))
        }
    }
}
