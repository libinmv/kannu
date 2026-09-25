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

import Foundation

enum AgentHookProvider: String, CaseIterable, Identifiable {
    case cursor
    case vscode
    case codex
    case claude
    case antigravity
    case gemini
    case qwen
    case opencode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .vscode: return "VS Code and Copilot CLI"
        case .codex: return "Codex CLI"
        case .claude: return "Claude Code"
        case .antigravity: return "Antigravity"
        case .gemini: return "Gemini CLI"
        case .qwen: return "Qwen Code"
        case .opencode: return "opencode"
        }
    }
}

/// Where each provider's hook lives: its script and every settings file its entries can be in.
/// Install, uninstall, the installed check and every migration read this one table —
/// docs/REGRESSIONS.md entry 6: while each kept its own list, the lists drifted apart twice (a
/// fresh Antigravity install was never migrated; uninstall left entries pointing at a deleted
/// script). A new provider is one more case here, and the tests hold every list to it.
///
/// Claude's usage status line (`~/.claude/kannu-usage-status.sh`, the `statusLine` key) is a
/// separate feature with its own install, migration and removal, and is not listed here.
struct AgentHookLayout: Equatable {
    enum Shape: Equatable {
        /// Cursor: `hooks.<event>` is a list of `{"command": …}`.
        case flatEntries
        /// Claude, Codex, Antigravity: `hooks.<event>` is a list of `{"hooks": [{"command": …}]}`.
        case matcherGroups
        /// VS Code: a file that is entirely Kannu's, deleted on uninstall.
        case ownFile
    }

    enum WritePolicy: Equatable {
        /// Install writes it, creating it when needed.
        case always
        /// Install merges into it only when it already exists; uninstall still strips it.
        case onlyIfPresent
    }

    struct ConfigFile: Equatable {
        let url: URL
        let shape: Shape
        let write: WritePolicy
    }

    struct Files: Equatable {
        let script: URL
        let configs: [ConfigFile]
        /// Settings install turns on and uninstall leaves alone, because other hooks may rely on
        /// them too (Codex's `features.hooks = true` in config.toml).
        let sharedSettings: [URL]
    }

    static let scriptName = "kannu-agent-status.sh"

    let home: URL

    var cursorHooksConfig: URL { home.appendingPathComponent(".cursor/hooks.json") }
    var cursorScript: URL { home.appendingPathComponent(".cursor/hooks/\(Self.scriptName)") }
    /// Copilot loads every JSON file in `~/.copilot/hooks`, so Kannu's is a file of its own.
    var vscodeHookFile: URL { home.appendingPathComponent(".copilot/hooks/kannu-agent-status.json") }
    var vscodeScript: URL { home.appendingPathComponent(".copilot/\(Self.scriptName)") }
    var codexHooksConfig: URL { home.appendingPathComponent(".codex/hooks.json") }
    var codexConfigToml: URL { home.appendingPathComponent(".codex/config.toml") }
    var codexScript: URL { home.appendingPathComponent(".codex/\(Self.scriptName)") }
    var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    var claudeScript: URL { home.appendingPathComponent(".claude/\(Self.scriptName)") }
    /// Antigravity reads whichever of its three hook files exists; this documented one is the
    /// file install always writes.
    var antigravityConfigHooks: URL { home.appendingPathComponent(".gemini/config/hooks.json") }
    var antigravityIDEHooks: URL { home.appendingPathComponent(".gemini/antigravity-ide/hooks.json") }
    var antigravityRootHooks: URL { home.appendingPathComponent(".gemini/hooks.json") }
    var antigravityScript: URL { home.appendingPathComponent(".gemini/antigravity-ide/\(Self.scriptName)") }
    /// Gemini CLI shares `~/.gemini` with Antigravity but reads its hooks from settings.json.
    var geminiSettings: URL { home.appendingPathComponent(".gemini/settings.json") }
    var geminiScript: URL { home.appendingPathComponent(".gemini/\(Self.scriptName)") }
    var qwenSettings: URL { home.appendingPathComponent(".qwen/settings.json") }
    var qwenScript: URL { home.appendingPathComponent(".qwen/\(Self.scriptName)") }
    /// opencode loads every file in `plugins/`, so the shared script sits one level up.
    var opencodePlugin: URL { home.appendingPathComponent(".config/opencode/plugins/\(OpencodePluginSource.fileName)") }
    var opencodeScript: URL { home.appendingPathComponent(".config/opencode/\(Self.scriptName)") }

    func files(for provider: AgentHookProvider) -> Files {
        switch provider {
        case .cursor:
            return Files(script: cursorScript,
                         configs: [ConfigFile(url: cursorHooksConfig, shape: .flatEntries, write: .always)],
                         sharedSettings: [])
        case .vscode:
            return Files(script: vscodeScript,
                         configs: [ConfigFile(url: vscodeHookFile, shape: .ownFile, write: .always)],
                         sharedSettings: [])
        case .codex:
            return Files(script: codexScript,
                         configs: [ConfigFile(url: codexHooksConfig, shape: .matcherGroups, write: .always)],
                         sharedSettings: [codexConfigToml])
        case .claude:
            return Files(script: claudeScript,
                         configs: [ConfigFile(url: claudeSettings, shape: .matcherGroups, write: .always)],
                         sharedSettings: [])
        case .antigravity:
            return Files(script: antigravityScript,
                         configs: [ConfigFile(url: antigravityConfigHooks, shape: .matcherGroups, write: .always),
                                   ConfigFile(url: antigravityIDEHooks, shape: .matcherGroups, write: .onlyIfPresent),
                                   ConfigFile(url: antigravityRootHooks, shape: .matcherGroups, write: .onlyIfPresent)],
                         sharedSettings: [])
        case .gemini:
            return Files(script: geminiScript,
                         configs: [ConfigFile(url: geminiSettings, shape: .matcherGroups, write: .always)],
                         sharedSettings: [])
        case .qwen:
            return Files(script: qwenScript,
                         configs: [ConfigFile(url: qwenSettings, shape: .matcherGroups, write: .always)],
                         sharedSettings: [])
        case .opencode:
            return Files(script: opencodeScript,
                         configs: [ConfigFile(url: opencodePlugin, shape: .ownFile, write: .always)],
                         sharedSettings: [])
        }
    }

    /// Whether the tool has ever run on this Mac. Only the opt-in CLIs are checked: an install
    /// for a tool that is not there would create its folder. `~/.gemini` alone means little —
    /// Antigravity makes it too — so Gemini CLI needs a file of its own.
    func toolIsPresent(_ provider: AgentHookProvider, fileManager: FileManager = .default) -> Bool {
        switch provider {
        case .gemini:
            return [".gemini/settings.json", ".gemini/projects.json", ".gemini/tmp", ".gemini/oauth_creds.json"]
                .contains { fileManager.fileExists(atPath: home.appendingPathComponent($0).path) }
        case .qwen:
            return fileManager.fileExists(atPath: home.appendingPathComponent(".qwen").path)
        case .opencode:
            return [".config/opencode", ".local/share/opencode"]
                .contains { fileManager.fileExists(atPath: home.appendingPathComponent($0).path) }
        case .cursor, .vscode, .codex, .claude, .antigravity:
            return true
        }
    }

    // MARK: - Events each hook file registers (the state is the no-python fallback's)

    /// VS Code Copilot and Codex, Claude-compatible PascalCase names. Codex validates strictly,
    /// so it keeps exactly this list.
    static let claudeStyleEvents: [(event: String, state: String)] = [
        // idle, not thinking: opening a session must not paint the green "running" light
        // (thinking stays visible for activeStaleMs, minutes of false "running").
        ("SessionStart", "idle"),
        ("UserPromptSubmit", "thinking"),
        ("PreToolUse", "executing"),
        ("PostToolUse", "thinking"),
        ("PermissionRequest", "awaiting_input"),
        ("Stop", "stopped")
    ]

    /// Kannu's own `~/.copilot/hooks` file, read by VS Code and by Copilot CLI. The CLI's yellow
    /// comes from `Notification` (permission_prompt, elicitation_dialog); the script ignores its
    /// `PermissionRequest`, which fires before the CLI's own rules decide anything.
    static let vscodeEvents: [(event: String, state: String)] = claudeStyleEvents + [
        ("Notification", "awaiting_input"),
        ("SessionEnd", "session_end")
    ]

    /// Gemini CLI (hooks on by default from v0.26). The script maps the names; a prompt on screen
    /// arrives as `Notification` with `notification_type: "ToolPermission"`.
    static let geminiEvents: [(event: String, state: String)] = [
        ("SessionStart", "idle"),
        ("BeforeAgent", "thinking"),
        ("BeforeTool", "executing"),
        ("AfterTool", "thinking"),
        ("Notification", "awaiting_input"),
        ("AfterAgent", "stopped"),
        ("SessionEnd", "session_end")
    ]

    /// Qwen Code, Claude-style. Its `PermissionRequest` fires when the dialog is shown.
    static let qwenEvents: [(event: String, state: String)] = claudeStyleEvents + [
        ("Notification", "awaiting_input"),
        ("SessionEnd", "session_end")
    ]

    /// Kannu's name on its Gemini CLI handlers (Gemini shows it while a hook runs).
    static let handlerName = "kannu-agent-status"

    // MARK: - Settings files Kannu shares with the tool (Gemini CLI, Qwen Code)

    /// Adds one matcher group per event, each holding Kannu's single handler, after removing any
    /// earlier Kannu group. Everything else in the file — and every other hook — is kept.
    static func mergingKannuGroups(into config: [String: Any], events: [(event: String, state: String)], script: URL,
                                   provider: String, handlerName: String?, timeout: Int) -> [String: Any] {
        var config = config
        var hooks = strippingKannuGroups(from: config["hooks"] as? [String: Any] ?? [:])
        for (event, state) in events {
            var handler: [String: Any] = ["type": "command", "command": "\(script.path) \(state) \(provider) \(event)",
                                          "timeout": timeout]
            if let handlerName { handler["name"] = handlerName }
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [handler]])
            hooks[event] = groups
        }
        config["hooks"] = hooks
        return config
    }

    /// Removes every group holding a Kannu handler (by script name, or by Kannu's handler name);
    /// events left with no groups are removed too.
    static func strippingKannuGroups(from hooks: [String: Any]) -> [String: Any] {
        var hooks = hooks
        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            groups.removeAll { group in
                (group["hooks"] as? [[String: Any]])?.contains { handler in
                    ((handler["command"] as? String)?.contains(scriptName) == true) || (handler["name"] as? String) == handlerName
                } == true
            }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        return hooks
    }

    /// The shape of any file a provider's entries can be in; nil for a file no provider uses.
    func shape(of url: URL) -> Shape? {
        for provider in AgentHookProvider.allCases {
            if let config = files(for: provider).configs.first(where: { $0.url == url }) { return config.shape }
        }
        return nil
    }
}
