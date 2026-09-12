//
//  ClaudeDesktopSessionIndexTests.swift
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

/// Desktop's on-disk index of Code-tab chats, the resolver that maps a CLI session to Desktop's
/// own id, and the focus link. Lineage keys are fixture-only: no record on the machine
/// this was written on carried them (they come from Desktop's bundle).
final class ClaudeDesktopSessionIndexTests: XCTestCase {
    typealias Index = ClaudeDesktopSessionIndex
    typealias Record = ClaudeDesktopSessionIndex.Record

    private func json(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    private func record(_ id: String, cli: String?, prior: [String] = [], archived: Bool = false,
                        activity: TimeInterval = 0) -> Record {
        Record(sessionID: id, cliSessionID: cli, priorCLISessionIDs: prior, cwd: nil, title: nil,
               isArchived: archived, lastActivityAt: Date(timeIntervalSince1970: activity))
    }

    // MARK: - Records

    func testRecordParsesIDsLineageArchivedAndActivity() throws {
        let parsed = try XCTUnwrap(Index.record(from: json(#"{"sessionId":"local_6bf3936b-1","cliSessionId":"a493e20e-4ef1","priorCliSessionIds":["p1","p2"],"unarchivedCliSessionId":"u1","preClearCliSessionId":"c1","cwd":"/Users/me/proj","title":"Fix","isArchived":true,"lastActivityAt":1788975810519,"remoteMcpServersConfig":{"x":1}}"#)))
        XCTAssertEqual(parsed.sessionID, "local_6bf3936b-1")
        XCTAssertEqual(parsed.cliSessionID, "a493e20e-4ef1")
        XCTAssertEqual(parsed.priorCLISessionIDs, ["p1", "p2", "u1", "c1"])
        XCTAssertEqual(parsed.cwd, "/Users/me/proj")
        XCTAssertEqual(parsed.title, "Fix")
        XCTAssertTrue(parsed.isArchived)
        XCTAssertEqual(parsed.lastActivityAt?.timeIntervalSince1970 ?? 0, 1788975810.519, accuracy: 0.001)
    }

    func testRecordWithoutOptionalKeysHasDefaults() {
        let parsed = Index.record(from: json(#"{"sessionId":"local_abc","cliSessionId":"abc"}"#))
        XCTAssertEqual(parsed?.priorCLISessionIDs, [])
        XCTAssertEqual(parsed?.isArchived, false)
        XCTAssertNil(parsed?.lastActivityAt)
    }

    func testRecordRejectsMissingOrForeignSessionID() {
        XCTAssertNil(Index.record(from: json(#"{"cliSessionId":"abc"}"#)))
        XCTAssertNil(Index.record(from: json(#"{"sessionId":"session_01ABC"}"#)), "a bridge id is not a Desktop id")
        XCTAssertNil(Index.record(from: json(#"{"sessionId":"local_"}"#)))
    }

    // MARK: - Resolver

    func testDirectMatchBeatsLineage() {
        let records = [record("local_new", cli: "cli-1"),
                       record("local_old", cli: "other", prior: ["cli-1"], activity: 999)]
        XCTAssertEqual(Index.desktopSessionID(forCLISession: "cli-1", in: records), "local_new")
        XCTAssertEqual(Index.desktopSessionID(forCLISession: "CLI-1", in: records), "local_new", "ids compare case-insensitively")
    }

    func testNonArchivedBeatsArchivedAndNewestActivityBreaksTies() {
        let records = [
            record("local_archived", cli: "cli-1", archived: true, activity: 500),
            record("local_stale", cli: "cli-1", activity: 100),
            record("local_fresh", cli: "cli-1", activity: 300)
        ]
        XCTAssertEqual(Index.desktopSessionID(forCLISession: "cli-1", in: records), "local_fresh")
    }

    func testArchivedOnlyMatchStillResolvesAndUnknownDoesNot() {
        let records = [record("local_archived", cli: "cli-1", archived: true)]
        XCTAssertEqual(Index.desktopSessionID(forCLISession: "cli-1", in: records), "local_archived",
                       "continue on an archived chat is a safe no-op; an importing resume is not")
        XCTAssertNil(Index.desktopSessionID(forCLISession: "cli-9", in: records))
    }

    func testIDMapAgreesWithTheResolverForEveryMentionedID() {
        let records = [record("local_a", cli: "cli-a", prior: ["cli-old"]), record("local_b", cli: "cli-b")]
        XCTAssertEqual(Index.desktopSessionIDsByCLISessionID(records),
                       ["cli-a": "local_a", "cli-old": "local_a", "cli-b": "local_b"])
    }

    // MARK: - Classifier and attach rule

    func testAttachRuleLiveRequiresDesktopEntrypointDeadDoesNot() {
        let map = ["cli-1": "local_x"]
        let desktop = json(#"{"pid":1,"entrypoint":"claude-desktop"}"#)
        let terminal = json(#"{"pid":1,"entrypoint":"cli"}"#)
        let unknown = json(#"{"pid":1}"#)
        XCTAssertTrue(Index.isDesktopHosted(sessionFile: desktop))
        XCTAssertFalse(Index.isDesktopHosted(sessionFile: terminal))
        XCTAssertEqual(Index.resolvedDesktopSessionID(cliSessionID: "cli-1", processAlive: true, sessionFile: desktop, idMap: map), "local_x")
        XCTAssertNil(Index.resolvedDesktopSessionID(cliSessionID: "cli-1", processAlive: true, sessionFile: terminal, idMap: map),
                     "a live terminal session once imported into Desktop keeps opening its terminal")
        XCTAssertNil(Index.resolvedDesktopSessionID(cliSessionID: "cli-1", processAlive: true, sessionFile: unknown, idMap: map))
        XCTAssertEqual(Index.resolvedDesktopSessionID(cliSessionID: "CLI-1", processAlive: false, sessionFile: terminal, idMap: map), "local_x",
                       "once the process is gone, Desktop's copy is the only place the chat lives")
        XCTAssertNil(Index.resolvedDesktopSessionID(cliSessionID: "cli-2", processAlive: false, sessionFile: desktop, idMap: map))
    }

    // MARK: - Link

    func testFocusLinkIsDesktopsSessionRoute() {
        // Verified on Desktop 1.46388.4: this exact shape logs `setFocusedSession` for the id and
        // spawns nothing; `claude://code/continue?session=` is feature-gated off there.
        XCTAssertEqual(Index.focusDeepLink(desktopSessionID: "local_6bf3936b-1ace-4b0b-9c1e-0123456789ab")?.absoluteString,
                       "claude://claude.ai/epitaxy/local_6bf3936b-1ace-4b0b-9c1e-0123456789ab")
    }

    func testFocusLinkRejectsWhatDesktopWouldMisreadOrCreate() {
        for bad in ["last", "6bf3936b-1ace-4b0b-9c1e-0123456789ab", "local_", "local_../x", "local_a b", "",
                    "local_" + String(repeating: "a", count: 65), "session_01ABC", "local_é"] {
            XCTAssertNil(Index.focusDeepLink(desktopSessionID: bad), bad)
        }
        XCTAssertTrue(Index.isValidDesktopSessionID("local_" + String(repeating: "a", count: 64)))
    }

    // MARK: - Files and loader

    func testRecordFilesEnumerateTwoLevelsAndSkipTombstonesAndDirectories() throws {
        let root = try makeRoot()
        let org = root.appendingPathComponent("acct/org", isDirectory: true)
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        try write(org.appendingPathComponent("local_a.json"), #"{"sessionId":"local_a","cliSessionId":"cli-a"}"#)
        try write(org.appendingPathComponent("scheduled-tasks.json"), "{}")
        try FileManager.default.createDirectory(at: org.appendingPathComponent("deleted_b", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: org.appendingPathComponent("local_c", isDirectory: true), withIntermediateDirectories: true)
        try write(root.appendingPathComponent("local_stray.json"), #"{"sessionId":"local_stray"}"#)
        XCTAssertEqual(Index.recordFiles(root: root).map(\.lastPathComponent), ["local_a.json"])
    }

    func testLoaderReparsesOnlyChangedFiles() throws {
        let root = try makeRoot()
        let org = root.appendingPathComponent("acct/org", isDirectory: true)
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        let a = org.appendingPathComponent("local_a.json")
        let b = org.appendingPathComponent("local_b.json")
        try write(a, #"{"sessionId":"local_a","cliSessionId":"cli-a"}"#)
        try write(b, #"{"sessionId":"local_b","cliSessionId":"cli-b"}"#)
        let loader = Index.Loader()
        XCTAssertEqual(loader.records(root: root).map(\.sessionID), ["local_a", "local_b"])
        XCTAssertEqual(loader.parseCount, 2)
        _ = loader.records(root: root)
        XCTAssertEqual(loader.parseCount, 2, "unchanged files are not re-read")
        // A rewrite with a different size is re-parsed; a vanished file leaves the cache.
        try write(b, #"{"sessionId":"local_b","cliSessionId":"cli-b2","isArchived":true}"#)
        try FileManager.default.removeItem(at: a)
        let again = loader.records(root: root)
        XCTAssertEqual(again.map(\.sessionID), ["local_b"])
        XCTAssertEqual(again.first?.cliSessionID, "cli-b2")
        XCTAssertEqual(loader.parseCount, 3)
    }

    // MARK: - The locator across reconstruction seams (REGRESSIONS entry 7)

    func testDesktopSessionIDSurvivesReconstruction() {
        var located = AgentSessionStatus(
            id: "claude-a", provider: "claude", conversationID: "a", chatName: "Chat", projectName: "proj",
            rawState: "stopped", displayState: .stopped, updatedAt: Date(timeIntervalSince1970: 1_000),
            isVisible: true, executionStartedAt: nil, cwd: nil, hostPID: nil
        )
        located.desktopSessionID = "local_x"
        XCTAssertEqual(located.withDisplayState(.inactive, visible: true).desktopSessionID, "local_x")
        XCTAssertEqual(located.replacingChatName("y").desktopSessionID, "local_x")
        XCTAssertEqual(located.replacingProjectName("z").desktopSessionID, "local_x")
        var bare = located
        bare.desktopSessionID = nil
        XCTAssertEqual(bare.carryingExtras(from: located).desktopSessionID, "local_x", "nil yields to the other side")
        var other = located
        other.desktopSessionID = "local_other"
        XCTAssertEqual(located.carryingExtras(from: other).desktopSessionID, "local_x", "self keeps its own locator")
    }

    // MARK: - Helpers

    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kannu-desktop-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func write(_ url: URL, _ text: String) throws {
        try Data(text.utf8).write(to: url)
    }
}
