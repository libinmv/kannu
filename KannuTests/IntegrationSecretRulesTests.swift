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

/// How the Jira token is handled, read from the source (the `TimerSessionEventRulesTests` idiom):
/// `TasksManager`, `JiraClient` and the Tasks page are not in the logic target.
///
/// - The Tasks page never touches the Keychain — not when it appears, not anywhere. A Keychain read
///   can raise the SecurityAgent dialog and block the thread that asked (docs/REGRESSIONS.md
///   entry 11); the page shows the Defaults display copies instead.
/// - No log line interpolates the token, the email, the filter, a title or a summary.
/// - Only `JiraAPI.swift` sets an `Authorization` header.
/// - The sync the page's appearance starts reads the Keychain non-interactively, and asks
///   `JiraSyncState.allowsSyncOnAppear` first, so a refused token is never sent again from there.
/// - Removing the saved token is never fire-and-forget: Disconnect tells the user it is gone, so a
///   failed delete must be seen.
///
/// Each detector has a planted-offender test, so a scanner that stops matching fails instead of
/// passing vacuously.
final class IntegrationSecretRulesTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root
    private static let settingsPath = "Kannu/components/Settings/TasksSettings.swift"
    private static let tasksDirectory = "Kannu/managers/Tasks"

    static let keychainAPIs = ["SecureSecretsStore", "KeychainReader", "SecItem", "JiraCredentialStore"]
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
        sources["TasksSettings.swift"] = try read(settingsPath)
        return sources
    }

    // MARK: - The rules, on the real sources

    func testTheTasksPageNeverTouchesTheKeychain() throws {
        let page = try Self.read(Self.settingsPath)
        XCTAssertTrue(page.contains(".onAppear"), "the page no longer syncs on appear: the lifecycle scan is vacuous")
        XCTAssertEqual(Self.keychainUses(in: Self.lifecycleBlocks(in: page).joined(separator: "\n")), [])
        XCTAssertEqual(Self.keychainUses(in: page), [])
    }

    func testNoLogLineInterpolatesASecret() throws {
        let sources = try Self.sources()
        XCTAssertNotNil(sources["JiraClient.swift"])
        XCTAssertNotNil(sources["TasksManager.swift"])
        let calls = sources.values.flatMap(Self.logCalls(in:))
        XCTAssertGreaterThan(calls.count, 5, "the log scan found too few calls to mean anything")
        var problems: [String] = []
        for (name, source) in sources {
            problems += Self.loggedSecrets(in: source).map { "\(name): \($0)" }
        }
        XCTAssertEqual(problems, [])
    }

    func testOnlyJiraAPISetsTheAuthorizationHeader() throws {
        let setters = try Self.sources().filter { $0.value.contains("\"Authorization\"") }.map(\.key)
        XCTAssertEqual(setters, ["JiraAPI.swift"])
    }

    func testTheSyncOnAppearNeverAsksForKeychainAccess() throws {
        let manager = try Self.read("\(Self.tasksDirectory)/TasksManager.swift")
        XCTAssertEqual(Self.interactiveProblems(in: manager), [])
    }

    func testTheSyncOnAppearNeverRetriesARefusedToken() throws {
        let manager = try Self.read("\(Self.tasksDirectory)/TasksManager.swift")
        XCTAssertEqual(Self.retryProblems(in: manager), [])
    }

    func testTheTokenRemovalResultIsAlwaysUsed() throws {
        let sources = try Self.sources()
        let calls = sources.values.flatMap { $0.components(separatedBy: "\n") }.filter { $0.contains(Self.removeCall) }
        XCTAssertFalse(calls.isEmpty, "no call removes the token: the scan is vacuous")
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
        XCTAssertEqual(Self.keychainUses(in: ".onAppear { manager.syncJiraIfStale() }"), [])
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
            func syncJiraIfStale(now: Date = Date()) {
                guard isJiraSyncOn else { return }
                syncJira(interactive: false, using: nil)
            }
            """), [])
        XCTAssertFalse(Self.interactiveProblems(in: """
            func syncJiraIfStale(now: Date = Date()) {
                syncJira(interactive: true, using: nil)
            }
            """).isEmpty)
        XCTAssertFalse(Self.interactiveProblems(in: """
            func syncJiraIfStale() {
                Task { _ = await JiraCredentialStore.load(allowInteraction: true) }
            }
            """).isEmpty)
        XCTAssertFalse(Self.interactiveProblems(in: "func somethingElse() {}").isEmpty, "a missing function is a problem")
    }

    func testTheRetryScannerCatchesPlantedOffenders() {
        XCTAssertEqual(Self.retryProblems(in: """
            func syncJiraIfStale(now: Date = Date()) {
                guard jiraSync.allowsSyncOnAppear(lastSuccess: lastJiraSync, now: now, staleAfter: 300) else { return }
                syncJira(interactive: false, using: nil)
            }
            """), [])
        XCTAssertFalse(Self.retryProblems(in: """
            func syncJiraIfStale(now: Date = Date()) {
                if let lastJiraSync, now.timeIntervalSince(lastJiraSync) < 300 { return }
                syncJira(interactive: false, using: nil)
            }
            """).isEmpty, "the original shape: only the last success is checked")
        XCTAssertFalse(Self.retryProblems(in: "func somethingElse() {}").isEmpty, "a missing function is a problem")
    }

    func testTheRemovalScannerCatchesPlantedOffenders() {
        let planted = Self.code("""
            Task { await JiraCredentialStore.remove() }
            _ = await JiraCredentialStore.remove()
            await JiraCredentialStore.remove()
            let removed = await JiraCredentialStore.remove()
            guard await JiraCredentialStore.remove() else { return }
            if await JiraCredentialStore.remove() { done() }
            // Task { await JiraCredentialStore.remove() } in a comment is fine
            """)
        XCTAssertEqual(Self.discardedRemovals(in: planted).count, 3, "\(Self.discardedRemovals(in: planted))")
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

    static func interactiveProblems(in source: String) -> [String] {
        guard let body = functionBody("syncJiraIfStale", in: source) else {
            return ["syncJiraIfStale: not found"]
        }
        var problems: [String] = []
        if body.contains("interactive: true") || body.contains("allowInteraction: true") {
            problems.append("syncJiraIfStale: reads the Keychain interactively")
        }
        if !body.contains("interactive: false") {
            problems.append("syncJiraIfStale: does not say interactive: false")
        }
        return problems
    }

    static func retryProblems(in source: String) -> [String] {
        guard let body = functionBody("syncJiraIfStale", in: source) else {
            return ["syncJiraIfStale: not found"]
        }
        return body.contains(".allowsSyncOnAppear(") ? [] : ["syncJiraIfStale: does not ask JiraSyncState.allowsSyncOnAppear"]
    }

    static let removeCall = "JiraCredentialStore.remove("

    /// Lines that call `JiraCredentialStore.remove()` and do nothing with its answer.
    static func discardedRemovals(in source: String) -> [String] {
        source.components(separatedBy: "\n").filter { line in
            guard line.contains(removeCall) else { return false }
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
