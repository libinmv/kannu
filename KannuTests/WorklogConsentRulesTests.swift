//
//  WorklogConsentRulesTests.swift
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

/// Kannu always asks before it logs time. That is a property of where code is, so it is read from
/// the source (the `IntegrationSecretRulesTests` idiom): `TasksManager` and the Settings views are
/// not in the logic target.
///
/// - The two write requests — `JiraAPI.addWorklogRequest` and `GitLabAPI.addSpentTimeRequest` — are
///   built only inside `TasksManager.confirmWorklog`, and only it hands a request to `WorklogPoster`.
/// - `confirmWorklog` is called only from `Kannu/components/`: a view, on the user's click. No
///   manager, sync, timer or launch path can call it.
/// - Inside it, the draft is marked `.sending` and saved — and the save awaited — before either
///   request is built (write-ahead), and a relaunch turns `.sending` into uncertain.
/// - After the last wait before each request, `canStillSend` looks again, so a Disconnect during
///   the save or the Keychain dialog sends nothing.
/// - A view that sends has no `.onSubmit`: Return in the length field never logs time.
///
/// Each detector has a planted-offender test, so a scanner that stops matching fails instead of
/// passing vacuously.
final class WorklogConsentRulesTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root
    static let managerPath = "Kannu/managers/Tasks/TasksManager.swift"
    static let gate = "confirmWorklog"
    static let builders = ["addWorklogRequest(", "addSpentTimeRequest("]
    static let senders = ["postJiraWorklog(", "postGitLabSpend("]

    /// Every Swift file under `Kannu/`, by repo-relative path, comments dropped.
    private static func sources() throws -> [String: String] {
        let root = repoRoot.appendingPathComponent("Kannu")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
        var sources: [String: String] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(repoRoot.path.count + 1))
            sources[relative] = code(try String(contentsOf: url, encoding: .utf8))
        }
        return sources
    }

    // MARK: - The rules, on the real sources

    func testOnlyConfirmWorklogBuildsAWriteRequest() throws {
        let sources = try Self.sources()
        XCTAssertNotNil(sources[Self.managerPath], "the scan would be vacuous")
        XCTAssertGreaterThan(sources.count, 100, "the walk found too few files to mean anything")
        XCTAssertEqual(Self.callsOutsideTheGate(of: Self.builders, in: sources), [])
        let gate = try XCTUnwrap(Self.functionBody(Self.gate, in: sources[Self.managerPath] ?? ""))
        for builder in Self.builders {
            XCTAssertTrue(gate.contains(builder), "confirmWorklog no longer builds \(builder)…): the scan is vacuous")
        }
    }

    func testOnlyConfirmWorklogSendsOne() throws {
        let sources = try Self.sources()
        XCTAssertEqual(Self.callsOutsideTheGate(of: Self.senders, in: sources), [])
        let gate = try XCTUnwrap(Self.functionBody(Self.gate, in: sources[Self.managerPath] ?? ""))
        for sender in Self.senders {
            XCTAssertTrue(gate.contains(sender), "confirmWorklog no longer calls \(sender)…): the scan is vacuous")
        }
    }

    func testConfirmWorklogIsCalledOnlyFromAView() throws {
        let sources = try Self.sources()
        XCTAssertEqual(Self.gateCallsOutsideViews(in: sources), [])
        let callers = sources.filter { !Self.calls(of: "\(Self.gate)(", in: $0.value).isEmpty }.map(\.key)
        XCTAssertFalse(callers.isEmpty, "nothing calls confirmWorklog: the scan is vacuous")
        XCTAssertTrue(callers.allSatisfy { $0.hasPrefix("Kannu/components/") }, "\(callers)")
    }

    func testTheDraftIsSavedAsSendingBeforeARequestIsBuilt() throws {
        let manager = try XCTUnwrap(try Self.sources()[Self.managerPath])
        XCTAssertEqual(Self.writeAheadProblems(in: manager), [])
    }

    func testReturnNeverSends() throws {
        let sources = try Self.sources()
        XCTAssertEqual(Self.submitProblems(in: sources), [])
        let senders = sources.filter { $0.key.hasPrefix("Kannu/components/") && !Self.calls(of: "\(Self.gate)(", in: $0.value).isEmpty }
        XCTAssertFalse(senders.isEmpty, "no view calls confirmWorklog: the scan is vacuous")
    }

    func testEveryRequestIsBuiltAfterALastLook() throws {
        let manager = try XCTUnwrap(try Self.sources()[Self.managerPath])
        XCTAssertEqual(Self.lastLookProblems(in: manager), [])
    }

    func testARelaunchTreatsASendInFlightAsUncertain() throws {
        let manager = try XCTUnwrap(try Self.sources()[Self.managerPath])
        let apply = try XCTUnwrap(Self.functionBody("apply", in: manager), "the load path is gone")
        XCTAssertTrue(apply.contains("WorklogDrafts.normalizedAtLoad("), "a draft saved as .sending must load as uncertain")
    }

    // MARK: - The scanners catch planted offenders

    func testTheBuilderScannerCatchesPlantedOffenders() {
        let planted = [
            Self.managerPath: Self.code("""
                func confirmWorklog(_ draftID: UUID, seconds: Int, comment: String?) {
                    Task {
                        guard await self.saveNow() else { return }
                        let request = JiraAPI.addWorklogRequest(credential, issueID: id)
                        _ = await poster.postJiraWorklog(request, lookup: lookup)
                    }
                }
                private func syncJira() {
                    let sneaky = GitLabAPI.addSpentTimeRequest(credential, kind: .issue, projectID: 1, iid: 2, seconds: 60)
                }
                """),
            "Kannu/managers/Tasks/JiraAPI.swift": Self.code("""
                static func addWorklogRequest(_ credential: JiraCredential) -> URLRequest? { nil }
                // addWorklogRequest(credential) in a comment is fine
                """),
            "Kannu/managers/Tasks/Elsewhere.swift": Self.code("""
                func autoLog() { _ = JiraAPI.addWorklogRequest(credential, issueID: "1") }
                func autoSend() async { _ = await WorklogPoster().postGitLabSpend(request) }
                """),
        ]
        let builders = Self.callsOutsideTheGate(of: Self.builders, in: planted)
        XCTAssertEqual(builders.count, 2, "\(builders)")
        XCTAssertTrue(builders.contains { $0.hasPrefix("Kannu/managers/Tasks/TasksManager.swift: addSpentTimeRequest(") }, "\(builders)")
        XCTAssertTrue(builders.contains { $0.hasPrefix("Kannu/managers/Tasks/Elsewhere.swift: addWorklogRequest(") }, "\(builders)")
        let senders = Self.callsOutsideTheGate(of: Self.senders, in: planted)
        XCTAssertEqual(senders, ["Kannu/managers/Tasks/Elsewhere.swift: postGitLabSpend("])
    }

    func testTheCallerScannerCatchesPlantedOffenders() {
        let planted = [
            Self.managerPath: Self.code("""
                func confirmWorklog(_ draftID: UUID, seconds: Int, comment: String?) {}
                func retryAll() { for draft in drafts { confirmWorklog(draft.id, seconds: draft.seconds, comment: nil) } }
                """),
            "Kannu/components/Settings/TimeToLogSection.swift": Self.code("""
                Button("Log to Jira") { manager.confirmWorklog(draft.id, seconds: seconds, comment: comment) }
                """),
            "Kannu/KannuApp.swift": Self.code("""
                // TasksManager.shared.confirmWorklog(id, seconds: 60, comment: nil) in a comment is fine
                TasksManager.shared.confirmWorklog(id, seconds: 60, comment: nil)
                """),
        ]
        XCTAssertEqual(Self.gateCallsOutsideViews(in: planted).sorted(), [
            "Kannu/KannuApp.swift: confirmWorklog(",
            "Kannu/managers/Tasks/TasksManager.swift: confirmWorklog(",
        ])
    }

    func testTheWriteAheadScannerCatchesPlantedOffenders() {
        XCTAssertEqual(Self.writeAheadProblems(in: """
            func confirmWorklog(_ draftID: UUID, seconds: Int, comment: String?) {
                drafts[index].state = sending
                Task {
                    guard await self.saveNow() else { return }
                    let a = JiraAPI.addWorklogRequest(credential)
                    let b = GitLabAPI.addSpentTimeRequest(credential)
                }
            }
            """), [])
        XCTAssertFalse(Self.writeAheadProblems(in: """
            func confirmWorklog(_ draftID: UUID, seconds: Int, comment: String?) {
                drafts[index].state = sending
                Task {
                    let a = JiraAPI.addWorklogRequest(credential)
                    guard await self.saveNow() else { return }
                    let b = GitLabAPI.addSpentTimeRequest(credential)
                }
            }
            """).isEmpty, "a request built before the save")
        XCTAssertFalse(Self.writeAheadProblems(in: """
            func confirmWorklog(_ draftID: UUID, seconds: Int, comment: String?) {
                Task {
                    guard await self.saveNow() else { return }
                    drafts[index].state = sending
                    let a = JiraAPI.addWorklogRequest(credential)
                    let b = GitLabAPI.addSpentTimeRequest(credential)
                }
            }
            """).isEmpty, "saved before it says .sending")
        XCTAssertFalse(Self.writeAheadProblems(in: """
            func confirmWorklog(_ draftID: UUID, seconds: Int, comment: String?) {
                drafts[index].state = sending
                Task {
                    self.persist()
                    let a = JiraAPI.addWorklogRequest(credential)
                    let b = GitLabAPI.addSpentTimeRequest(credential)
                }
            }
            """).isEmpty, "a save that is not awaited is not a write-ahead")
        XCTAssertFalse(Self.writeAheadProblems(in: "func somethingElse() {}").isEmpty, "a missing function is a problem")
    }

    func testTheReturnScannerCatchesPlantedOffenders() {
        let planted = [
            "Kannu/components/Settings/TimeToLogSection.swift": Self.code("""
                TextField("Length", text: $durationText).onSubmit(log)
                private func log() { manager.confirmWorklog(draft.id, seconds: seconds, comment: nil) }
                """),
            "Kannu/components/Settings/TasksSettings.swift": Self.code("""
                TextField("Title", text: $title).onSubmit(save)
                """),
            "Kannu/components/Settings/Quiet.swift": Self.code("""
                // .onSubmit(log) in a comment is fine
                Button("Log") { manager.confirmWorklog(draft.id, seconds: 60, comment: nil) }
                """),
        ]
        XCTAssertEqual(Self.submitProblems(in: planted), ["Kannu/components/Settings/TimeToLogSection.swift: .onSubmit"])
    }

    func testTheLastLookScannerCatchesPlantedOffenders() {
        XCTAssertEqual(Self.lastLookProblems(in: """
            func confirmWorklog(_ draftID: UUID, seconds: Int, comment: String?) {
                Task {
                    guard await self.saveNow() else { return }
                    switch await JiraCredentialStore.load(allowInteraction: true) { default: break }
                    guard self.canStillSend(draftID) else { return }
                    let a = JiraAPI.addWorklogRequest(credential)
                    switch await GitLabCredentialStore.load(allowInteraction: true) { default: break }
                    guard self.canStillSend(draftID) else { return }
                    let b = GitLabAPI.addSpentTimeRequest(credential)
                }
            }
            """), [])
        XCTAssertEqual(Self.lastLookProblems(in: """
            func confirmWorklog(_ draftID: UUID, seconds: Int, comment: String?) {
                Task {
                    guard await self.saveNow() else { return }
                    guard self.canStillSend(draftID) else { return }
                    switch await JiraCredentialStore.load(allowInteraction: true) { default: break }
                    let a = JiraAPI.addWorklogRequest(credential)
                    switch await GitLabCredentialStore.load(allowInteraction: true) { default: break }
                    let b = GitLabAPI.addSpentTimeRequest(credential)
                }
            }
            """), [
                "confirmWorklog: addWorklogRequest( is built without looking again after the last wait",
                "confirmWorklog: addSpentTimeRequest( is built without looking again after the last wait",
            ], "a look before the Keychain wait is not a last look")
        XCTAssertFalse(Self.lastLookProblems(in: "func somethingElse() {}").isEmpty, "a missing function is a problem")
    }

    // MARK: - Rules

    /// Views that call `confirmWorklog(` and also send on Return (`.onSubmit`), as "path: .onSubmit".
    /// Return in a field confirms what was typed; only a click on Log sends.
    static func submitProblems(in sources: [String: String]) -> [String] {
        sources.compactMap { path, source -> String? in
            guard path.hasPrefix("Kannu/components/"), !calls(of: "\(gate)(", in: source).isEmpty,
                  source.contains(".onSubmit") else { return nil }
            return "\(path): .onSubmit"
        }.sorted()
    }

    /// Inside `confirmWorklog`: between the last `await` before each request builder and the builder,
    /// `canStillSend(` looks again — a Disconnect during the save or the Keychain dialog sends nothing.
    static func lastLookProblems(in source: String) -> [String] {
        guard let body = functionBody(gate, in: source) else { return ["\(gate): not found"] }
        var problems: [String] = []
        for builder in builders {
            guard let built = body.range(of: builder)?.lowerBound else {
                problems.append("\(gate): never builds \(builder)")
                continue
            }
            let lastWait = body.range(of: "await ", options: .backwards, range: body.startIndex..<built)?.upperBound ?? body.startIndex
            if body.range(of: "canStillSend(", range: lastWait..<built) == nil {
                problems.append("\(gate): \(builder) is built without looking again after the last wait")
            }
        }
        return problems
    }

    /// Calls of `names` (not their declarations) anywhere but inside `confirmWorklog` in
    /// `TasksManager.swift`, as "path: name".
    static func callsOutsideTheGate(of names: [String], in sources: [String: String]) -> [String] {
        var found: [String] = []
        for (path, source) in sources {
            let gateRange = path == managerPath ? functionBodyRange(gate, in: source) : nil
            for name in names {
                for call in calls(of: name, in: source) where !(gateRange?.contains(call) ?? false) {
                    found.append("\(path): \(name)")
                }
            }
        }
        return found.sorted()
    }

    /// Calls of `confirmWorklog(` from anywhere but `Kannu/components/`, as "path: confirmWorklog(".
    static func gateCallsOutsideViews(in sources: [String: String]) -> [String] {
        sources.flatMap { path, source -> [String] in
            guard !path.hasPrefix("Kannu/components/") else { return [] }
            return calls(of: "\(gate)(", in: source).map { _ in "\(path): \(gate)(" }
        }
    }

    /// Inside `confirmWorklog`: `.sending` is set, then the list is saved and awaited, then each
    /// request is built.
    static func writeAheadProblems(in source: String) -> [String] {
        guard let body = functionBody(gate, in: source) else { return ["\(gate): not found"] }
        guard let save = body.range(of: "await self.saveNow()")?.lowerBound else {
            return ["\(gate): never awaits saveNow() before sending"]
        }
        var problems: [String] = []
        if let sending = body.range(of: "state = sending")?.lowerBound, sending < save {
            // In order.
        } else {
            problems.append("\(gate): the draft is not marked .sending before it is saved")
        }
        for builder in builders {
            guard let built = body.range(of: builder)?.lowerBound else {
                problems.append("\(gate): never builds \(builder)")
                continue
            }
            if built < save { problems.append("\(gate): \(builder) is built before the draft is saved") }
        }
        return problems
    }

    // MARK: - Scanning

    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Where each call of `opener` starts: every occurrence not part of a longer name and not its
    /// own declaration (`func name(`).
    private static func calls(of opener: String, in text: String) -> [String.Index] {
        var found: [String.Index] = []
        var searchStart = text.startIndex
        while let range = text.range(of: opener, range: searchStart..<text.endIndex) {
            searchStart = range.upperBound
            if range.lowerBound > text.startIndex {
                let before = text[text.index(before: range.lowerBound)]
                if before.isLetter || before.isNumber || before == "_" { continue }
            }
            let declaration = text[..<range.lowerBound].hasSuffix("func ")
            if !declaration { found.append(range.lowerBound) }
        }
        return found
    }

    /// The braces of `func name(…) { … }`, balanced, as a range of `source`.
    private static func functionBodyRange(_ name: String, in source: String) -> Range<String.Index>? {
        guard let declaration = source.range(of: "func \(name)("),
              let open = source[declaration.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        repeat {
            if source[index] == "{" { depth += 1 } else if source[index] == "}" { depth -= 1 }
            index = source.index(after: index)
        } while index < source.endIndex && depth > 0
        return open..<index
    }

    private static func functionBody(_ name: String, in source: String) -> String? {
        functionBodyRange(name, in: source).map { String(source[$0]) }
    }
}
