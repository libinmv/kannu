import Foundation

enum AgentHookProvider: String, CaseIterable, Identifiable {
    case cursor
    case vscode
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .vscode: return "VS Code (Copilot)"
        case .codex: return "Codex CLI"
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
@MainActor
final class AgentHookInstaller: ObservableObject {
    static let shared = AgentHookInstaller()

    @Published private(set) var installedProviders: Set<AgentHookProvider> = []
    @Published private(set) var lastError: String?

    static let scriptName = "kannu-agent-status.sh"
    private static let scriptVersionMarker = "KANNU_HOOK_SCRIPT_VERSION=4"

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

    private init() {
        migrateLegacyStatusDirectoryIfNeeded()
        migrateLegacyCursorInstallIfNeeded()
        migrateLegacyHookScriptsIfNeeded()
        migrateIncorrectAwaitingInputHooksIfNeeded()
        migrateHookScriptVersionIfNeeded()
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
            }
        } catch {
            lastError = "\(provider.displayName): \(error.localizedDescription)"
        }
        refresh()
    }

    // MARK: - Event mappings

    /// Cursor hook events (lowerCamelCase) mapped to traffic-light states.
    private static let cursorEvents: [(event: String, state: String)] = [
        ("beforeSubmitPrompt", "thinking"),
        ("afterAgentThought", "thinking"),
        ("preToolUse", "executing"),
        ("postToolUse", "executing"),
        ("beforeMCPExecution", "executing"),
        ("stop", "stopped")
    ]

    /// VS Code Copilot / Codex hook events (PascalCase, Claude-compatible).
    private static let claudeStyleEvents: [(event: String, state: String)] = [
        ("SessionStart", "thinking"),
        ("UserPromptSubmit", "thinking"),
        ("PreToolUse", "executing"),
        ("PostToolUse", "executing"),
        ("PermissionRequest", "awaiting_input"),
        ("Stop", "stopped")
    ]

    // MARK: - Shared script

    private static func writeScript(to url: URL) throws {
        let script = """
        #!/bin/bash
        # Installed by Kannu: reports AI agent status for the notch traffic light.
        # \(scriptVersionMarker)
        # Usage: kannu-agent-status.sh <state> <provider>  (hook JSON arrives on stdin)

        STATE="${1:-thinking}"
        PROVIDER="${2:-unknown}"
        STATUS_DIR="$HOME/.kannu/agent-status"
        mkdir -p "$STATUS_DIR"

        INPUT=$(cat)

        resolve_state() {
          KANNU_STATE="$1" INPUT="$INPUT" python3 <<'PY'
        import json, os

        state = os.environ.get("KANNU_STATE", "thinking")
        raw = os.environ.get("INPUT", "")
        try:
            data = json.loads(raw) if raw.strip() else {}
        except json.JSONDecodeError:
            print(state)
            raise SystemExit

        tool = (data.get("tool_name") or data.get("toolName") or data.get("name") or "").strip()
        if not tool and isinstance(data.get("tool"), str):
            tool = data["tool"].strip()
        if not tool and isinstance(data.get("tool_input"), dict):
            tool = str(data["tool_input"].get("tool_name") or data["tool_input"].get("name") or "").strip()
        if not tool and isinstance(data.get("tool_input"), str):
            try:
                nested = json.loads(data["tool_input"])
                if isinstance(nested, dict):
                    tool = str(nested.get("tool_name") or nested.get("name") or "").strip()
            except json.JSONDecodeError:
                pass

        def requires_approval(name: str) -> bool:
            lower = name.lower()
            compact = lower.replace("_", "").replace("-", "")
            if lower in {"websearch", "webfetch", "web_search", "web_fetch", "search"}:
                return True
            return compact in {"websearch", "webfetch", "search"}

        if state == "executing" and requires_approval(tool):
            state = "awaiting_input"

        print(state)
        PY
        }

        if command -v python3 >/dev/null 2>&1; then
          STATE="$(resolve_state "$STATE")"
        fi

        extract() {
          printf '%s' "$INPUT" | sed -n "s/.*\\"$1\\"[[:space:]]*:[[:space:]]*\\"\\([^\\"]*\\)\\".*/\\1/p" | head -n 1
        }
        extract_workspace_root() {
          printf '%s' "$INPUT" | sed -n 's/.*"workspace_roots"[[:space:]]*:[[:space:]]*\\[[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -n 1
        }
        ID=$(extract conversation_id)
        [ -z "$ID" ] && ID=$(extract conversationId)
        [ -z "$ID" ] && ID=$(extract session_id)
        [ -z "$ID" ] && ID=$(extract sessionId)
        [ -z "$ID" ] && ID=$(extract thread_id)
        ID=$(printf '%s' "$ID" | tr -cd 'A-Za-z0-9_-')
        [ -z "$ID" ] && ID="default"

        NAME=$(extract name)
        [ -z "$NAME" ] && NAME=$(extract title)
        [ -z "$NAME" ] && NAME=$(extract conversation_title)
        NAME=$(printf '%s' "$NAME" | tr -d '\\n\\r')
        NAME=$(printf '%s' "$NAME" | sed 's/"/\\\\"/g')

        WORKSPACE_ROOT=$(extract_workspace_root)
        WORKSPACE_ROOT=$(printf '%s' "$WORKSPACE_ROOT" | sed 's#^file://##')
        PROJECT=""
        if [ -n "$WORKSPACE_ROOT" ]; then
          PROJECT=$(basename "$WORKSPACE_ROOT")
        fi
        PROJECT=$(printf '%s' "$PROJECT" | tr -d '\\n\\r')
        PROJECT=$(printf '%s' "$PROJECT" | sed 's/"/\\\\"/g')

        TS=$(($(date +%s) * 1000))
        if [ -n "$NAME" ] && [ -n "$PROJECT" ]; then
          printf '{"state":"%s","ts":%s,"provider":"%s","name":"%s","project":"%s"}' "$STATE" "$TS" "$PROVIDER" "$NAME" "$PROJECT" > "$STATUS_DIR/$PROVIDER-$ID.json"
        elif [ -n "$NAME" ]; then
          printf '{"state":"%s","ts":%s,"provider":"%s","name":"%s"}' "$STATE" "$TS" "$PROVIDER" "$NAME" > "$STATUS_DIR/$PROVIDER-$ID.json"
        elif [ -n "$PROJECT" ]; then
          printf '{"state":"%s","ts":%s,"provider":"%s","project":"%s"}' "$STATE" "$TS" "$PROVIDER" "$PROJECT" > "$STATUS_DIR/$PROVIDER-$ID.json"
        else
          printf '{"state":"%s","ts":%s,"provider":"%s"}' "$STATE" "$TS" "$PROVIDER" > "$STATUS_DIR/$PROVIDER-$ID.json"
        fi

        # Never block the agent: always allow gating events.
        echo '{"permission":"allow","continue":true}'
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
            entries.append(["command": "hooks/\(scriptName) \(state) cursor"])
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
                "command": "\(vscodeScriptURL.path) \(state) vscode",
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
                    "command": "\(codexScriptURL.path) \(state) codex",
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
        }
    }

    private static func stripEntries(configURL: URL) throws {
        guard var config = readJSON(at: configURL),
              var hooks = config["hooks"] as? [String: Any] else { return }
        if configURL == codexHooksConfigURL {
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

        let staleEvents = ["beforeShellExecution", "beforeMCPExecution", "beforeReadFile"]
        let hasStaleAwaitingHooks = staleEvents.contains { event in
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            return entries.contains { ($0["command"] as? String)?.contains("awaiting_input") == true }
        }

        guard hasStaleAwaitingHooks else { return }
        install(.cursor)
    }

    /// Reinstalls hooks when the shared status script gains new approval-detection logic.
    private func migrateHookScriptVersionIfNeeded() {
        let scriptURLs = [Self.cursorScriptURL, Self.vscodeScriptURL, Self.codexScriptURL]
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
