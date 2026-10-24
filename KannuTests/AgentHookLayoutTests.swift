//
//  AgentHookLayoutTests.swift
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

/// docs/REGRESSIONS.md entry 6: install, uninstall, the installed check and the migrations must
/// cover the same files. They all read `AgentHookLayout` now; these pin the table and keep paths
/// from creeping back into the installer.
final class AgentHookLayoutTests: XCTestCase {
    private let layout = AgentHookLayout(home: URL(fileURLWithPath: "/Users/u"))

    func testEveryProviderHasAScriptAndAFileInstallAlwaysWrites() {
        var scripts: Set<URL> = []
        var configs: Set<URL> = []
        for provider in AgentHookProvider.allCases {
            let files = layout.files(for: provider)
            XCTAssertEqual(files.script.lastPathComponent, AgentHookLayout.scriptName, "\(provider)")
            XCTAssertTrue(files.script.path.hasPrefix("/Users/u/."), "\(provider) lives in the home folder")
            XCTAssertTrue(scripts.insert(files.script).inserted, "\(provider) has a script of its own")
            XCTAssertTrue(files.configs.contains { $0.write == .always },
                          "\(provider): a fresh install must write a file the installed check can see")
            for config in files.configs {
                XCTAssertTrue(configs.insert(config.url).inserted, "\(config.url.path) belongs to one provider")
                XCTAssertEqual(layout.shape(of: config.url), config.shape)
            }
        }
        XCTAssertNil(layout.shape(of: URL(fileURLWithPath: "/Users/u/.zshrc")))
    }

    /// v46: the documented global file is the one install writes; the two an older Kannu also wrote
    /// stay listed so install and uninstall clean them (REGRESSIONS entry 6).
    func testAntigravityWritesTheDocumentedFileAndCleansTheTwoOlderOnes() {
        let files = layout.files(for: .antigravity)
        XCTAssertEqual(files.configs.map(\.url.path), ["/Users/u/.gemini/config/hooks.json",
                                                       "/Users/u/.gemini/antigravity-ide/hooks.json",
                                                       "/Users/u/.gemini/hooks.json"])
        XCTAssertEqual(files.configs.map(\.write), [.always, .stripOnly, .stripOnly])
        XCTAssertEqual(files.configs.map(\.shape), [.namedHooks, .namedHooks, .namedHooks])
        XCTAssertEqual(layout.files(for: .codex).sharedSettings.map(\.lastPathComponent), ["config.toml"])
        XCTAssertEqual(layout.files(for: .vscode).configs.map(\.shape), [.ownFile])
        XCTAssertEqual(layout.files(for: .cursor).configs.map(\.shape), [.flatEntries])
        XCTAssertEqual(layout.files(for: .gemini).configs.map(\.url.path), ["/Users/u/.gemini/settings.json"])
        XCTAssertEqual(layout.files(for: .gemini).script.path, "/Users/u/.gemini/kannu-agent-status.sh",
                       "beside Antigravity's folder, not inside it")
        XCTAssertEqual(layout.files(for: .qwen).configs.map(\.url.path), ["/Users/u/.qwen/settings.json"])
        let opencode = layout.files(for: .opencode)
        XCTAssertEqual(opencode.configs.map(\.url.path), ["/Users/u/.config/opencode/plugins/kannu-agent-status.js"])
        XCTAssertEqual(opencode.configs.map(\.shape), [.ownFile])
        XCTAssertEqual(opencode.script.deletingLastPathComponent().lastPathComponent, "opencode",
                       "outside plugins/, which opencode loads wholesale")
    }

    func testTheClaudeTableKeepsEveryEventMatcherAndState() {
        // Moved here from the installer so the cloud-session relay's settings snippet reads the
        // same rows. Any change to a row changes both installs at once: make it deliberately.
        let rows = AgentHookLayout.claudeHookEntries.map { "\($0.event)|\($0.matcher ?? "-")|\($0.matcherKey)|\($0.state)" }
        XCTAssertEqual(rows, [
            "SessionStart|-||idle",
            "UserPromptSubmit|-||thinking",
            "UserPromptExpansion|-||thinking",
            "PreToolUse|ExitPlanMode|AskUserQuestion|gated|awaiting_input",
            "PreToolUse|-||executing",
            "PostToolUse|-||thinking",
            "PostToolUseFailure|-||thinking",
            "PermissionRequest|-||awaiting_input",
            "Notification|agent_completed|completed|stopped",
            "Notification|permission_prompt|idle_prompt|agent_needs_input|needs_input|awaiting_input",
            "Stop|-||stopped",
            "StopFailure|-||stopped",
            "SubagentStart|-||thinking",
            "SubagentStop|-||stopped",
            "SessionEnd|-||session_end"
        ])
    }

    func testVSCodeTableGainsNotificationButCodexDoesNot() {
        let vscode = AgentHookLayout.vscodeEvents.map(\.event)
        XCTAssertTrue(vscode.contains("Notification"))
        XCTAssertTrue(vscode.contains("SessionEnd"))
        XCTAssertFalse(AgentHookLayout.claudeStyleEvents.map(\.event).contains("Notification"),
                       "Codex validates strictly: its list stays as it was")
        XCTAssertEqual(AgentHookLayout.geminiEvents.map(\.event),
                       ["SessionStart", "BeforeAgent", "BeforeTool", "AfterTool", "Notification", "AfterAgent", "SessionEnd"])
    }

    func testGeminiMergeWritesOnlyEventKeysAndStripsCleanly() throws {
        let user: [String: Any] = [
            "mcpServers": ["x": ["command": "npx"]],
            "hooks": ["BeforeTool": [["matcher": "write_file", "hooks": [["type": "command", "command": "/usr/local/bin/guard"]]]]],
        ]
        let script = URL(fileURLWithPath: "/Users/u/.gemini/kannu-agent-status.sh")
        let once = AgentHookLayout.mergingKannuGroups(into: user, events: AgentHookLayout.geminiEvents, script: script,
                                                      provider: "gemini", handlerName: AgentHookLayout.handlerName, timeout: 10_000)
        let twice = AgentHookLayout.mergingKannuGroups(into: once, events: AgentHookLayout.geminiEvents, script: script,
                                                       provider: "gemini", handlerName: AgentHookLayout.handlerName, timeout: 10_000)
        XCTAssertEqual(NSDictionary(dictionary: once), NSDictionary(dictionary: twice), "merging again changes nothing")
        let hooks = try XCTUnwrap(once["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(AgentHookLayout.geminiEvents.map(\.event)), "only real event names under hooks")
        XCTAssertNotNil(once["mcpServers"], "the rest of the file is kept")
        let beforeTool = try XCTUnwrap(hooks["BeforeTool"] as? [[String: Any]])
        XCTAssertEqual(beforeTool.count, 2, "the user's own hook stays")
        let ours = try XCTUnwrap((beforeTool.last?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(ours["command"] as? String, script.path + " executing gemini BeforeTool")
        XCTAssertEqual(ours["name"] as? String, "kannu-agent-status")
        XCTAssertEqual(ours["timeout"] as? Int, 10_000)
        let stripped = AgentHookLayout.strippingKannuGroups(from: hooks)
        XCTAssertEqual(stripped.keys.sorted(), ["BeforeTool"])
        XCTAssertEqual((stripped["BeforeTool"] as? [[String: Any]])?.count, 1)
    }

    func testQwenMergeRoundTrip() throws {
        let script = URL(fileURLWithPath: "/Users/u/.qwen/kannu-agent-status.sh")
        let merged = AgentHookLayout.mergingKannuGroups(into: [:], events: AgentHookLayout.qwenEvents, script: script,
                                                        provider: "qwen", handlerName: nil, timeout: 10)
        let hooks = try XCTUnwrap(merged["hooks"] as? [String: Any])
        let handler = try XCTUnwrap(((hooks["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(handler["command"] as? String, script.path + " awaiting_input qwen PermissionRequest")
        XCTAssertNil(handler["name"])
        XCTAssertTrue(AgentHookLayout.strippingKannuGroups(from: hooks).isEmpty)
    }

    func testOnlyTheOptInCLIsNeedToBePresent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hook-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".gemini/antigravity-ide"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let layout = AgentHookLayout(home: dir)
        XCTAssertFalse(layout.toolIsPresent(.gemini), "Antigravity's folder alone is not Gemini CLI")
        XCTAssertFalse(layout.toolIsPresent(.qwen))
        XCTAssertTrue(layout.toolIsPresent(.claude))
        FileManager.default.createFile(atPath: dir.appendingPathComponent(".gemini/projects.json").path, contents: Data("{}".utf8))
        XCTAssertTrue(layout.toolIsPresent(.gemini))
    }

    /// The installer may name paths only through the layout. Comments and the embedded hook
    /// script (whose sensitive-file tables list agent settings on purpose) are not code paths.
    func testTheInstallerHardCodesNoHookPaths() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kannu/managers/AgentStatus/AgentHookInstaller.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let forbidden = [".cursor/hooks.json", ".cursor/hooks/", ".copilot/hooks", ".codex/hooks.json", ".codex/config.toml",
                         ".claude/settings.json", ".gemini/config/hooks.json", ".gemini/antigravity-ide", ".gemini/hooks.json"]
        var insideScript = false
        for (number, line) in source.components(separatedBy: "\n").enumerated() {
            if insideScript {
                if line == "        \"\"\"" { insideScript = false }
                continue
            }
            if line.hasSuffix("let script = \"\"\"") { insideScript = true; continue }
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("//") || code.hasPrefix("*") { continue }
            for path in forbidden where code.contains(path) {
                XCTFail("AgentHookInstaller.swift:\(number + 1) names \(path); take it from AgentHookLayout")
            }
        }
    }

    // MARK: - v45: new events, and the installed check that must not move with them

    func testCursorRegistersSessionEndAndItsSubagentEvents() {
        let states = Dictionary(AgentHookLayout.cursorEvents.map { ($0.event, $0.state) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(states["sessionEnd"], "session_end")
        XCTAssertEqual(states["subagentStart"], "thinking")
        XCTAssertEqual(states["subagentStop"], "stopped")
        XCTAssertEqual(AgentHookLayout.cursorEvents.count, states.count, "one entry per Cursor event")
    }

    /// REGRESSIONS entry 6: an install from v44 must still read as installed, or the Settings toggle
    /// flips off and the migrations gated on it skip the very installs that need the new events.
    func testTheInstalledCheckIsAFixedCoreOfEachTable() {
        let cursor = Set(AgentHookLayout.cursorEvents.map(\.event))
        XCTAssertTrue(Set(AgentHookLayout.cursorCoreInstalledEvents).isSubset(of: cursor))
        XCTAssertEqual(AgentHookLayout.cursorCoreInstalledEvents.count, 9, "the v44 table, unchanged")
        for event in ["sessionEnd", "subagentStart", "subagentStop"] {
            XCTAssertFalse(AgentHookLayout.cursorCoreInstalledEvents.contains(event), event)
        }
        let claude = Set(AgentHookLayout.claudeHookEntries.map(\.event))
        XCTAssertTrue(Set(AgentHookLayout.claudeCoreInstalledEvents).isSubset(of: claude))
        XCTAssertEqual(AgentHookLayout.claudeCoreInstalledEvents, ["SessionStart", "UserPromptSubmit", "PreToolUse", "Stop"])
        let antigravity = Set(AgentHookLayout.antigravityEvents.map(\.event))
        XCTAssertTrue(Set(AgentHookLayout.antigravityCoreInstalledEvents).isSubset(of: antigravity))
        XCTAssertEqual(AgentHookLayout.antigravityCoreInstalledEvents, ["PreInvocation", "PreToolUse", "Stop"], "the v46 core")
    }

    func testClaudeRegistersUserPromptExpansionWithoutAMatcher() throws {
        let entry = try XCTUnwrap(AgentHookLayout.claudeHookEntries.first { $0.event == "UserPromptExpansion" })
        XCTAssertNil(entry.matcher)
        XCTAssertEqual(entry.matcherKey, "")
        XCTAssertEqual(entry.state, "thinking")
        XCTAssertEqual(AgentHookLayout.claudeHookEntries.filter { $0.matcherKey == "gated" }.map(\.matcher),
                       ["ExitPlanMode|AskUserQuestion"], "the one group the script checks against its tools")
    }

    /// Install merges and uninstall strips the same entries, the new events included, and leaves the
    /// user's own hooks alone.
    func testCursorMergeAndStripCoverEveryEvent() throws {
        let user: [String: Any] = ["stop": [["command": "./notify.sh"]],
                                   "sessionEnd": [["command": "./cleanup.sh"]]]
        let once = AgentHookLayout.mergingKannuEntries(into: user, events: AgentHookLayout.cursorEvents)
        let twice = AgentHookLayout.mergingKannuEntries(into: once, events: AgentHookLayout.cursorEvents)
        XCTAssertEqual(NSDictionary(dictionary: once), NSDictionary(dictionary: twice), "merging again changes nothing")
        XCTAssertEqual(Set(once.keys), Set(AgentHookLayout.cursorEvents.map(\.event)))
        let sessionEnd = try XCTUnwrap(once["sessionEnd"] as? [[String: Any]])
        XCTAssertEqual(sessionEnd.map { $0["command"] as? String },
                       ["./cleanup.sh", "hooks/kannu-agent-status.sh session_end cursor sessionEnd"])
        XCTAssertEqual((once["subagentStart"] as? [[String: Any]])?.first?["command"] as? String,
                       "hooks/kannu-agent-status.sh thinking cursor subagentStart")
        let stripped = AgentHookLayout.strippingKannuEntries(from: once)
        XCTAssertEqual(NSDictionary(dictionary: stripped), NSDictionary(dictionary: user), "only Kannu's entries go")
        let legacy: [String: Any] = ["stop": [["command": "hooks/atoll-agent-status.sh stopped cursor stop"]]]
        XCTAssertTrue(AgentHookLayout.strippingKannuEntries(from: legacy).isEmpty)
    }

    /// learn.chatgpt.com/docs/hooks: hooks are on by default and `hooks = false` turns them off;
    /// `codex_hooks` is a deprecated alias. A value the user wrote is never changed.
    func testCodexConfigAddsTheFlagOnlyWhenTheFileSaysNothing() {
        XCTAssertEqual(AgentHookLayout.codexConfigEnablingHooks(""), "\n[features]\nhooks = true\n")
        XCTAssertEqual(AgentHookLayout.codexConfigEnablingHooks("model = \"o3\""),
                       "model = \"o3\"\n\n[features]\nhooks = true\n")
        XCTAssertEqual(AgentHookLayout.codexConfigEnablingHooks("[features]\nweb_search = true\n\n[tui]\nx = 1\n"),
                       "[features]\nhooks = true\nweb_search = true\n\n[tui]\nx = 1\n")
        XCTAssertEqual(AgentHookLayout.codexConfigEnablingHooks("model = \"o3\"\n[features]"),
                       "model = \"o3\"\n[features]\nhooks = true\n", "a header on the last line")
        for kept in ["[features]\nhooks = false\n", "[features]\n  hooks=false # mine\n", "features.hooks = false\n",
                     "[features]\ncodex_hooks = false\n", "features.codex_hooks = true\n", "[features]\nhooks = true\n",
                     "features = { hooks = false }\n", "features = { web_search = true }\n"] {
            XCTAssertNil(AgentHookLayout.codexConfigEnablingHooks(kept), kept)
        }
        XCTAssertEqual(AgentHookLayout.codexConfigEnablingHooks("[profiles.work.features]\nhooks = false\n"),
                       "[profiles.work.features]\nhooks = false\n\n[features]\nhooks = true\n",
                       "a profile's table is not the top-level one")
        // A "[" that starts no table does not end the section: a second `hooks` key is invalid TOML.
        for kept in ["[features]\n# see [docs]\nhooks = false\n",
                     "[features]\nlist = [\"a\", \"b\"]\nhooks = false\n",
                     "[features]\nnested = [\n  [1, 2],\n]\nhooks = false\n",
                     "[features] # flags\nhooks = false\n",
                     "  [ features ]\nhooks = false\n"] {
            XCTAssertNil(AgentHookLayout.codexConfigEnablingHooks(kept), kept)
        }
        // The section still ends at the next table, however that header is spaced.
        XCTAssertEqual(AgentHookLayout.codexConfigEnablingHooks("[features]\nweb_search = true\n  [ tui ] # x\nhooks = 1\n"),
                       "[features]\nhooks = true\nweb_search = true\n  [ tui ] # x\nhooks = 1\n")
        XCTAssertEqual(AgentHookLayout.codexConfigEnablingHooks("[features]\nweb_search = true\n[[mcp]]\nhooks = 1\n"),
                       "[features]\nhooks = true\nweb_search = true\n[[mcp]]\nhooks = 1\n")
        XCTAssertEqual(AgentHookLayout.codexConfigEnablingHooks("  [features]\nweb_search = true\n"),
                       "  [features]\nhooks = true\nweb_search = true\n", "an indented header is the same table")
    }
}

// MARK: - v46: Antigravity's named hooks

extension AgentHookLayoutTests {
    private var antigravityScript: URL { layout.files(for: .antigravity).script }

    /// What Kannu v45 wrote: Claude-style matcher groups under `hooks`, UserPromptSubmit included.
    private func v45AntigravityFile(userGroup: [String: Any]? = nil) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for (event, state) in [("SessionStart", "idle"), ("UserPromptSubmit", "thinking"), ("PreToolUse", "executing"), ("Stop", "stopped")] {
            let handler: [String: Any] = ["type": "command", "command": "\(antigravityScript.path) \(state) antigravity \(event)", "timeout": 10]
            let group: [String: Any] = ["hooks": [handler]]
            hooks[event] = [group]
        }
        if let userGroup { hooks["PreToolUse"] = (hooks["PreToolUse"] as? [[String: Any]] ?? []) + [userGroup] }
        return ["hooks": hooks]
    }

    /// antigravity.google/docs/hooks: the top level maps a hook name to its configuration; only
    /// PreToolUse and PostToolUse take matcher groups, the other four a flat list of handlers.
    func testTheAntigravityEntryIsInTheDocumentedShape() throws {
        let user: [String: Any] = ["my-linter": ["PostToolUse": [["matcher": "run_command",
                                                                  "hooks": [["type": "command", "command": "./lint.sh"]]]]]]
        let merged = AgentHookLayout.mergingAntigravityEntry(into: user, script: antigravityScript)
        XCTAssertEqual(Set(merged.keys), ["my-linter", "kannu-agent-status"], "nothing else at the top level")
        XCTAssertEqual(NSDictionary(dictionary: try XCTUnwrap(merged["my-linter"] as? [String: Any])),
                       NSDictionary(dictionary: try XCTUnwrap(user["my-linter"] as? [String: Any])), "the user's hook is kept as it was")
        let entry = try XCTUnwrap(merged["kannu-agent-status"] as? [String: Any])
        XCTAssertEqual(entry["enabled"] as? Bool, true)
        XCTAssertEqual(Set(entry.keys).subtracting(["enabled"]),
                       ["SessionStart", "PreInvocation", "PostInvocation", "PreToolUse", "PostToolUse", "Stop"])
        XCTAssertNil(entry["UserPromptSubmit"], "not an Antigravity event")
        for (event, state) in AgentHookLayout.antigravityEvents {
            let items = try XCTUnwrap(entry[event] as? [[String: Any]], event)
            XCTAssertEqual(items.count, 1, event)
            let handler: [String: Any]
            if ["PreToolUse", "PostToolUse"].contains(event) {
                XCTAssertEqual(items[0]["matcher"] as? String, "", "\(event): every tool")
                handler = try XCTUnwrap((items[0]["hooks"] as? [[String: Any]])?.first, event)
            } else {
                XCTAssertNil(items[0]["matcher"], "\(event) takes no matcher")
                XCTAssertNil(items[0]["hooks"], "\(event) takes its handlers directly")
                handler = items[0]
            }
            XCTAssertEqual(handler["type"] as? String, "command")
            XCTAssertEqual(handler["command"] as? String, "\(antigravityScript.path) \(state) antigravity \(event)")
            XCTAssertEqual(handler["timeout"] as? Int, 10)
        }
        let again = AgentHookLayout.mergingAntigravityEntry(into: merged, script: antigravityScript)
        XCTAssertEqual(NSDictionary(dictionary: again), NSDictionary(dictionary: merged), "merging again changes nothing")
        XCTAssertTrue(AgentHookLayout.antigravityEntryCovers(merged, events: AgentHookLayout.antigravityCoreInstalledEvents))
        XCTAssertTrue(AgentHookLayout.antigravityEntryCovers(merged, events: AgentHookLayout.antigravityEvents.map(\.event)))
        XCTAssertFalse(AgentHookLayout.hasLegacyAntigravityGroups(merged))
    }

    /// Install over a v45 file: Kannu's old groups go, the user's group beside them stays, and the
    /// file reads as installed only through the new entry.
    func testInstallMigratesTheV45ShapeAndKeepsTheUsersGroups() throws {
        let userGroup: [String: Any] = ["matcher": "run_command", "hooks": [["type": "command", "command": "./guard.sh"]]]
        let old = v45AntigravityFile(userGroup: userGroup)
        XCTAssertTrue(AgentHookLayout.hasLegacyAntigravityGroups(old), "the shape migration's trigger")
        XCTAssertFalse(AgentHookLayout.antigravityEntryCovers(old, events: AgentHookLayout.antigravityCoreInstalledEvents),
                       "a v45 file is not a v46 install; the version migration upgrades it")
        let merged = AgentHookLayout.mergingAntigravityEntry(into: old, script: antigravityScript)
        XCTAssertFalse(AgentHookLayout.hasLegacyAntigravityGroups(merged))
        let legacy = try XCTUnwrap(merged["hooks"] as? [String: Any], "the user's group keeps its place")
        XCTAssertEqual(Array(legacy.keys), ["PreToolUse"])
        XCTAssertEqual((legacy["PreToolUse"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(((legacy["PreToolUse"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String,
                       "./guard.sh")
        XCTAssertNotNil(merged["kannu-agent-status"])
        // A v45 file with nothing of the user's under `hooks` loses the key altogether.
        let clean = AgentHookLayout.mergingAntigravityEntry(into: v45AntigravityFile(), script: antigravityScript)
        XCTAssertEqual(Array(clean.keys), ["kannu-agent-status"])
    }

    /// Uninstall strips exactly what install wrote, in either shape, and nothing of the user's.
    func testUninstallStripsBothShapesAndOnlyKannus() throws {
        let user: [String: Any] = ["my-linter": ["enabled": false, "Stop": [["type": "command", "command": "./notify.sh"]]],
                                   "hooks": ["PreToolUse": [["matcher": "x", "hooks": [["command": "./mine.sh"]]]]]]
        let installed = AgentHookLayout.mergingAntigravityEntry(into: user, script: antigravityScript)
        XCTAssertEqual(NSDictionary(dictionary: AgentHookLayout.strippingAntigravityEntries(from: installed)),
                       NSDictionary(dictionary: user))
        XCTAssertTrue(AgentHookLayout.strippingAntigravityEntries(from: v45AntigravityFile()).isEmpty)
        XCTAssertFalse(AgentHookLayout.hasLegacyAntigravityGroups(user), "a user's own `hooks` hook is not Kannu's")
        XCTAssertEqual(NSDictionary(dictionary: AgentHookLayout.strippingAntigravityEntries(from: user)), NSDictionary(dictionary: user))
    }

    /// A user who switched Kannu's hook off in Antigravity keeps it off across a reinstall.
    func testReinstallKeepsTheUsersEnabledFalse() throws {
        var installed = AgentHookLayout.mergingAntigravityEntry(into: [:], script: antigravityScript)
        var entry = try XCTUnwrap(installed["kannu-agent-status"] as? [String: Any])
        entry["enabled"] = false
        installed["kannu-agent-status"] = entry
        let again = AgentHookLayout.mergingAntigravityEntry(into: installed, script: antigravityScript)
        XCTAssertEqual((again["kannu-agent-status"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertTrue(AgentHookLayout.antigravityEntryCovers(again, events: AgentHookLayout.antigravityCoreInstalledEvents),
                      "still installed: the entries are there")
        var partial = try XCTUnwrap(again["kannu-agent-status"] as? [String: Any])
        partial["Stop"] = nil
        XCTAssertFalse(AgentHookLayout.antigravityEntryCovers(["kannu-agent-status": partial],
                                                             events: AgentHookLayout.antigravityCoreInstalledEvents))
    }
}
