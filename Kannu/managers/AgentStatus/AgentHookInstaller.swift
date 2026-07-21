import Foundation

enum AgentHookProvider: String, CaseIterable, Identifiable {
    case cursor
    case vscode
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .vscode: return "VS Code (Copilot)"
        case .codex: return "Codex CLI"
        case .claude: return "Claude Code"
        }
    }
}

/// Installs agent-status hooks for the supported AI coding tools. Every hook
/// runs the same shell script, which writes a small per-conversation status
/// file into a shared directory that `CursorAgentStatusMonitor` watches.
///
/// Per-provider layout:
/// - Cursor:  script `~/.cursor/hooks/kannu-agent-status.sh`, entries merged
///   into `~/.cursor/hooks.json` (relative command paths).
/// - VS Code: script `~/.copilot/kannu-agent-status.sh`, self-contained hook
///   file `~/.copilot/hooks/kannu-agent-status.json` (Copilot loads every
///   JSON file in that folder).
/// - Codex:   script `~/.codex/kannu-agent-status.sh`, entries merged into
///   `~/.codex/hooks.json`, plus `features.hooks = true` in
///   `~/.codex/config.toml`.
/// - Claude:  script `~/.claude/kannu-agent-status.sh`, entries merged into
///   `~/.claude/settings.json` under the `"hooks"` key.
@MainActor
final class AgentHookInstaller: ObservableObject {
    static let shared = AgentHookInstaller()

    @Published private(set) var installedProviders: Set<AgentHookProvider> = []
    @Published private(set) var lastError: String?

    static let scriptName = "kannu-agent-status.sh"
    private static let scriptVersionMarker = "KANNU_HOOK_SCRIPT_VERSION=23"

    private static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// Shared directory all hooks write status files into.
    static var statusDirectory: URL {
        home.appendingPathComponent(".kannu/agent-status", isDirectory: true)
    }

    // MARK: - Per-provider paths

    static var cursorHooksConfigURL: URL { home.appendingPathComponent(".cursor/hooks.json") }
    static var cursorScriptURL: URL { home.appendingPathComponent(".cursor/hooks/\(scriptName)") }

    static var vscodeHookFileURL: URL { home.appendingPathComponent(".copilot/hooks/kannu-agent-status.json") }
    static var vscodeScriptURL: URL { home.appendingPathComponent(".copilot/\(scriptName)") }

    static var codexHooksConfigURL: URL { home.appendingPathComponent(".codex/hooks.json") }
    static var codexConfigTomlURL: URL { home.appendingPathComponent(".codex/config.toml") }
    static var codexScriptURL: URL { home.appendingPathComponent(".codex/\(scriptName)") }

    static var claudeSettingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    static var claudeScriptURL: URL { home.appendingPathComponent(".claude/\(scriptName)") }

    private init() {
        migrateLegacyStatusDirectoryIfNeeded()
        migrateLegacyCursorInstallIfNeeded()
        migrateLegacyHookScriptsIfNeeded()
        migrateIncorrectAwaitingInputHooksIfNeeded()
        migrateHookScriptVersionIfNeeded()
        migrateCursorHookEventArgumentIfNeeded()
        migrateClaudeStyleHookEventArgumentIfNeeded()
        refresh()
    }

    func isInstalled(_ provider: AgentHookProvider) -> Bool {
        installedProviders.contains(provider)
    }

    func refresh() {
        var result: Set<AgentHookProvider> = []
        for provider in AgentHookProvider.allCases where Self.checkInstalled(provider) {
            result.insert(provider)
        }
        installedProviders = result
    }

    func install(_ provider: AgentHookProvider) {
        lastError = nil
        do {
            try FileManager.default.createDirectory(at: Self.statusDirectory, withIntermediateDirectories: true)
            switch provider {
            case .cursor:
                try Self.writeScript(to: Self.cursorScriptURL)
                try Self.mergeCursorHooksConfig()
            case .vscode:
                try Self.writeScript(to: Self.vscodeScriptURL)
                try Self.writeVSCodeHookFile()
            case .codex:
                try Self.writeScript(to: Self.codexScriptURL)
                try Self.mergeCodexHooksConfig()
                try Self.ensureCodexHooksFeatureEnabled()
            case .claude:
                try Self.writeScript(to: Self.claudeScriptURL)
                try Self.mergeClaudeHooksConfig()
            }
        } catch {
            lastError = "\(provider.displayName): \(error.localizedDescription)"
        }
        refresh()
    }

    func uninstall(_ provider: AgentHookProvider) {
        lastError = nil
        do {
            switch provider {
            case .cursor:
                try Self.stripEntries(configURL: Self.cursorHooksConfigURL)
                try Self.removeIfExists(Self.cursorScriptURL)
            case .vscode:
                try Self.removeIfExists(Self.vscodeHookFileURL)
                try Self.removeIfExists(Self.vscodeScriptURL)
            case .codex:
                try Self.stripEntries(configURL: Self.codexHooksConfigURL)
                try Self.removeIfExists(Self.codexScriptURL)
            case .claude:
                try Self.stripEntries(configURL: Self.claudeSettingsURL)
                try Self.removeIfExists(Self.claudeScriptURL)
            }
        } catch {
            lastError = "\(provider.displayName): \(error.localizedDescription)"
        }
        refresh()
    }

    // MARK: - Event mappings

    /// Cursor hook events (lowerCamelCase) mapped to traffic-light states.
    /// Cursor emits `afterAgentThought` while reasoning and between tool calls, so we map it
    /// to thinking. The script keeps yellow sticky during active approval windows to avoid
    /// repainting green too early.
    private static let cursorEvents: [(event: String, state: String)] = [
        ("beforeSubmitPrompt", "thinking"),
        ("afterAgentThought", "thinking"),
        ("afterAgentResponse", "executing"),
        ("beforeShellExecution", "awaiting_input"),
        ("preToolUse", "executing"),
        ("postToolUse", "executing"),
        ("postToolUseFailure", "executing"),
        ("beforeMCPExecution", "executing"),
        ("stop", "stopped")
    ]

    /// VS Code Copilot / Codex hook events (PascalCase, Claude-compatible).
    private static let claudeStyleEvents: [(event: String, state: String)] = [
        // idle, not thinking: opening a session must not paint the green "running" light
        // (thinking stays visible for activeStaleMs, minutes of false "running").
        ("SessionStart", "idle"),
        ("UserPromptSubmit", "thinking"),
        ("PreToolUse", "executing"),
        ("PostToolUse", "executing"),
        ("PermissionRequest", "awaiting_input"),
        ("Stop", "stopped")
    ]

    // MARK: - Shared script

    private static func writeScript(to url: URL) throws {
        // Tiny bash wrapper + Python writer. Avoid sed JSON extraction — Swift escaping
        // previously corrupted the installed hook and broke all Cursor tool calls.
        let script = """
        #!/bin/bash
        # Installed by Kannu: reports AI agent status for the notch traffic light.
        # \(scriptVersionMarker)
        # Usage: kannu-agent-status.sh <state> <provider> [hook_event]  (hook JSON arrives on stdin)

        export KANNU_STATE="${1:-thinking}"
        export KANNU_PROVIDER="${2:-unknown}"
        export KANNU_HOOK_EVENT="${3:-unknown}"
        export KANNU_STATUS_DIR="$HOME/.kannu/agent-status"
        mkdir -p "$KANNU_STATUS_DIR"
        export KANNU_INPUT="$(cat)"

        if ! command -v python3 >/dev/null 2>&1; then
          TS=$(($(date +%s) * 1000))
          printf '{"state":"%s","ts":%s,"provider":"%s"}' "$KANNU_STATE" "$TS" "$KANNU_PROVIDER" > "$KANNU_STATUS_DIR/$KANNU_PROVIDER-default.json"
          echo '{"permission":"allow","continue":true}'
          exit 0
        fi

        python3 <<'PY'
        import json, os, re, time
        from pathlib import Path

        state = os.environ.get("KANNU_STATE", "thinking")
        provider = os.environ.get("KANNU_PROVIDER", "unknown")
        hook_event = os.environ.get("KANNU_HOOK_EVENT", "unknown")
        status_dir = Path(os.environ.get("KANNU_STATUS_DIR", "")).expanduser()
        raw = os.environ.get("KANNU_INPUT", "")
        status_dir.mkdir(parents=True, exist_ok=True)

        try:
            data = json.loads(raw) if raw.strip() else {}
        except json.JSONDecodeError:
            data = {}

        def pick_str(*values):
            for value in values:
                if isinstance(value, str) and value.strip():
                    return value.strip()
            return ""

        def requires_approval(name: str) -> bool:
            lower = (name or "").lower()
            compact = lower.replace("_", "").replace("-", "").replace(" ", "")
            return compact in {
                "websearch", "webfetch", "search", "askquestion", "userquestion",
                "shell", "runterminalcmd", "bash",
            } or lower in {"web_search", "web_fetch", "ask_question", "run_terminal_cmd"}

        def normalize_token(value: str) -> str:
            return (value or "").strip().lower().replace("_", "").replace("-", "").replace(" ", "")

        TITLE_BEARING_EVENTS = {"beforeSubmitPrompt", "stop", "SessionStart", "UserPromptSubmit", "Stop"}

        tool = pick_str(
            data.get("tool_name"),
            data.get("toolName"),
            data.get("name"),
            data.get("tool") if isinstance(data.get("tool"), str) else None,
        )
        nested_tool = data.get("tool") if isinstance(data.get("tool"), dict) else None
        if nested_tool:
            tool = tool or pick_str(nested_tool.get("name"), nested_tool.get("tool_name"))

        tool_input = data.get("tool_input")
        if tool_input is None:
            tool_input = data.get("input") or data.get("arguments")
            if tool_input is None and nested_tool:
                tool_input = nested_tool.get("input") or nested_tool.get("arguments")
        if not tool and isinstance(tool_input, dict):
            tool = pick_str(tool_input.get("tool_name"), tool_input.get("name"))
            if any(key in tool_input for key in ("search_term", "searchTerm", "query")):
                tool = tool or "WebSearch"
            elif any(key in tool_input for key in ("url", "uri")):
                tool = tool or "WebFetch"
            elif "questions" in tool_input:
                tool = tool or "AskQuestion"
            elif any(key in tool_input for key in ("command", "working_directory", "description")):
                tool = tool or "Shell"

        def is_ask_question() -> bool:
            compact = (tool or "").lower().replace("_", "").replace("-", "")
            if compact in {"askquestion", "userquestion"}:
                return True
            return isinstance(tool_input, dict) and "questions" in tool_input

        def looks_gated_payload(name: str, payload) -> bool:
            if requires_approval(name):
                return True
            if not isinstance(payload, dict):
                return False
            if "questions" in payload:
                return True
            if any(key in payload for key in ("search_term", "searchTerm", "query")):
                return True
            if any(key in payload for key in ("url", "uri")):
                return True
            if any(key in payload for key in ("command", "working_directory")):
                return True
            return False

        # Timing (Cursor):
        # - WebSearch approval card appears BEFORE preToolUse. preToolUse runs after approve.
        # - So WebSearch must NOT set awaiting_input on preToolUse (that paints yellow too late).
        # - afterAgentResponse / transcript catch the proposal while the card is open.
        # - AskQuestion still uses preToolUse for yellow (card is the tool itself).
        if hook_event == "afterAgentResponse":
            if looks_gated_payload(tool, tool_input):
                state = "awaiting_input"
        elif hook_event == "afterAgentThought":
            state = "thinking"
        elif hook_event in {"preToolUse", "beforeMCPExecution", "PreToolUse"}:
            if is_ask_question():
                state = "awaiting_input"
            else:
                # Includes WebSearch/WebFetch/Shell: approval already granted; tool is running.
                state = "executing"
        elif hook_event in {"beforeShellExecution", "PermissionRequest"}:
            state = "awaiting_input"
        elif hook_event in {"postToolUse", "postToolUseFailure", "PostToolUse"}:
            state = "executing"
        elif hook_event in {"stop", "Stop"}:
            state = "stopped"

        conversation_id = pick_str(
            data.get("agentId"),
            data.get("agent_id"),
            data.get("composerId"),
            data.get("composer_id"),
            data.get("conversation_id"),
            data.get("conversationId"),
            data.get("session_id"),
            data.get("sessionId"),
            data.get("thread_id"),
        )
        conversation_id = re.sub(r"[^A-Za-z0-9_-]", "", conversation_id) or "default"
        status_file = status_dir / f"{provider}-{conversation_id}.json"

        existing_state = ""
        existing = {}
        if status_file.exists():
            try:
                existing = json.loads(status_file.read_text())
                existing_state = str(existing.get("state", ""))
            except Exception:
                existing = {}

        roots = data.get("workspace_roots")
        project = ""
        if isinstance(roots, list) and roots:
            root = str(roots[0]).replace("file://", "").rstrip("/")
            if root:
                project = Path(root).name
        project = pick_str(project, existing.get("project"), existing.get("project_name"), existing.get("workspace_name"))

        if hook_event in TITLE_BEARING_EVENTS:
            title = pick_str(
                data.get("conversation_title"),
                data.get("title"),
                data.get("chat_name"),
                data.get("conversation_name"),
                data.get("chatTitle"),
                data.get("bubbleTitle"),
            )
            name = pick_str(title, existing.get("name"), existing.get("title"), existing.get("conversation_title"))
        else:
            name = pick_str(existing.get("name"), existing.get("title"), existing.get("conversation_title"))

        if hook_event in {"preToolUse", "beforeMCPExecution", "postToolUse", "postToolUseFailure", "PreToolUse", "PostToolUse"}:
            if normalize_token(name) == normalize_token(tool):
                name = ""

        # Sticky yellow only against reasoning noise during an open approval card.
        # UserPromptSubmit / SessionStart must clear yellow and enter thinking.
        if existing_state == "awaiting_input" and state not in {"awaiting_input", "stopped"}:
            if hook_event in {"beforeSubmitPrompt", "afterAgentThought"}:
                existing["state"] = "awaiting_input"
                existing["ts"] = int(time.time() * 1000)
                existing["provider"] = provider
                if name:
                    existing["name"] = name
                if project:
                    existing["project"] = project
                status_file.write_text(json.dumps(existing, separators=(",", ":")))
                print('{"permission":"allow","continue":true}')
                raise SystemExit(0)

        payload = {
            "state": state,
            "ts": int(time.time() * 1000),
            "provider": provider,
        }
        if name:
            payload["name"] = name
        if project:
            payload["project"] = project
        status_file.write_text(json.dumps(payload, separators=(",", ":")))
        print('{"permission":"allow","continue":true}')
        PY
        exit 0
        """

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func removeIfExists(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Cursor (~/.cursor/hooks.json, flat entries)

    private static func mergeCursorHooksConfig() throws {
        var config = readJSON(at: cursorHooksConfigURL) ?? [:]
        if config["version"] == nil {
            config["version"] = 1
        }
        var hooks = config["hooks"] as? [String: Any] ?? [:]
        stripCursorEntries(from: &hooks)

        for (event, state) in cursorEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.append(["command": "hooks/\(scriptName) \(state) cursor \(event)"])
            hooks[event] = entries
        }

        config["hooks"] = hooks
        try writeJSON(config, to: cursorHooksConfigURL)
    }

    private static func stripCursorEntries(from hooks: inout [String: Any]) {
        for (event, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll { entry in
                let command = entry["command"] as? String ?? ""
                return command.contains(scriptName) || command.contains("atoll-agent-status")
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }
    }

    // MARK: - VS Code Copilot (~/.copilot/hooks/*.json, own file)

    private static func writeVSCodeHookFile() throws {
        var events: [String: Any] = [:]
        for (event, state) in claudeStyleEvents {
            events[event] = [[
                "type": "command",
                "command": "\(vscodeScriptURL.path) \(state) vscode \(event)",
                "timeout": 10
            ]]
        }
        try writeJSON(["hooks": events], to: vscodeHookFileURL)
    }

    // MARK: - Codex (~/.codex/hooks.json, matcher-group schema)

    private static func mergeCodexHooksConfig() throws {
        var config = readJSON(at: codexHooksConfigURL) ?? [:]
        var hooks = config["hooks"] as? [String: Any] ?? [:]
        stripCodexEntries(from: &hooks)

        for (event, state) in claudeStyleEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append([
                "hooks": [[
                    "type": "command",
                    "command": "\(codexScriptURL.path) \(state) codex \(event)",
                    "timeout": 10
                ]]
            ])
            hooks[event] = groups
        }

        config["hooks"] = hooks
        try writeJSON(config, to: codexHooksConfigURL)
    }

    private static func stripCodexEntries(from hooks: inout [String: Any]) {
        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            groups.removeAll { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
                return handlers.contains { handler in
                    (handler["command"] as? String)?.contains(scriptName) == true
                }
            }
            if groups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = groups
            }
        }
    }

    // MARK: - Claude Code (~/.claude/settings.json, matcher-group schema)

    private static func mergeClaudeHooksConfig() throws {
        var config = readJSON(at: claudeSettingsURL) ?? [:]
        var hooks = config["hooks"] as? [String: Any] ?? [:]
        stripClaudeEntries(from: &hooks)

        for (event, state) in claudeStyleEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append([
                "hooks": [[
                    "type": "command",
                    "command": "\(claudeScriptURL.path) \(state) claude \(event)",
                    "timeout": 10
                ]]
            ])
            hooks[event] = groups
        }

        config["hooks"] = hooks
        try writeJSON(config, to: claudeSettingsURL)
    }

    private static func stripClaudeEntries(from hooks: inout [String: Any]) {
        stripCodexEntries(from: &hooks)
    }

    /// Codex only runs hooks.json when `features.hooks = true` is set in
    /// `~/.codex/config.toml`. Enables the flag with minimal text edits so the
    /// rest of the user's TOML is left untouched.
    private static func ensureCodexHooksFeatureEnabled() throws {
        var text = (try? String(contentsOf: codexConfigTomlURL, encoding: .utf8)) ?? ""

        if text.range(of: #"(?m)^\s*features\.hooks\s*=\s*true\b"#, options: .regularExpression) != nil {
            return
        }
        if let dottedFalse = text.range(of: #"(?m)^\s*features\.hooks\s*=\s*false\b"#, options: .regularExpression) {
            text.replaceSubrange(
                dottedFalse,
                with: text[dottedFalse].replacingOccurrences(of: "false", with: "true")
            )
            try writeToml(text)
            return
        }

        if let sectionRange = text.range(of: #"(?m)^\[features\][^\[]*"#, options: .regularExpression) {
            let section = String(text[sectionRange])
            if section.range(of: #"(?m)^\s*hooks\s*=\s*true\b"#, options: .regularExpression) != nil {
                return
            }
            if let falseRange = section.range(of: #"(?m)^\s*hooks\s*=\s*false\b"#, options: .regularExpression) {
                var updatedSection = section
                updatedSection.replaceSubrange(
                    falseRange,
                    with: section[falseRange].replacingOccurrences(of: "false", with: "true")
                )
                text.replaceSubrange(sectionRange, with: updatedSection)
            } else if let headerEnd = text.range(of: #"(?m)^\[features\][^\n]*\n?"#, options: .regularExpression) {
                text.insert(contentsOf: "hooks = true\n", at: headerEnd.upperBound)
            }
            try writeToml(text)
            return
        }

        if !text.isEmpty && !text.hasSuffix("\n") {
            text += "\n"
        }
        text += "\n[features]\nhooks = true\n"
        try writeToml(text)
    }

    private static func writeToml(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: codexConfigTomlURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: codexConfigTomlURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Install detection

    private static func checkInstalled(_ provider: AgentHookProvider) -> Bool {
        switch provider {
        case .cursor:
            guard FileManager.default.fileExists(atPath: cursorScriptURL.path),
                  let config = readJSON(at: cursorHooksConfigURL),
                  let hooks = config["hooks"] as? [String: Any] else { return false }
            return cursorEvents.allSatisfy { event, _ in
                guard let entries = hooks[event] as? [[String: Any]] else { return false }
                return entries.contains { (($0["command"] as? String)?.contains(scriptName)) == true }
            }
        case .vscode:
            return FileManager.default.fileExists(atPath: vscodeHookFileURL.path)
                && FileManager.default.fileExists(atPath: vscodeScriptURL.path)
        case .codex:
            guard FileManager.default.fileExists(atPath: codexScriptURL.path),
                  let config = readJSON(at: codexHooksConfigURL),
                  let hooks = config["hooks"] as? [String: Any] else { return false }
            return claudeStyleEvents.allSatisfy { event, _ in
                guard let groups = hooks[event] as? [[String: Any]] else { return false }
                return groups.contains { group in
                    guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
                    return handlers.contains { (($0["command"] as? String)?.contains(scriptName)) == true }
                }
            }
        case .claude:
            guard FileManager.default.fileExists(atPath: claudeScriptURL.path),
                  let config = readJSON(at: claudeSettingsURL),
                  let hooks = config["hooks"] as? [String: Any] else { return false }
            return claudeStyleEvents.allSatisfy { event, _ in
                guard let groups = hooks[event] as? [[String: Any]] else { return false }
                return groups.contains { group in
                    guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
                    return handlers.contains { (($0["command"] as? String)?.contains(scriptName)) == true }
                }
            }
        }
    }

    private static func stripEntries(configURL: URL) throws {
        guard var config = readJSON(at: configURL),
              var hooks = config["hooks"] as? [String: Any] else { return }
        if configURL == codexHooksConfigURL || configURL == claudeSettingsURL {
            stripCodexEntries(from: &hooks)
        } else {
            stripCursorEntries(from: &hooks)
        }
        config["hooks"] = hooks
        try writeJSON(config, to: configURL)
    }

    // MARK: - Legacy migration

    /// Rewrites Cursor hooks that incorrectly mapped pre-tool events to awaiting_input.
    private func migrateIncorrectAwaitingInputHooksIfNeeded() {
        guard Self.checkInstalled(.cursor),
              let config = Self.readJSON(at: Self.cursorHooksConfigURL),
              let hooks = config["hooks"] as? [String: Any] else { return }

        let staleEvents = ["beforeMCPExecution", "beforeReadFile"]
        let hasStaleAwaitingHooks = staleEvents.contains { event in
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            return entries.contains { ($0["command"] as? String)?.contains("awaiting_input") == true }
        }

        guard hasStaleAwaitingHooks else { return }
        install(.cursor)
    }

    /// Reinstalls hooks when the shared status script gains new approval-detection logic.
    private func migrateHookScriptVersionIfNeeded() {
        let scriptURLs = [
            Self.cursorScriptURL,
            Self.vscodeScriptURL,
            Self.codexScriptURL,
            Self.claudeScriptURL
        ]
        let needsRefresh = scriptURLs.contains { url in
            guard FileManager.default.fileExists(atPath: url.path),
                  let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return !content.contains(Self.scriptVersionMarker)
        }
        guard needsRefresh else { return }
        for provider in AgentHookProvider.allCases where Self.checkInstalled(provider) {
            install(provider)
        }
    }

    /// Upgrades Cursor hook commands that omit the hook event argument (v6 sticky awaiting_input).
    private func migrateCursorHookEventArgumentIfNeeded() {
        guard Self.checkInstalled(.cursor),
              let config = Self.readJSON(at: Self.cursorHooksConfigURL),
              let hooks = config["hooks"] as? [String: Any] else { return }

        let needsEventArg = hooks.contains { _, value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains { entry in
                let command = entry["command"] as? String ?? ""
                guard command.contains(Self.scriptName) else { return false }
                return command.split(separator: " ").count < 4
            }
        }

        guard needsEventArg else { return }
        install(.cursor)
    }

    /// Upgrades VS Code/Codex/Claude hook commands that omit the hook event argument.
    private func migrateClaudeStyleHookEventArgumentIfNeeded() {
        for provider in [AgentHookProvider.vscode, .codex, .claude] {
            guard Self.checkInstalled(provider) else { continue }
            let configURL: URL
            switch provider {
            case .vscode:
                guard let config = Self.readJSON(at: Self.vscodeHookFileURL),
                      let hooks = config["hooks"] as? [String: Any] else { continue }
                let needsEventArg = hooks.contains { _, value in
                    guard let handlers = value as? [[String: Any]] else { return false }
                    return handlers.contains { handler in
                        let command = handler["command"] as? String ?? ""
                        guard command.contains(Self.scriptName) else { return false }
                        return command.split(separator: " ").count < 4
                    }
                }
                guard needsEventArg else { continue }
                install(provider)
                continue
            case .codex:
                configURL = Self.codexHooksConfigURL
            case .claude:
                configURL = Self.claudeSettingsURL
            default:
                continue
            }

            guard let config = Self.readJSON(at: configURL),
                  let hooks = config["hooks"] as? [String: Any] else { continue }
            let needsEventArg = hooks.contains { _, value in
                guard let groups = value as? [[String: Any]] else { return false }
                return groups.contains { group in
                    guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
                    return handlers.contains { handler in
                        let command = handler["command"] as? String ?? ""
                        guard command.contains(Self.scriptName) else { return false }
                        return command.split(separator: " ").count < 4
                    }
                }
            }
            guard needsEventArg else { continue }
            install(provider)
        }
    }

    /// Copies status JSON from older `~/.atoll/agent-status` into `~/.kannu/agent-status`.
    private func migrateLegacyStatusDirectoryIfNeeded() {
        let legacy = Self.home.appendingPathComponent(".atoll/agent-status", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        try? FileManager.default.createDirectory(at: Self.statusDirectory, withIntermediateDirectories: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            let destination = Self.statusDirectory.appendingPathComponent(file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.copyItem(at: file, to: destination)
            }
        }
    }

    /// Reinstalls hooks that still reference legacy script names or status paths.
    private func migrateLegacyHookScriptsIfNeeded() {
        let legacyMarkers = ["atoll-agent-status", ".atoll/agent-status", ".cursor/atoll/agent-status"]
        for provider in AgentHookProvider.allCases {
            let scriptURL: URL
            switch provider {
            case .cursor: scriptURL = Self.cursorScriptURL
            case .vscode: scriptURL = Self.vscodeScriptURL
            case .codex: scriptURL = Self.codexScriptURL
            case .claude: scriptURL = Self.claudeScriptURL
            }
            guard FileManager.default.fileExists(atPath: scriptURL.path),
                  let content = try? String(contentsOf: scriptURL, encoding: .utf8),
                  legacyMarkers.contains(where: { content.contains($0) }) else { continue }
            install(provider)
        }
    }

    /// Earlier builds installed a Cursor-only hook whose script wrote into
    /// `~/.cursor/atoll/agent-status`. Rewrites it to the shared layout.
    private func migrateLegacyCursorInstallIfNeeded() {
        let scriptPath = Self.cursorScriptURL.path
        guard FileManager.default.fileExists(atPath: scriptPath),
              let content = try? String(contentsOfFile: scriptPath, encoding: .utf8),
              content.contains(".cursor/atoll/agent-status") else { return }
        install(.cursor)
        try? FileManager.default.removeItem(
            at: Self.home.appendingPathComponent(".cursor/atoll", isDirectory: true)
        )
    }

    // MARK: - JSON helpers

    private static func readJSON(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
