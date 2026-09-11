//
//  MCPServerWatchTests.swift
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

/// "A new MCP server appeared": every settings format, trust on first use, nothing secret shown,
/// and the Discovery scan trigger that keeps a change it saw too early.
final class MCPServerWatchTests: XCTestCase {
    typealias Watch = MCPServerWatch
    private let home = "/Users/u"

    private func servers(_ json: String, _ format: Watch.Location.Format, json5: Bool = false) -> [Watch.Server]? {
        Watch.servers(in: Data(json.utf8), format: format, json5: json5)
    }

    func testEveryFormat() {
        XCTAssertEqual(servers(#"{"mcpServers":{"b":{"command":"npx","args":["-y","@modelcontextprotocol/server-github"]},"a":{"url":"https://mcp.example.com/sse?token=abc"}}}"#, .mcpServers),
                       [.init(scope: nil, name: "a", runs: "https://mcp.example.com"),
                        .init(scope: nil, name: "b", runs: "npx @modelcontextprotocol/server-github")])
        XCTAssertEqual(servers(#"{"mcpServers":{"u":{"command":"uvx","args":["mcp-server-fetch"]}},"projects":{"/p":{"mcpServers":{"local":{"command":"node"}}},"/q":{"allowedTools":[]}}}"#, .claudeUserConfig)?.map(\.key),
                       ["|u", "/p|local"])
        let jsonc = """
        {
          // VS Code allows comments
          "servers": { "gh": { "type": "http", "url": "https://api.githubcopilot.com/mcp/", }, },
        }
        """
        XCTAssertEqual(servers(jsonc, .vsCodeServers, json5: true)?.map(\.name), ["gh"])
        XCTAssertNil(servers(jsonc, .vsCodeServers, json5: false), "strict JSON refuses comments")
        XCTAssertEqual(servers(#"{"mcp":{"x":{"type":"local","command":["bunx","my-mcp"]}}}"#, .opencode, json5: true),
                       [.init(scope: nil, name: "x", runs: "bunx my-mcp")])
        let toml = "model = \"o4\"\r\n[mcp_servers.github]\ncommand = \"npx\"\n[mcp_servers.github.env]\nTOKEN = \"x\"\n[mcp_servers.\"dotted.name\"]\n[profiles.x]\n"
        XCTAssertEqual(Watch.codexServers(inTOML: toml).map(\.name), ["github", "dotted.name"])
        XCTAssertEqual(servers("  \n", .mcpServers), [], "an empty file declares nothing")
        XCTAssertNil(servers(#"{"mcpServers":{"half"#, .mcpServers), "a half-written file is unreadable, not empty")
        XCTAssertEqual(servers(#"{"other":1}"#, .mcpServers), [])
    }

    func testRunsNeverShowsSecrets() {
        XCTAssertEqual(Watch.runs(of: ["command": "/opt/homebrew/bin/npx", "args": ["-y", "--token=ghp_abc", "@org/server"]]), "npx @org/server")
        XCTAssertEqual(Watch.runs(of: ["command": "server", "args": ["sk-AbC123xyz"]]), "server", "mixed case: not a package")
        XCTAssertEqual(Watch.runs(of: ["command": "server", "args": ["0123456789abcdef0123456789abcdef"]]), "server", "a long hex run is not a package")
        XCTAssertEqual(Watch.runs(of: ["url": "https://user:pass@mcp.example.com/path?key=1"]), "https://mcp.example.com")
        XCTAssertEqual(Watch.runs(of: [:]), "")
    }

    func testProjectRootsSkipProtectedFolders() {
        let roots = Watch.projectRoots(["/Users/u/code/app", "/Users/u/code/app/", "/Users/u/Documents/x", "/Users/u/Desktop",
                                        "/Users/u", "/Volumes/ext/p", "relative", nil, "/Users/u/Library/Mobile Documents/y"],
                                       home: home)
        XCTAssertEqual(roots, ["/Users/u/code/app"])
        XCTAssertEqual(Watch.projectRoots((0..<30).map { "/src/p\($0)" }, home: home).count, 20)
    }

    func testFirstLookIsSilentThenAdditionsAndRemovals() {
        let location = Watch.globalLocations(home: home).first { $0.appName == "Cursor" }!
        let a = Watch.Server(scope: nil, name: "a", runs: "npx a")
        let b = Watch.Server(scope: nil, name: "b", runs: "npx b")
        var (baseline, additions) = Watch.compare(baseline: .init(), reads: [location.path: [a]], locations: [location], nowMs: 1)
        XCTAssertEqual(additions, [], "trust on first use")
        (baseline, additions) = Watch.compare(baseline: baseline, reads: [location.path: [a, b]], locations: [location], nowMs: 2)
        XCTAssertEqual(additions.map(\.name), ["b"])
        XCTAssertEqual(additions.first?.appName, "Cursor")
        let unread = Watch.compare(baseline: baseline, reads: [:], locations: [location], nowMs: 3)
        XCTAssertEqual(unread.baseline, baseline, "an unread file keeps what was known")
        XCTAssertEqual(unread.additions, [])
        (baseline, additions) = Watch.compare(baseline: baseline, reads: [location.path: [a]], locations: [location], nowMs: 4)
        XCTAssertEqual(additions, [])
        XCTAssertEqual(Watch.pruning([Watch.Addition(configPath: location.path, appName: "Cursor", projectRoot: nil, scope: nil,
                                                     name: "b", runs: "", firstSeenMs: 2)], reads: [location.path: [a]]), [],
                       "a removed server's finding goes")
        let readded = Watch.compare(baseline: baseline, reads: [location.path: [a, b]], locations: [location], nowMs: 5)
        XCTAssertEqual(readded.additions.map(\.firstSeenMs), [5], "added again is news again")
        XCTAssertNotEqual(readded.additions[0].findingID,
                          Watch.Addition(configPath: location.path, appName: "Cursor", projectRoot: nil, scope: nil,
                                         name: "b", runs: "", firstSeenMs: 2).findingID)
    }

    func testAMissingFileThatAppearsWithServersIsNews() {
        let location = Watch.projectLocations(root: "/src/app")[0]
        let seeded = Watch.compare(baseline: .init(), reads: [location.path: []], locations: [location], nowMs: 1)
        let created = Watch.compare(baseline: seeded.baseline, reads: [location.path: [.init(scope: nil, name: "evil", runs: "")]],
                                    locations: [location], nowMs: 2)
        XCTAssertEqual(created.additions.map(\.name), ["evil"])
        XCTAssertEqual(created.additions.first?.projectRoot, "/src/app")
    }

    func testTheFindingIsPlainAndPathFree() {
        let addition = Watch.Addition(configPath: home + "/.claude.json", appName: "Claude Code", projectRoot: nil,
                                      scope: home + "/code/app", name: "github", runs: "npx @org/server", firstSeenMs: 1_788_000_000_000)
        let finding = addition.finding(home: home)
        XCTAssertEqual(finding.severity, .medium)
        XCTAssertEqual(finding.title, "New MCP server: github")
        XCTAssertFalse(finding.summary.contains("/"), "the summary is pushed: no paths")
        XCTAssertTrue(finding.evidence.contains("Runs: npx @org/server"))
        XCTAssertTrue(finding.evidence.contains { $0.contains("~/.claude.json") && $0.contains("~/code/app") })
    }

    func testReadingUsesTheCacheAndTellsMissingFromUnreadable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.path
        let locations = Watch.projectLocations(root: root)
        var result = Watch.read(locations, cache: [:])
        XCTAssertEqual(result.reads[root + "/.mcp.json"], [], "missing: no servers")
        try Data(#"{"mcpServers":{"a":{"command":"npx"}}}"#.utf8).write(to: URL(fileURLWithPath: root + "/.mcp.json"))
        result = Watch.read(locations, cache: result.cache)
        XCTAssertEqual(result.reads[root + "/.mcp.json"]?.map(\.name), ["a"])
        let cached = Watch.read(locations, cache: result.cache)
        XCTAssertEqual(cached.cache, result.cache)
        try Data(#"{"mcpServers":{"a""#.utf8).write(to: URL(fileURLWithPath: root + "/.mcp.json"))
        let broken = Watch.read(locations, cache: result.cache)
        XCTAssertNil(broken.reads[root + "/.mcp.json"], "unreadable: left out, not emptied")
    }

    func testTheInventoryIsTheGlobalFilesOnly() {
        let global = Watch.globalLocations(home: home)[3].path
        let reads: [String: [Watch.Server]] = [global: [.init(scope: nil, name: "a", runs: "")], "/src/app/.mcp.json": []]
        XCTAssertEqual(Watch.inventory(reads, home: home), [global: ["|a"]])
    }

    // MARK: - Discovery scan trigger

    func testAChangeInsideTheDebounceIsKept() {
        var trigger = ADRScanTrigger(interval: 86_400, debounce: 300)
        let t0 = Date(timeIntervalSince1970: 1_788_000_000)
        let lastScan = t0
        XCTAssertNil(trigger.evaluate(now: t0.addingTimeInterval(60), lastScan: lastScan, inventory: ["f": ["|a"]]), "first look learns")
        XCTAssertNil(trigger.evaluate(now: t0.addingTimeInterval(120), lastScan: lastScan, inventory: ["f": ["|a", "|b"]]),
                     "changed inside the window: wait")
        XCTAssertTrue(trigger.pendingChange)
        XCTAssertNil(trigger.evaluate(now: t0.addingTimeInterval(180), lastScan: lastScan, inventory: ["f": ["|a", "|b"]]))
        XCTAssertEqual(trigger.evaluate(now: t0.addingTimeInterval(301), lastScan: lastScan, inventory: nil), .configChanged,
                       "the change was kept, not dropped")
        XCTAssertNil(trigger.evaluate(now: t0.addingTimeInterval(400), lastScan: lastScan, inventory: ["f": ["|a", "|b"]]), "once")
        XCTAssertEqual(trigger.evaluate(now: t0.addingTimeInterval(86_401), lastScan: lastScan, inventory: nil), .scheduled)
    }

    func testAnyScanCoversAPendingChange() {
        var trigger = ADRScanTrigger(interval: 86_400, debounce: 300)
        let t0 = Date(timeIntervalSince1970: 1_788_000_000)
        _ = trigger.evaluate(now: t0, lastScan: t0, inventory: ["f": []])
        _ = trigger.evaluate(now: t0.addingTimeInterval(10), lastScan: t0, inventory: ["f": ["|x"]])
        trigger.scanStarted()
        XCTAssertNil(trigger.evaluate(now: t0.addingTimeInterval(900), lastScan: t0, inventory: ["f": ["|x"]]))
    }
}
