//
//  IntegrationSecretRulesTests.swift
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

/// How the Jira and GitLab tokens are handled, read from the source (the
/// `TimerSessionEventRulesTests` idiom): `TasksManager`, `JiraClient`, `GitLabClient` and the Tasks
/// page are not in the logic target.
///
/// - The Tasks page never touches the Keychain — not when it appears, not anywhere. A Keychain read
///   can raise the SecurityAgent dialog and block the thread that asked (docs/REGRESSIONS.md
///   entry 11); the page shows the Defaults display copies instead.
/// - No log line interpolates the token, the email, the filter, a title or a summary.
/// - Only `JiraAPI.swift` sets an `Authorization` header, and only `GitLabAPI.swift` a
///   `PRIVATE-TOKEN` one.
/// - The sync each source's row starts on appear reads the Keychain non-interactively, and asks
///   `SourceSyncState.allowsSyncOnAppear` first, so a refused token is never sent again from there.
/// - Removing a saved token is never fire-and-forget: Disconnect tells the user it is gone, so a
///   failed delete must be seen.
///
/// Each detector has a planted-offender test, so a scanner that stops matching fails instead of
/// passing vacuously.
final class IntegrationSecretRulesTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root
    /// Brain › Tasks: the overview and every page below it, and the Connect sheets.
    private static let settingsPaths = ["TasksSettings", "TaskSourcePages", "TaskConnectSheets", "TaskRowList",
                                        "AllTasksPage", "TaskDetailPage", "NewTaskSheet"].map { "Kannu/components/Settings/\($0).swift" }
    private static let tasksDirectory = "Kannu/managers/Tasks"

    static let keychainAPIs = ["SecureSecretsStore", "KeychainReader", "SecItem", "CredentialStore", "TaskCredentials", "SecretSlot"]
    /// The engine's syncs that run without the user asking: a page appearing, the source saying it
    /// changed (`SourceSync`). Every source runs through them.
    static let onAppearSyncs = ["syncIfStale", "externalChange"]
    private static let enginePath = "Kannu/managers/Tasks/SourceSync.swift"
    /// The files that build a request with an `Authorization` header: each source's own API file.
    static let authorizationHeaderOwners = ["GitHubAPI.swift", "JiraAPI.swift", "LinearAPI.swift", "TodoistAPI.swift"]
    static let secretWords = ["token", "email", "jql", "title", "summary", "credential", "displayname", "password", "authorization"]

    private static func read(_ path: String) throws -> String {
        code(try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8))
    }

    private static func sources() throws -> [String: String] {
        let folder = repoRoot.appendingPathComponent(tasksDirectory)
        var sources: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".swift") {
            sources[name] = try read("\(tasksDirectory)/\(name)")
        }
        for path in settingsPaths {
            sources[String(path.split(separator: "/").last ?? "")] = try read(path)
        }
        return sources
    }

    /// Every Brain › Tasks file, one after another.
    private static func tasksPages() throws -> String {
        try settingsPaths.map(read).joined(separator: "\n")
    }

    // MARK: - The rules, on the real sources

    func testTheTasksPageNeverTouchesTheKeychain() throws {
        let page = try Self.tasksPages()
        XCTAssertTrue(page.contains(".onAppear"), "the page no longer syncs on appear: the lifecycle scan is vacuous")
        XCTAssertEqual(Self.keychainUses(in: Self.lifecycleBlocks(in: page).joined(separator: "\n")), [])
        XCTAssertEqual(Self.keychainUses(in: page), [])
    }

    func testTimeToLogNeverTouchesTheKeychain() throws {
        // Log reads the token in TasksManager.confirmWorklog, off the main actor; the cards never do.
        let section = try Self.read("Kannu/components/Settings/TimeToLogSection.swift")
        XCTAssertTrue(section.contains("confirmWorklog("), "the section no longer logs anything: the scan is vacuous")
        XCTAssertEqual(Self.keychainUses(in: section), [])
    }

    func testNoLogLineInterpolatesASecret() throws {
        let sources = try Self.sources()
        XCTAssertNotNil(sources["JiraClient.swift"])
        XCTAssertNotNil(sources["GitLabClient.swift"])
        XCTAssertNotNil(sources["GitLabAPI.swift"])
        XCTAssertNotNil(sources["TasksManager.swift"])
        let calls = sources.values.flatMap(Self.logCalls(in:))
        XCTAssertGreaterThan(calls.count, 5, "the log scan found too few calls to mean anything")
        var problems: [String] = []
        for (name, source) in sources {
            problems += Self.loggedSecrets(in: source).map { "\(name): \($0)" }
        }
        XCTAssertEqual(problems, [])
    }

    func testOnlyEachSourcesAPIFileSetsTheAuthorizationHeader() throws {
        let setters = try Self.sources().filter { $0.value.contains("\"Authorization\"") }.map(\.key).sorted()
        XCTAssertEqual(setters, Self.authorizationHeaderOwners, "each source's API file sets its own header, and no other file does")
    }

    func testOnlyGitLabAPISetsThePrivateTokenHeader() throws {
        let setters = try Self.sources().filter { $0.value.contains("\"PRIVATE-TOKEN\"") || $0.value.contains("tokenHeader") }.map(\.key)
        XCTAssertEqual(setters, ["GitLabAPI.swift"])
    }

    /// The engine's class, without the protocol that declares the same names first.
    private static func engine() throws -> String {
        let source = try read(enginePath)
        guard let start = source.range(of: "final class SourceSync<") else { return "" }
        return String(source[start.lowerBound...])
    }

    func testTheSyncOnAppearNeverAsksForKeychainAccess() throws {
        let engine = try Self.engine()
        for function in Self.onAppearSyncs {
            XCTAssertEqual(Self.interactiveProblems(in: engine, function: function), [], function)
        }
    }

    func testTheSyncOnAppearNeverRetriesARefusedToken() throws {
        let engine = try Self.engine()
        for function in Self.onAppearSyncs {
            XCTAssertEqual(Self.retryProblems(in: engine, function: function), [], function)
        }
    }

    func testEachSourceRowSyncsOnAppear() throws {
        let page = try Self.read(Self.settingsPaths[0])
        let lifecycle = Self.lifecycleBlocks(in: page).joined(separator: "\n")
        XCTAssertTrue(lifecycle.contains("manager.syncIfStale("), "no source row syncs from a lifecycle block")
    }

    /// macOS's Reminders question is asked once, from the user's Connect, and never from a sync, a
    /// page appearing or launch: only `AppleRemindersStore.requestAccess` asks, and only
    /// `connectAppleReminders` calls it.
    func testRemindersAccessIsAskedOnlyFromConnect() throws {
        let sources = try Self.sources()
        let asking = sources.filter { $0.value.contains("requestFullAccessToReminders") }.map(\.key)
        XCTAssertEqual(asking, ["AppleRemindersSource.swift"])
        let callers = sources.filter { $0.value.contains(".requestAccess()") }.map(\.key)
        XCTAssertEqual(callers, ["TasksManager.swift"])
        let manager = try XCTUnwrap(sources["TasksManager.swift"])
        let connect = try XCTUnwrap(Self.functionBody("connectAppleReminders", in: manager), "connectAppleReminders is gone")
        XCTAssertTrue(connect.contains("AppleRemindersStore.shared.requestAccess()"))
        XCTAssertEqual(manager.components(separatedBy: ".requestAccess()").count - 1, 1, "asked from more than Connect")
        let keeper = try XCTUnwrap(sources["AppleRemindersSource.swift"])
        XCTAssertTrue(keeper.contains("AppleRemindersStore.shared.hasAccess ? .found(AppleRemindersAccess()) : .missing"),
                      "a sync's credential read must only look at macOS's answer, never ask")
    }

    /// The per-source sync state lives in `SourceSync`, one engine for every source: none of it may
    /// grow back in the manager, where Jira's and GitLab's copies once drifted apart.
    func testTheManagerKeepsNoSyncStateOfItsOwn() throws {
        let manager = try Self.read("\(Self.tasksDirectory)/TasksManager.swift")
        for name in ["Generation", "SyncInFlight", "SyncWhenReady", "pendingJiraRefresh", "ConnectsInFlight", "lastJiraSync", "lastGitLabSync"] {
            XCTAssertFalse(manager.contains(name), "TasksManager keeps \(name) again")
        }
        XCTAssertTrue(manager.contains("lazy var jira = SourceSync("), "Jira no longer runs on the engine")
        XCTAssertTrue(manager.contains("lazy var gitlab = SourceSync("), "GitLab no longer runs on the engine")
    }

    func testTheTokenRemovalResultIsAlwaysUsed() throws {
        let sources = try Self.sources()
        let lines = sources.values.flatMap { $0.components(separatedBy: "\n") }
        for call in Self.removeCalls {
            XCTAssertTrue(lines.contains { $0.contains(call) }, "no \(call)…) call: the scan is vacuous")
        }
        var problems: [String] = []
        for (name, source) in sources {
            problems += Self.discardedRemovals(in: source).map { "\(name): \($0)" }
        }
        XCTAssertEqual(problems, [])
    }

    // MARK: - The scanners catch planted offenders

    func testTheKeychainScannerCatchesPlantedOffenders() {
        let planted = Self.code("""
            .onAppear {
                manager.syncJiraIfStale()
                let saved = SecureSecretsStore.value(for: .jiraCredential)
            }
            .task { _ = KeychainReader.read(service: "x") }
            // JiraCredentialStore in a comment is fine
            Button("x") { SecItemCopyMatching(query, &item) }
            let count = manager.tasks.count
            """)
        let lifecycle = Self.lifecycleBlocks(in: planted).joined(separator: "\n")
        XCTAssertEqual(Self.keychainUses(in: lifecycle), ["KeychainReader", "SecureSecretsStore"])
        XCTAssertEqual(Self.keychainUses(in: planted), ["KeychainReader", "SecItem", "SecureSecretsStore"])
        XCTAssertEqual(Self.keychainUses(in: ".onAppear { manager.syncIfStale(source) }"), [])
    }

    func testTheLogScannerCatchesPlantedOffenders() {
        let planted = Self.code("""
            logger.info("Synced \\(issues.count, privacy: .public) issues")
            logger.error("Connect failed for \\(email, privacy: .private)")
            Self.log.notice("Token \\(credential.token)")
            logger.debug("Filter: \\(Defaults[.jiraJQL])")
            logger.info("Row \\(task.title, privacy: .private) and \\(
                summary)")
            // logger.info("\\(token)") in a comment is fine
            let title = "\\(task.title)"
            """)
        let found = Self.loggedSecrets(in: planted)
        XCTAssertEqual(found.count, 5, "one for each secret interpolated: \(found)")
        XCTAssertTrue(found.contains { $0.contains("email") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("credential") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("jql") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("title") }, "even .private is refused: \(found)")
        XCTAssertEqual(Self.logCalls(in: planted).count, 5)
    }

    func testTheInteractiveScannerCatchesPlantedOffenders() {
        XCTAssertEqual(Self.interactiveProblems(in: """
            func syncIfStale(now: Date = Date()) {
                guard isSyncOn else { return }
                sync(interactive: false, using: nil)
            }
            """), [])
        XCTAssertFalse(Self.interactiveProblems(in: """
            func syncIfStale(now: Date = Date()) {
                sync(interactive: true, using: nil)
            }
            """).isEmpty)
        XCTAssertFalse(Self.interactiveProblems(in: """
            func syncIfStale() {
                Task { _ = await store.load(allowInteraction: true) }
            }
            """).isEmpty)
        XCTAssertFalse(Self.interactiveProblems(in: "func somethingElse() {}").isEmpty, "a missing function is a problem")
    }

    func testTheRetryScannerCatchesPlantedOffenders() {
        XCTAssertEqual(Self.retryProblems(in: """
            func syncIfStale(now: Date = Date()) {
                guard state.allowsSyncOnAppear(lastSuccess: lastSuccess, now: now, staleAfter: 300) else { return }
                sync(interactive: false, using: nil)
            }
            """), [])
        XCTAssertFalse(Self.retryProblems(in: """
            func syncIfStale(now: Date = Date()) {
                if let lastSuccess, now.timeIntervalSince(lastSuccess) < 300 { return }
                sync(interactive: false, using: nil)
            }
            """).isEmpty, "the original shape: only the last success is checked")
        XCTAssertFalse(Self.retryProblems(in: "func somethingElse() {}").isEmpty, "a missing function is a problem")
    }

    func testTheRemovalScannerCatchesPlantedOffenders() {
        let planted = Self.code("""
            Task { await store.remove() }
            _ = await store.remove()
            await store.remove()
            let removed = await store.remove()
            guard await store.remove() else { return }
            if await store.remove() { done() }
            // Task { await store.remove() } in a comment is fine
            Task { await self.store.remove() }
            let gone = await self.store.remove()
            """)
        XCTAssertEqual(Self.discardedRemovals(in: planted).count, 4, "\(Self.discardedRemovals(in: planted))")
    }

    func testTheGitLabScannersCatchPlantedOffenders() {
        XCTAssertEqual(Self.interactiveProblems(in: """
            func syncGitLabIfStale(now: Date = Date()) {
                guard gitlabSync.allowsSyncOnAppear(lastSuccess: nil, now: now, staleAfter: 300) else { return }
                syncGitLab(interactive: false, using: nil)
            }
            """, function: "syncGitLabIfStale"), [])
        XCTAssertFalse(Self.interactiveProblems(in: """
            func syncGitLabIfStale(now: Date = Date()) {
                syncGitLab(interactive: true, using: nil)
            }
            """, function: "syncGitLabIfStale").isEmpty)
        XCTAssertFalse(Self.retryProblems(in: """
            func syncGitLabIfStale(now: Date = Date()) {
                syncGitLab(interactive: false, using: nil)
            }
            """, function: "syncGitLabIfStale").isEmpty, "a sync on appear that never asks allowsSyncOnAppear")
        XCTAssertFalse(Self.interactiveProblems(in: "func syncJiraIfStale() { syncJira(interactive: false, using: nil) }",
                                                function: "syncGitLabIfStale").isEmpty, "a missing function is a problem")
        XCTAssertEqual(Self.keychainUses(in: ".onAppear { _ = await TaskCredentials.gitlab.load(allowInteraction: false) }"),
                       ["TaskCredentials"])
    }

    // MARK: - Rules

    /// Keychain API names used in `source`, sorted and unique.
    static func keychainUses(in source: String) -> [String] {
        keychainAPIs.filter { source.contains($0) }.sorted()
    }

    /// The bodies of `.onAppear { }`, `.task { }` and `.onChange(…) { }` blocks.
    static func lifecycleBlocks(in source: String) -> [String] {
        var blocks: [String] = []
        for opener in [".onAppear", ".task", ".onChange("] {
            var searchStart = source.startIndex
            while let range = source.range(of: opener, range: searchStart..<source.endIndex) {
                searchStart = range.upperBound
                // `.task` must not match `.tasks` or `.taskID`.
                if !opener.hasSuffix("("), range.upperBound < source.endIndex, source[range.upperBound].isLetter { continue }
                guard let brace = source[range.upperBound...].firstIndex(of: "{") else { break }
                blocks.append(balanced(from: brace, in: source, open: "{", close: "}"))
            }
        }
        return blocks
    }

    /// Each log call: `logger.` / `log.` followed by a level and its balanced arguments.
    static func logCalls(in source: String) -> [String] {
        let pattern = #"\b(?:logger|log|Logger\([^)]*\))\.(?:info|error|debug|notice|warning|fault|trace|critical|log)\("#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
            guard let range = Range(match.range, in: source) else { return nil }
            let open = source.index(before: range.upperBound)
            return balanced(from: open, in: source, open: "(", close: ")")
        }
    }

    /// Log calls that interpolate a secret word, whatever their privacy.
    static func loggedSecrets(in source: String) -> [String] {
        var found: [String] = []
        for call in logCalls(in: source) {
            var searchStart = call.startIndex
            while let range = call.range(of: "\\(", range: searchStart..<call.endIndex) {
                let open = call.index(before: range.upperBound)
                let interpolation = balanced(from: open, in: call, open: "(", close: ")").lowercased()
                searchStart = range.upperBound
                if let word = secretWords.first(where: { interpolation.contains($0) }) {
                    found.append("\(word) in \(call.prefix(80))")
                }
            }
        }
        return found
    }

    static func interactiveProblems(in source: String, function: String = "syncIfStale") -> [String] {
        guard let body = functionBody(function, in: source) else {
            return ["\(function): not found"]
        }
        var problems: [String] = []
        if body.contains("interactive: true") || body.contains("allowInteraction: true") {
            problems.append("\(function): reads the Keychain interactively")
        }
        if !body.contains("interactive: false") {
            problems.append("\(function): does not say interactive: false")
        }
        return problems
    }

    static func retryProblems(in source: String, function: String = "syncIfStale") -> [String] {
        guard let body = functionBody(function, in: source) else {
            return ["\(function): not found"]
        }
        return body.contains(".allowsSyncOnAppear(") ? [] : ["\(function): does not ask SourceSyncState.allowsSyncOnAppear"]
    }

    static let removeCalls = ["store.remove("]

    /// Lines that remove a saved token (`SourceSync.removeToken`'s `store.remove()`) and do nothing
    /// with its answer.
    static func discardedRemovals(in source: String) -> [String] {
        source.components(separatedBy: "\n").filter { line in
            guard removeCalls.contains(where: { line.contains($0) }) else { return false }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("_ =") { return true }
            return !["let ", "var ", "guard ", "if ", "return ", "= await"].contains { trimmed.contains($0) }
        }
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
}
