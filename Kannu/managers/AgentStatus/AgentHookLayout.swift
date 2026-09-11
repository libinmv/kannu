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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .vscode: return "VS Code (Copilot)"
        case .codex: return "Codex CLI"
        case .claude: return "Claude Code"
        case .antigravity: return "Antigravity"
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
        }
    }

    /// The shape of any file a provider's entries can be in; nil for a file no provider uses.
    func shape(of url: URL) -> Shape? {
        for provider in AgentHookProvider.allCases {
            if let config = files(for: provider).configs.first(where: { $0.url == url }) { return config.shape }
        }
        return nil
    }
}
