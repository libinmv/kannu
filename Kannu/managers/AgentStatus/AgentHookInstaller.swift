import Foundation
import os

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
/// - Antigravity: script `~/.gemini/antigravity-ide/kannu-agent-status.sh`,
///   entries merged into `~/.gemini/antigravity-ide/hooks.json`.
@MainActor
final class AgentHookInstaller: ObservableObject {
    static let shared = AgentHookInstaller()

    @Published private(set) var installedProviders: Set<AgentHookProvider> = []
    @Published private(set) var lastError: String?

    private static let logger = os.Logger(subsystem: "com.kannu.app", category: "AgentHookInstaller")

    static let scriptName = "kannu-agent-status.sh"
    private static let scriptVersionMarker = "KANNU_HOOK_SCRIPT_VERSION=29"

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

    static var antigravityHooksConfigURL: URL { home.appendingPathComponent(".gemini/antigravity-ide/hooks.json") }
    static var antigravityConfigHooksURL: URL { home.appendingPathComponent(".gemini/config/hooks.json") }
    static var antigravityRootHooksURL: URL { home.appendingPathComponent(".gemini/hooks.json") }
    static var antigravityScriptURL: URL { home.appendingPathComponent(".gemini/antigravity-ide/\(scriptName)") }

    static func scriptURL(for provider: AgentHookProvider) -> URL {
        switch provider {
        case .cursor: return cursorScriptURL
        case .vscode: return vscodeScriptURL
        case .codex: return codexScriptURL
        case .claude: return claudeScriptURL
        case .antigravity: return antigravityScriptURL
        }
    }

    private init() {
        migrateLegacyStatusDirectoryIfNeeded()
        migrateLegacyCursorInstallIfNeeded()
        migrateLegacyHookScriptsIfNeeded()
        migrateIncorrectAwaitingInputHooksIfNeeded()
        migrateHookScriptVersionIfNeeded()
        migrateClaudeNotificationHooksIfNeeded()
        migrateCursorHookEventArgumentIfNeeded()
        migrateClaudeStyleHookEventArgumentIfNeeded()
        migrateClaudeUsageStatusLineIfNeeded()
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
            try FileManager.default.createDirectory(
                at: Self.statusDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
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
                try Self.installClaudeUsageStatusLine()
            case .antigravity:
                try Self.writeScript(to: Self.antigravityScriptURL)
                try Self.mergeAntigravityHooksConfig()
            }
        } catch {
            lastError = "\(provider.displayName): \(error.localizedDescription)"
            Self.logger.error("hook install failed: \(self.lastError ?? "?", privacy: .public)")
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
                try Self.stripClaudeUsageStatusLine()
            case .antigravity:
                // Install merges into every location that exists, so uninstall has to clear
                // all of them — stripping only the IDE path left orphaned entries pointing at
                // a script we just deleted.
                try Self.stripEntries(configURL: Self.antigravityHooksConfigURL)
                try? Self.stripEntries(configURL: Self.antigravityConfigHooksURL)
                try? Self.stripEntries(configURL: Self.antigravityRootHooksURL)
                try Self.removeIfExists(Self.antigravityScriptURL)
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
        // Fires for every shell command, including auto-approved ones — so it cannot mean
        // "waiting for you". Genuine approvals still surface via afterAgentResponse's
        // gated-payload check and via the transcript.
        ("beforeShellExecution", "executing"),
        ("preToolUse", "executing"),
        ("postToolUse", "thinking"),
        ("postToolUseFailure", "thinking"),
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
        ("PostToolUse", "thinking"),
        ("PermissionRequest", "awaiting_input"),
        ("Stop", "stopped")
    ]

    /// Claude Code hook coverage. Richer than `claudeStyleEvents` because Claude supports
    /// matcher-scoped groups, which is the only way to reach the states that matter:
    /// `Notification/agent_completed` is the real "it's done", and matching `PreToolUse` on
    /// the plan-approval tools is the only signal for "waiting on you to approve a plan".
    ///
    /// `matcherKey` is a short token handed to the script so it knows the state is already
    /// unambiguous and does not re-derive it from the event name.
    private static let claudeHookEntries: [(event: String, matcher: String?, matcherKey: String, state: String)] = [
        // idle, not thinking: opening a session must not paint the green "running" light.
        ("SessionStart", nil, "", "idle"),
        ("UserPromptSubmit", nil, "", "thinking"),
        // Must come before the generic PreToolUse entry for readability; Claude runs matcher
        // groups in parallel with no ordering guarantee, so the script also derives this
        // state from tool_name as a backstop.
        ("PreToolUse", "ExitPlanMode|AskUserQuestion", "gated", "awaiting_input"),
        ("PreToolUse", nil, "", "executing"),
        // `thinking`, matching what the script derives for this event and what
        // `claudeStyleEvents` passes. The argument is only a fallback for the no-python
        // branch, but a value the script contradicts is a trap for the next reader.
        ("PostToolUse", nil, "", "thinking"),
        ("PermissionRequest", nil, "", "awaiting_input"),
        ("Notification", "agent_completed", "completed", "stopped"),
        ("Notification", "permission_prompt|idle_prompt|agent_needs_input", "needs_input", "awaiting_input"),
        ("Stop", nil, "", "stopped"),
        ("StopFailure", nil, "", "stopped"),
        ("SessionEnd", nil, "", "session_end")
    ]

    /// The subset that defines "Claude hooks are installed". Kept intentionally small so the
    /// table above can grow without invalidating existing installs — see `checkInstalled`.
    private static let claudeCoreInstalledEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "Stop"]

    /// Antigravity hook events (PascalCase).
    private static let antigravityEvents: [(event: String, state: String)] = [
        ("SessionStart", "idle"),
        ("UserPromptSubmit", "thinking"),
        ("PreInvocation", "thinking"),
        ("PostInvocation", "thinking"),
        ("PreToolUse", "executing"),
        ("PostToolUse", "thinking"),
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
        # Usage: kannu-agent-status.sh <state> <provider> [hook_event] [matcher_key]
        #        (hook JSON arrives on stdin)

        export KANNU_STATE="${1:-thinking}"
        export KANNU_PROVIDER="${2:-unknown}"
        export KANNU_HOOK_EVENT="${3:-unknown}"
        export KANNU_HOOK_MATCHER="${4:-}"
        export KANNU_STATUS_DIR="$HOME/.kannu/agent-status"
        # 700: the files carry session titles and project names, and Kannu trusts their
        # contents to drive the traffic light — no reason for other users to see them.
        mkdir -p "$KANNU_STATUS_DIR" && chmod 700 "$KANNU_STATUS_DIR"
        export KANNU_INPUT="$(cat)"

        if ! command -v python3 >/dev/null 2>&1; then
          TS=$(($(date +%s) * 1000))
          printf '{"state":"%s","ts":%s,"provider":"%s"}' "$KANNU_STATE" "$TS" "$KANNU_PROVIDER" > "$KANNU_STATUS_DIR/$KANNU_PROVIDER-default.json"
          echo '{"permission":"allow","continue":true}'
          exit 0
        fi

        python3 <<'PY'
        import fcntl, json, os, re, tempfile, time
        from pathlib import Path

        def write_status(path, obj):
            # Truncate-then-write leaves the file empty for a moment, and Kannu reads it on
            # every FSEvent — a torn read drops the session card for that scan. Write a temp
            # file in the same directory and rename it over: on the same filesystem os.replace
            # is atomic, so a reader sees either the old document or the new one, never half.
            fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".kannu-", suffix=".tmp")
            try:
                with os.fdopen(fd, "w") as fh:
                    json.dump(obj, fh, separators=(",", ":"))
                    fh.flush()
                    os.fsync(fh.fileno())
                os.replace(tmp, str(path))
            except Exception:
                try:
                    os.unlink(tmp)
                except Exception:
                    pass
                raise

        state = os.environ.get("KANNU_STATE", "thinking")
        provider = os.environ.get("KANNU_PROVIDER", "unknown")
        hook_event = os.environ.get("KANNU_HOOK_EVENT", "unknown")
        hook_matcher = os.environ.get("KANNU_HOOK_MATCHER", "")
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

        TITLE_BEARING_EVENTS = {"beforeSubmitPrompt", "stop", "SessionStart", "UserPromptSubmit", "Stop", "PreInvocation"}

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

        def is_approval_gated_tool() -> bool:
            # ExitPlanMode means "here is the plan, approve it" — a wait on the user, not work.
            # Claude fires the matcher-scoped and generic PreToolUse groups in parallel with no
            # ordering guarantee, so the generic group has to reach the same verdict on its own.
            compact = (tool or "").lower().replace("_", "").replace("-", "")
            if compact in {"askquestion", "userquestion", "askuserquestion", "exitplanmode"}:
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
        if hook_matcher:
            # Matcher-scoped group: the installer already picked the right state for exactly
            # this case, so trust the argument rather than re-deriving from the event name.
            pass
        elif hook_event == "afterAgentResponse":
            if looks_gated_payload(tool, tool_input):
                state = "awaiting_input"
        elif hook_event in {"afterAgentThought", "PreInvocation"}:
            state = "thinking"
        elif hook_event in {"preToolUse", "beforeMCPExecution", "PreToolUse"}:
            if is_approval_gated_tool():
                state = "awaiting_input"
            else:
                # Includes WebSearch/WebFetch/Shell: approval already granted; tool is running.
                state = "executing"
        elif hook_event in {"beforeShellExecution"}:
            # Fires for auto-approved commands too, so it means "running", not "waiting".
            state = "executing"
        elif hook_event in {"PermissionRequest"}:
            state = "awaiting_input"
        elif hook_event in {"postToolUse", "postToolUseFailure", "PostToolUse", "PostInvocation"}:
            state = "thinking"
        elif hook_event in {"stop", "Stop", "StopFailure"}:
            state = "stopped"
            # Antigravity's Stop payload carries terminationReason/error instead of a
            # separate "quota exceeded" event — there's no other signal that a run ended
            # because the account hit a rate limit rather than finishing normally. Surface
            # it as a distinct raw state string (not a new AgentTrafficLightState case: an
            # unrecognized raw state already falls back to the same stopped/inactive-by-age
            # lifecycle in resolveHookState, so this is purely additive) so the Usage-tab
            # card and chat-name label can show it instead of a generic "stopped".
            if provider == "antigravity" and hook_event == "Stop":
                termination_reason = pick_str(data.get("terminationReason"), data.get("termination_reason"))
                stop_error = pick_str(data.get("error"))
                quota_signal = (termination_reason + " " + stop_error).lower()
                if any(marker in quota_signal for marker in ("quota", "rate_limit", "rate limit", "resource_exhausted")):
                    state = "quota_exceeded"
        elif hook_event == "SessionEnd":
            state = "session_end"

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
        # Cap the id: session ids are UUID-sized in practice, and an oversized hostile id
        # would push the status/lock paths past NAME_MAX — the resulting os.replace failure
        # kills the hook before it prints its allow JSON, which for permission-shaped hooks
        # is undefined behaviour in the host tool.
        conversation_id = conversation_id[:64]
        status_file = status_dir / f"{provider}-{conversation_id}.json"

        # Claude runs the matcher-scoped and generic hook groups for one event as separate
        # processes, in parallel, with no ordering guarantee. The STATE_PRIORITY merge below
        # compares against what is on disk, so without a lock both processes read the same
        # pre-race value, each finds nothing to preserve, and whichever writes second wins
        # outright — the exact downgrade (yellow "needs you" overwritten by green "running")
        # that the merge exists to prevent. Serialise the whole read-modify-write instead.
        #
        # The lock is advisory and per-conversation, held until this process exits, so it
        # cannot deadlock a hook for a different session. If flock is unavailable or the
        # wait fails we proceed unlocked: a possible lost update beats a hung hook, which
        # would stall the agent itself.
        try:
            _lock_fh = open(status_dir / f".{provider}-{conversation_id}.lock", "w")
            fcntl.flock(_lock_fh.fileno(), fcntl.LOCK_EX)
        except Exception:
            _lock_fh = None

        # SessionStart also fires for /compact and /resume, which happen mid-conversation —
        # writing "idle" there dims (or with the stopped-indicator on, reddens) a session that
        # is actively working. Only a genuine startup should seed the idle card.
        if hook_event == "SessionStart" and str(data.get("source", "")) in {"compact", "resume"}:
            print('{"permission":"allow","continue":true}')
            raise SystemExit(0)

        # The session is gone: drop the card outright rather than leaving a terminal state to
        # age out. Passive detection cannot resurrect it because the process has exited too.
        if state == "session_end":
            try:
                status_file.unlink()
            except Exception:
                pass
            # Otherwise one zero-byte lock file per conversation accumulates forever. Safe to
            # remove while we hold it: flock lives on the open descriptor, not the directory
            # entry, and the session is over so nothing else will contend for this one.
            try:
                (status_dir / f".{provider}-{conversation_id}.lock").unlink()
            except Exception:
                pass
            print('{"permission":"allow","continue":true}')
            raise SystemExit(0)

        existing_state = ""
        existing = {}
        if status_file.exists():
            try:
                existing = json.loads(status_file.read_text())
                existing_state = str(existing.get("state", ""))
            except Exception:
                existing = {}

        # Claude runs the matcher-scoped and generic groups for one event in parallel with no
        # ordering guarantee. If both land within the same instant, keep the more urgent verdict
        # so the winner of the race cannot silently downgrade the light.
        STATE_PRIORITY = {"quota_exceeded": 50, "awaiting_input": 40, "stopped": 30, "executing": 20, "thinking": 10, "idle": 0}
        preserved_ts = None
        if existing_state and existing.get("hook_event") == hook_event:
            _raw_ts = existing.get("ts")
            # A status file is untrusted input (any same-user process can write it). `or 0`
            # only defaults falsy values, so a truthy non-numeric ts reached the subtraction
            # below and raised TypeError -- which killed the hook before it printed its allow
            # JSON, leaving the host tool with empty stdout and exit 0.
            existing_ts_ms = _raw_ts if isinstance(_raw_ts, (int, float)) and not isinstance(_raw_ts, bool) else 0
            if int(time.time() * 1000) - existing_ts_ms <= 2000:
                if STATE_PRIORITY.get(existing_state, -1) > STATE_PRIORITY.get(state, -1):
                    state = existing_state
                    # Keep the original clock. Refreshing ts here made the 2s window
                    # self-renewing: chained tool calls arriving <2s apart re-latched the
                    # kept state forever instead of resolving one parallel-group race.
                    preserved_ts = existing_ts_ms

        roots = data.get("workspace_roots") or data.get("workspacePaths") or data.get("workspace_paths")
        project = ""
        workdir = ""
        if isinstance(roots, list) and roots:
            root = str(roots[0]).replace("file://", "").rstrip("/")
            if root:
                project = Path(root).name
                workdir = root
        if not project:
            # Claude Code sends cwd rather than workspace_roots; without this the card has no
            # project name until passive transcript detection can supply one.
            cwd = pick_str(data.get("cwd"))
            if cwd:
                cleaned = cwd.replace("file://", "").rstrip("/")
                project = Path(cleaned).name
                workdir = cleaned
        project = pick_str(project, existing.get("project"), existing.get("project_name"), existing.get("workspace_name"))
        # Full path, not just the basename: click-through in the notch needs it to open the
        # right project window. Falls back to what an earlier event stored — most hook events
        # carry cwd, but a matcher-only event might not.
        workdir = pick_str(workdir, existing.get("cwd"))

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

        if state == "quota_exceeded":
            name = "Quota exceeded"  # more useful than whatever chat title was already cached

        if hook_event in {"preToolUse", "beforeMCPExecution", "postToolUse", "postToolUseFailure", "PreToolUse", "PostToolUse"}:
            if normalize_token(name) == normalize_token(tool):
                name = ""

        # Sticky yellow holds the light steady against reasoning noise while an approval card
        # is genuinely open. Two rules keep it from latching forever:
        #   - only afterAgentThought is absorbed. beforeSubmitPrompt is Cursor's new-prompt
        #     event, so it must clear yellow rather than renew it.
        #   - the original ts is preserved, so the 5-minute staleness escape can still fire.
        #     Refreshing it here is what let yellow survive an entire thinking phase.
        if existing_state == "awaiting_input" and state not in {"awaiting_input", "stopped"}:
            if hook_event == "afterAgentThought":
                _raw_sticky_ts = existing.get("ts")
                # Same untrusted-input coercion as the priority merge above.
                existing_ts = _raw_sticky_ts if isinstance(_raw_sticky_ts, (int, float)) and not isinstance(_raw_sticky_ts, bool) else 0
                if int(time.time() * 1000) - existing_ts <= 300000:
                    existing["provider"] = provider
                    if name:
                        existing["name"] = name
                    if project:
                        existing["project"] = project
                    if workdir:
                        existing["cwd"] = workdir
                    write_status(status_file, existing)
                    print('{"permission":"allow","continue":true}')
                    raise SystemExit(0)

        payload = {
            "state": state,
            "ts": preserved_ts or int(time.time() * 1000),
            "provider": provider,
            "hook_event": hook_event,
        }
        if name:
            payload["name"] = name
        if project:
            payload["project"] = project
        if workdir:
            payload["cwd"] = workdir
        write_status(status_file, payload)
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
        var config = try readJSONForMerge(at: cursorHooksConfigURL)
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
        var config = try readJSONForMerge(at: codexHooksConfigURL)
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
        var config = try readJSONForMerge(at: claudeSettingsURL)
        var hooks = config["hooks"] as? [String: Any] ?? [:]
        stripClaudeEntries(from: &hooks)

        for entry in claudeHookEntries {
            var groups = hooks[entry.event] as? [[String: Any]] ?? []
            // The matcher is passed to the script too: when a group is matcher-scoped its state
            // is unambiguous, so the script trusts the argument instead of re-deriving it.
            let matcherArg = entry.matcher == nil ? "" : " \(entry.matcherKey)"
            var group: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": "\(claudeScriptURL.path) \(entry.state) claude \(entry.event)\(matcherArg)",
                    "timeout": 10
                ]]
            ]
            if let matcher = entry.matcher {
                group["matcher"] = matcher
            }
            groups.append(group)
            hooks[entry.event] = groups
        }

        config["hooks"] = hooks
        try writeJSON(config, to: claudeSettingsURL)
    }

    private static func stripClaudeEntries(from hooks: inout [String: Any]) {
        stripCodexEntries(from: &hooks)
    }

    // MARK: - Antigravity (~/.gemini/antigravity-ide/hooks.json, matcher-group schema)

    private static func mergeAntigravityHooksConfig() throws {
        // Antigravity reads whichever of these locations exists, so all three may need our
        // entries — but each must be merged into its OWN content. Building the document from
        // the IDE config and writing that same document to the other two destroyed whatever
        // hooks the user had defined in them.
        // Documented global location first (antigravity.google/docs/hooks lists
        // ~/.gemini/config/hooks.json), then the IDE-specific and legacy root paths.
        let targets = [antigravityConfigHooksURL, antigravityHooksConfigURL, antigravityRootHooksURL]
        var primaryError: Error?

        for target in targets {
            // The documented path is authoritative and always written. The others are only
            // updated when they already exist — creating them would scatter config the user
            // never asked for, and uninstall only strips what it finds.
            let isPrimary = target == antigravityConfigHooksURL
            guard isPrimary || FileManager.default.fileExists(atPath: target.path) else { continue }

            // Match the write-side policy below: a broken non-primary file is skipped
            // (never overwritten), only a broken primary aborts the install.
            var config: [String: Any]
            do {
                config = try readJSONForMerge(at: target)
            } catch {
                if isPrimary { primaryError = error }
                continue
            }
            var hooks = config["hooks"] as? [String: Any] ?? [:]
            stripAntigravityEntries(from: &hooks)

            for (event, state) in antigravityEvents {
                var groups = hooks[event] as? [[String: Any]] ?? []
                groups.append([
                    "hooks": [[
                        "type": "command",
                        "command": "\(antigravityScriptURL.path) \(state) antigravity \(event)",
                        "timeout": 10
                    ]]
                ])
                hooks[event] = groups
            }

            config["hooks"] = hooks
            do {
                try writeJSON(config, to: target)
            } catch {
                if isPrimary { primaryError = error }
            }
        }

        if let primaryError { throw primaryError }
    }

    private static func stripAntigravityEntries(from hooks: inout [String: Any]) {
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
            // Only the core events, deliberately. Requiring every entry in `claudeHookEntries`
            // would make an install from an older Kannu report "not installed" the moment the
            // table grows — which flips the Settings toggle off and, worse, makes the version
            // migration skip the very installs that need upgrading.
            return claudeCoreInstalledEvents.allSatisfy { event in
                guard let groups = hooks[event] as? [[String: Any]] else { return false }
                return groups.contains { group in
                    guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
                    return handlers.contains { (($0["command"] as? String)?.contains(scriptName)) == true }
                }
            }
        case .antigravity:
            guard FileManager.default.fileExists(atPath: antigravityScriptURL.path) else { return false }
            // Installed if ANY supported location carries our entries — Antigravity reads
            // whichever exists, and older installs seeded only the IDE path.
            let configs = [antigravityConfigHooksURL, antigravityHooksConfigURL, antigravityRootHooksURL]
            return configs.contains { url in
                guard let config = readJSON(at: url),
                      let hooks = config["hooks"] as? [String: Any] else { return false }
                return antigravityEvents.allSatisfy { event, _ in
                    guard let groups = hooks[event] as? [[String: Any]] else { return false }
                    return groups.contains { group in
                        guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
                        return handlers.contains { (($0["command"] as? String)?.contains(scriptName)) == true }
                    }
                }
            }
        }
    }

    /// Configs whose entries are matcher groups (`{"hooks": [{"command": …}]}`) rather than
    /// Cursor's flat `{"command": …}`. Routing has to match what `merge…HooksConfig` wrote:
    /// `mergeAntigravityHooksConfig` writes group-shaped entries to *all three* Antigravity
    /// locations, so sending two of them to `stripCursorEntries` — which looks for a top-level
    /// `command` — matched nothing and left live entries behind in `~/.gemini/config/hooks.json`,
    /// the primary path install always writes. Antigravity then ran a command whose script had
    /// just been deleted, and `checkInstalled` still reported it installed.
    private static var matcherGroupConfigs: Set<URL> {
        [
            codexHooksConfigURL,
            claudeSettingsURL,
            antigravityHooksConfigURL,
            antigravityConfigHooksURL,
            antigravityRootHooksURL
        ]
    }

    private static func stripEntries(configURL: URL) throws {
        guard var config = readJSON(at: configURL),
              var hooks = config["hooks"] as? [String: Any] else { return }
        if matcherGroupConfigs.contains(configURL) {
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
            Self.claudeScriptURL,
            Self.antigravityScriptURL
        ]
        let needsRefresh = scriptURLs.contains { url in
            guard FileManager.default.fileExists(atPath: url.path),
                  let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return !content.contains(Self.scriptVersionMarker)
        }
        guard needsRefresh else { return }
        // Gate on the script existing, not on `checkInstalled`. A provider whose config schema
        // changed in this same release would fail the install check and skip its own upgrade —
        // exactly the users who need it most.
        for provider in AgentHookProvider.allCases where FileManager.default.fileExists(atPath: Self.scriptURL(for: provider).path) {
            install(provider)
        }
    }

    /// Backfills the Claude `Notification` groups for installs that predate them.
    ///
    /// Without `Notification/agent_completed` there is no "finished" signal at all, so the
    /// light never turns red. The script-version migration alone won't cover an install whose
    /// script is already current but whose settings.json still holds the older group set.
    private func migrateClaudeNotificationHooksIfNeeded() {
        guard FileManager.default.fileExists(atPath: Self.claudeScriptURL.path),
              let config = Self.readJSON(at: Self.claudeSettingsURL),
              let hooks = config["hooks"] as? [String: Any] else { return }

        let groups = hooks["Notification"] as? [[String: Any]] ?? []
        let hasKannuNotification = groups.contains { group in
            guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
            return handlers.contains { (($0["command"] as? String)?.contains(Self.scriptName)) == true }
        }
        guard !hasKannuNotification else { return }
        install(.claude)
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
        for provider in [AgentHookProvider.vscode, .codex, .claude, .antigravity] {
            guard Self.checkInstalled(provider) else { continue }
            // Plural: Antigravity's entries can live in any of three files, and install only
            // touches the two non-primary ones when they already exist. Inspecting the IDE
            // path alone meant a fresh install — which seeds `~/.gemini/config/hooks.json`
            // and nothing else — read as "nothing to migrate" and was skipped forever.
            let configURLs: [URL]
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
                configURLs = [Self.codexHooksConfigURL]
            case .claude:
                configURLs = [Self.claudeSettingsURL]
            case .antigravity:
                // Same set `checkInstalled(.antigravity)` accepts.
                configURLs = [
                    Self.antigravityConfigHooksURL,
                    Self.antigravityHooksConfigURL,
                    Self.antigravityRootHooksURL
                ]
            default:
                continue
            }

            let needsEventArg = configURLs.contains { configURL in
                guard let config = Self.readJSON(at: configURL),
                      let hooks = config["hooks"] as? [String: Any] else { return false }
                return hooks.contains { _, value in
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
            }
            guard needsEventArg else { continue }
            install(provider)
        }
    }

    /// Copies status JSON from older `~/.atoll/agent-status` into `~/.kannu/agent-status`.
    private func migrateLegacyStatusDirectoryIfNeeded() {
        let legacy = Self.home.appendingPathComponent(".atoll/agent-status", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        try? FileManager.default.createDirectory(
            at: Self.statusDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
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
            case .antigravity: scriptURL = Self.antigravityScriptURL
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

    /// Read a config that is about to be merged into and REWRITTEN. `readJSON`'s nil
    /// collapses "file absent" and "file present but unparseable" into one case, and the
    /// merge functions' `?? [:]` then rebuilt the document from scratch — silently
    /// destroying every user-defined hook (and for `~/.claude/settings.json`, the user's
    /// whole settings file) over one stray trailing comma. Absent stays mergeable;
    /// unparseable-but-present must abort the install with a visible error instead.
    private static func readJSONForMerge(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let json = readJSON(at: url) else {
            throw NSError(
                domain: "Kannu.AgentHookInstaller", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "\(url.lastPathComponent) exists but isn't valid JSON — fix or remove it, then retry (nothing was changed)."]
            )
        }
        return json
    }

    // MARK: - Claude usage statusline (~/.claude/settings.json "statusLine" key)

    /// Claude Code exposes server-reported 5h/7d subscription usage only to the configured
    /// statusLine command (stdin JSON, `rate_limits.five_hour` / `rate_limits.seven_day`).
    /// Kannu installs a statusline script that forwards those values to the shared status
    /// directory as `claude-usage.json`. Claude supports a single statusLine command, so a
    /// pre-existing user command is preserved: stored base64 inside the script, chained with
    /// the same stdin after the usage write, and restored verbatim on uninstall.
    static let usageScriptName = "kannu-usage-status.sh"
    static let usageFileName = "claude-usage.json"
    private static let usageScriptVersionMarker = "KANNU_USAGE_SCRIPT_VERSION=3"
    private static let usageChainMarkerPrefix = "# KANNU_USAGE_CHAIN_B64="

    static var claudeUsageScriptURL: URL { home.appendingPathComponent(".claude/\(usageScriptName)") }

    static func installClaudeUsageStatusLine() throws {
        try FileManager.default.createDirectory(at: statusDirectory, withIntermediateDirectories: true)

        var chainCommand: String? = nil
        let config = readJSON(at: claudeSettingsURL) ?? [:]
        if let statusLine = config["statusLine"] as? [String: Any],
           let command = statusLine["command"] as? String,
           !command.contains(usageScriptName) {
            chainCommand = command
        } else if FileManager.default.fileExists(atPath: claudeUsageScriptURL.path),
                  let existing = try? String(contentsOf: claudeUsageScriptURL, encoding: .utf8) {
            // Reinstall over our own script: keep the chain it already carries.
            chainCommand = chainedCommand(fromScript: existing)
        }

        try writeUsageScript(to: claudeUsageScriptURL, chainCommand: chainCommand)

        var newConfig = readJSON(at: claudeSettingsURL) ?? [:]
        newConfig["statusLine"] = [
            "type": "command",
            "command": claudeUsageScriptURL.path,
            "padding": 0
        ]
        try writeJSON(newConfig, to: claudeSettingsURL)
    }

    static func stripClaudeUsageStatusLine() throws {
        let chain: String? = {
            guard let script = try? String(contentsOf: claudeUsageScriptURL, encoding: .utf8) else { return nil }
            return chainedCommand(fromScript: script)
        }()

        if var config = readJSON(at: claudeSettingsURL),
           let statusLine = config["statusLine"] as? [String: Any],
           let command = statusLine["command"] as? String,
           command.contains(usageScriptName) {
            if let chain {
                config["statusLine"] = ["type": "command", "command": chain, "padding": 0]
            } else {
                config.removeValue(forKey: "statusLine")
            }
            try writeJSON(config, to: claudeSettingsURL)
        }
        try removeIfExists(claudeUsageScriptURL)
        try? FileManager.default.removeItem(at: statusDirectory.appendingPathComponent(usageFileName))
    }

    private static func chainedCommand(fromScript script: String) -> String? {
        for line in script.split(separator: "\n") where line.hasPrefix(usageChainMarkerPrefix) {
            let encoded = String(line.dropFirst(usageChainMarkerPrefix.count))
            guard !encoded.isEmpty,
                  let data = Data(base64Encoded: encoded),
                  let command = String(data: data, encoding: .utf8),
                  !command.isEmpty else { return nil }
            return command
        }
        return nil
    }

    private static func writeUsageScript(to url: URL, chainCommand: String?) throws {
        let chainB64 = chainCommand.flatMap { $0.data(using: .utf8)?.base64EncodedString() } ?? ""
        let script = """
        #!/bin/bash
        # Installed by Kannu: forwards Claude Code rate-limit usage to the notch.
        # \(usageScriptVersionMarker)
        \(usageChainMarkerPrefix)\(chainB64)
        # Reads the Claude Code statusLine JSON from stdin, writes rate-limit usage to
        # the Kannu status directory, then chains the user's original statusLine (if any).

        export KANNU_STATUS_DIR="$HOME/.kannu/agent-status"
        mkdir -p "$KANNU_STATUS_DIR"
        export KANNU_INPUT="$(cat)"

        if command -v python3 >/dev/null 2>&1; then
        python3 <<'PY'
        import datetime, json, os, tempfile, time

        raw = os.environ.get("KANNU_INPUT", "")
        status_dir = os.environ.get("KANNU_STATUS_DIR", "")
        try:
            data = json.loads(raw) if raw.strip() else {}
        except json.JSONDecodeError:
            data = {}

        # Every window Claude reports, not a fixed pair: five_hour and seven_day are universal,
        # but a plan may also carry per-model or per-surface weekly caps. Forwarding whatever
        # arrives means a newly added window shows up without the script changing again.
        rl = data.get("rate_limits") or {}
        windows = []
        for key, bucket in rl.items():
            if not isinstance(bucket, dict):
                continue
            pct = bucket.get("used_percentage")
            if pct is None:
                continue
            windows.append({"key": key, "pct": pct, "resets_at": bucket.get("resets_at")})

        # Per-model weekly windows (e.g. Fable) arrive separately, as an array with a
        # server-supplied label rather than a fixed key — "additive; present only when the server
        # emits them". Different field names too: utilization, and an ISO resets_at rather than
        # epoch seconds, normalised here so Kannu sees one shape. Wrapped so a surprise in this
        # newer, optional block can never cost us the fixed windows above.
        try:
            for bucket in rl.get("model_scoped") or []:
                if not isinstance(bucket, dict):
                    continue
                pct = bucket.get("utilization")
                name = bucket.get("display_name")
                if pct is None or not name:
                    continue
                resets = None
                raw = bucket.get("resets_at")
                if isinstance(raw, (int, float)):
                    resets = raw
                elif isinstance(raw, str) and raw:
                    try:
                        resets = datetime.datetime.fromisoformat(
                            raw.replace("Z", "+00:00")).timestamp()
                    except ValueError:
                        resets = None
                windows.append({"key": f"model_scoped:{name}", "label": name,
                                "pct": pct, "resets_at": resets})
        except Exception:
            pass

        if windows and status_dir:
            record = {
                "ts": int(time.time() * 1000),
                "windows": windows,
                "session_id": data.get("session_id"),
            }
            # Atomic same-directory replace so Kannu's watcher sees one complete file.
            fd, tmp = tempfile.mkstemp(dir=status_dir, prefix=".claude-usage-", suffix=".tmp")
            with os.fdopen(fd, "w") as f:
                json.dump(record, f)
            os.replace(tmp, os.path.join(status_dir, "claude-usage.json"))
        PY
        fi

        CHAIN_B64="$(grep -m1 '^\(usageChainMarkerPrefix)' "$0" | cut -d= -f2-)"
        if [ -n "$CHAIN_B64" ]; then
          CHAIN_CMD="$(printf '%s' "$CHAIN_B64" | base64 -d 2>/dev/null)"
          if [ -n "$CHAIN_CMD" ]; then
            printf '%s' "$KANNU_INPUT" | /bin/bash -c "$CHAIN_CMD"
            exit 0
          fi
        fi

        if command -v python3 >/dev/null 2>&1; then
        python3 <<'PY'
        import json, os, datetime

        raw = os.environ.get("KANNU_INPUT", "")
        try:
            data = json.loads(raw) if raw.strip() else {}
        except json.JSONDecodeError:
            data = {}

        rl = data.get("rate_limits") or {}

        def fmt(window):
            bucket = rl.get(window) or {}
            pct = bucket.get("used_percentage")
            if pct is None:
                return "-"
            out = f"{pct:.0f}%"
            resets = bucket.get("resets_at")
            if resets:
                dt = datetime.datetime.fromtimestamp(resets).astimezone()
                out += dt.strftime("@%H:%M" if dt.date() == datetime.date.today() else "@%a")
            return out

        model = (data.get("model") or {}).get("display_name") or ""
        line = f"{model} | 5h {fmt('five_hour')} | 7d {fmt('seven_day')}"
        print(line.strip(" |"))
        PY
        fi
        """
        try (script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Installs or refreshes the usage statusline for existing Claude hook installs.
    private func migrateClaudeUsageStatusLineIfNeeded() {
        guard FileManager.default.fileExists(atPath: Self.claudeScriptURL.path) else { return }
        if let content = try? String(contentsOf: Self.claudeUsageScriptURL, encoding: .utf8),
           content.contains(Self.usageScriptVersionMarker) { return }
        try? Self.installClaudeUsageStatusLine()
    }

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
