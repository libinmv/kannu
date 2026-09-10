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
    private static let scriptVersionMarker = "KANNU_HOOK_SCRIPT_VERSION=34"

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
                // One read-modify-write of settings.json for both keys. As two passes (hooks,
                // then statusLine) each re-reading the file, a write Claude Code made between a
                // pass's read and its write was silently discarded — .atomic protects the write,
                // not the RMW — and several migrations in init can each call install().
                var settings = try Self.readJSONForMerge(at: Self.claudeSettingsURL)
                Self.mergeClaudeHooks(into: &settings)
                try Self.setClaudeUsageStatusLine(in: &settings)
                try Self.writeJSON(settings, to: Self.claudeSettingsURL)
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
        // Counted into `tool_errors` (reset on UserPromptSubmit) for diagnostics only: a failure
        // the agent recovered from is not the turn's outcome. The card's verdict comes from
        // StopFailure below and from the transcript's API-error record, never from this count.
        ("PostToolUseFailure", nil, "", "thinking"),
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
          # Codex validates hook output strictly and rejects this line; empty stdout is its success.
          [ "$KANNU_PROVIDER" = "codex" ] || echo '{"permission":"allow","continue":true}'
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
        except Exception:
            # Not only JSONDecodeError: a deeply nested document raises RecursionError.
            data = {}
        if not isinstance(data, dict):
            # `[]`, `"x"` or `42` is valid JSON with no .get(): it killed the script before the allow line.
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

        # --- Hidden Unicode (v34) ------------------------------------------------------------
        # Local, model-free check for text an agent can read but a person cannot see: Unicode tag
        # characters (ASCII smuggling), bytes hidden in variation selectors, right-to-left overrides on
        # lines with no right-to-left letters (Trojan Source), long zero-width runs. A hit goes into
        # this status file for Kannu to show; the agent is told only if the user opted in (marker).
        # This file is embedded in a plain Swift string literal: NO backslash anywhere in it. Every
        # code point, regex classes included, is built with chr().
        HT_OFF_MARKER = ".kannu-hidden-text-off"
        HT_WARN_MARKER = ".kannu-hidden-text-warn-agent"
        HT_SKIP_EVENTS = {"SessionStart", "SessionEnd", "Notification", "PermissionRequest",
                          "beforeShellExecution", "beforeMCPExecution"}
        HT_POST_EVENTS = {"PostToolUse", "postToolUse", "PostToolUseFailure", "postToolUseFailure"}
        HT_POST_SKIP_KEYS = {"tool_input", "input", "arguments", "tool"}
        HT_WHERE = {
            "tool_response": "tool_result", "tool_output": "tool_result", "result_json": "tool_result",
            "output": "tool_result", "error": "tool_result", "error_message": "tool_result",
            "prompt": "prompt",
            "tool_input": "tool_input", "input": "tool_input", "arguments": "tool_input",
            "tool": "tool_input", "command": "tool_input", "edits": "tool_input",
            "last_assistant_message": "agent_reply", "text": "agent_reply",
        }
        HT_KIND_RANK = {"tags": 4, "variation_selectors": 3, "bidi": 2, "zero_width": 1}
        HT_WHERE_RANK = {"tool_result": 5, "prompt": 4, "tool_input": 3, "agent_reply": 2, "other": 1}
        HT_KIND_WORDS = {"tags": "Unicode tag", "variation_selectors": "variation selector",
                         "bidi": "bidirectional control", "zero_width": "zero-width"}
        HT_BIDI_NAMES = {0x202A: "LRE", 0x202B: "RLE", 0x202C: "PDF", 0x202D: "LRO", 0x202E: "RLO",
                         0x2066: "LRI", 0x2067: "RLI", 0x2068: "FSI", 0x2069: "PDI"}
        HT_TAGS = [(0xE0000, 0xE007F)]
        HT_VS = [(0xFE00, 0xFE0F), (0xE0100, 0xE01EF)]
        HT_BIDI = [(0x202A, 0x202E), (0x2066, 0x2069)]
        HT_BIDI_RTL = [(0x202B, 0x202B), (0x202E, 0x202E), (0x2067, 0x2067)]  # RLE, RLO, RLI
        HT_ZW = [(0x200B, 0x200D), (0x2060, 0x2064), (0xFEFF, 0xFEFF)]
        HT_RTL_LETTERS = [(0x0590, 0x08FF), (0xFB1D, 0xFDFF), (0xFE70, 0xFEFC), (0x10800, 0x10FFF), (0x1E800, 0x1EFFF)]
        HT_MAX_ENTRIES = 3
        HT_WINDOW_MS = 600000
        HT_BUDGET = 4000000
        HT_PLAUSIBLE_MS = 1000000000000
        HT_NL = chr(10)
        HT_ESCAPED_U = chr(92) + "u"  # a JSON escape inside a string that is itself JSON
        _ht_re = {}

        def ht_class(ranges):
            # A regex character class from (first, last) code points; chr() only, never an escape.
            out = "["
            for lo, hi in ranges:
                out += chr(lo) if lo == hi else chr(lo) + "-" + chr(hi)
            return out + "]"

        def ht_re(name):
            # Compiled on first need (about 1 ms): ASCII-only payloads never get here.
            if not _ht_re:
                _ht_re["any"] = re.compile(ht_class(HT_TAGS + HT_VS + HT_BIDI + HT_ZW))
                _ht_re["tags"] = re.compile(ht_class(HT_TAGS) + "+")
                # UTS #51 flag tag sequence: BLACK FLAG, optional VS16, 3-7 tag digits/lowercase, CANCEL TAG.
                _ht_re["flag"] = re.compile(chr(0x1F3F4) + chr(0xFE0F) + "?"
                                            + ht_class([(0xE0030, 0xE0039), (0xE0061, 0xE007A)]) + "{3,7}" + chr(0xE007F))
                _ht_re["vs"] = re.compile(ht_class(HT_VS) + "{4,}")
                _ht_re["bidi"] = re.compile(ht_class(HT_BIDI_RTL))
                _ht_re["rtl"] = re.compile(ht_class(HT_RTL_LETTERS))
                _ht_re["zw"] = re.compile(ht_class(HT_ZW) + "{10,}")
            return _ht_re[name]

        def printable_ascii(chars, limit=160):
            out = []
            for ch in chars:
                if 32 <= ord(ch) < 127:
                    out.append(ch)
                    if len(out) >= limit:
                        break
            return "".join(out)

        def ht_int(value, default=0):
            return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else default

        def ht_token(value, limit=64):
            return re.sub("[^A-Za-z0-9_.:-]", "", value)[:limit] if isinstance(value, str) else ""

        def ht_vs_text(run):
            # Butler (2025): byte b -> U+FE00+b (b < 16) or U+E0100+(b-16).
            data = bytes((ord(ch) - 0xFE00) if ord(ch) < 0xFE10 else (ord(ch) - 0xE0100 + 16) for ch in run[:4096])
            return data.decode("utf-8", "replace")

        def ht_zw_bits(run):
            # Best effort for two-symbol binary runs (Rehberger's Sneaky Bits); "" when it does not read.
            run = run[:1280]
            symbols = sorted(set(run))
            if len(symbols) != 2 or len(run) < 32:
                return ""
            run = run[:len(run) - len(run) % 8]
            best = ""
            for one in symbols:
                data = bytearray()
                for i in range(0, len(run), 8):
                    value = 0
                    for ch in run[i:i + 8]:
                        value = value * 2 + (1 if ch == one else 0)
                    data.append(value)
                text = printable_ascii(data.decode("latin-1"))
                if len(text) * 10 >= len(data) * 9 and len(text) > len(best):
                    best = text
            return best

        def ht_bidi_preview(text, lo, hi):
            out = []
            for ch in text[lo:hi]:
                name = HT_BIDI_NAMES.get(ord(ch))
                if name:
                    out.append("<" + name + ">")
                elif 32 <= ord(ch) < 127:
                    out.append(ch)
            return "".join(out).strip()[:160]

        def classify_hidden(text):
            # [(kind, chars, preview)] for one string that tripped the prefilter.
            found = []
            tag_text = ht_re("flag").sub("", text) if chr(0x1F3F4) in text else text
            count, preview = 0, ""
            for m in ht_re("tags").finditer(tag_text):
                count += len(m.group(0))
                if len(preview) < 160:
                    preview += printable_ascii((chr(ord(ch) - 0xE0000) for ch in m.group(0)[:400]), 160 - len(preview))
            if count:
                found.append(("tags", count, preview))
            count, preview = 0, ""
            for m in ht_re("vs").finditer(text):
                count += len(m.group(0))
                if len(preview) < 160:
                    preview += printable_ascii(ht_vs_text(m.group(0)), 160 - len(preview))
            if count:
                found.append(("variation_selectors", count, preview))
            count, preview, line_lo, line_hi, line_ok = 0, "", 0, -1, False
            for m in ht_re("bidi").finditer(text):
                if m.start() > line_hi:
                    line_lo = text.rfind(HT_NL, 0, m.start()) + 1
                    end = text.find(HT_NL, m.start())
                    line_hi = len(text) if end < 0 else end
                    line_ok = ht_re("rtl").search(text, line_lo, line_hi) is None
                if line_ok:
                    count += 1
                    if not preview:
                        preview = ht_bidi_preview(text, max(line_lo, m.start() - 60), min(line_hi, m.start() + 100))
                    if count >= 1000:
                        break
            if count:
                found.append(("bidi", count, preview))
            count, preview = 0, ""
            for m in ht_re("zw").finditer(text):
                count += len(m.group(0))
                if not preview:
                    preview = ht_zw_bits(m.group(0))
            if count:
                found.append(("zero_width", count, preview))
            return found

        def ht_rank(hit):
            kind, where, chars, preview = hit
            return (kind != "bidi" and len(preview) >= 4, HT_KIND_RANK[kind], HT_WHERE_RANK[where], chars)

        def scan_hidden_text(payload, event):
            # One best hit per event, from the DECODED payload (never `raw`), or None.
            skip = HT_POST_SKIP_KEYS if event in HT_POST_EVENTS else ()
            stack = [(value, HT_WHERE.get(key, "other"), 0) for key, value in payload.items() if key not in skip]
            best, budget, nodes = None, HT_BUDGET, 0
            while stack and budget > 0 and nodes < 50000:
                value, where, depth = stack.pop()
                nodes += 1
                if isinstance(value, dict):
                    if depth < 8:
                        stack.extend((item, where, depth + 1) for item in value.values())
                    continue
                if isinstance(value, list):
                    if depth < 8:
                        stack.extend((item, where, depth + 1) for item in value)
                    continue
                if not isinstance(value, str) or not value:
                    continue
                budget -= len(value)
                suspect = not value.isascii() and ht_re("any").search(value) is not None
                # Cursor hands tool output over as a JSON string: judge what it decodes to, which also
                # turns an escaped surrogate pair into the real character.
                if (suspect or HT_ESCAPED_U in value) and depth < 8 and len(value) <= 1000000 and value[:64].lstrip()[:1] in ("{", "["):
                    try:
                        inner = json.loads(value)
                    except Exception:
                        inner = None
                    if isinstance(inner, (dict, list)):
                        stack.append((inner, where, depth + 1))
                        continue
                if suspect:
                    for kind, chars, preview in classify_hidden(value):
                        hit = (kind, where, chars, preview)
                        if best is None or ht_rank(hit) > ht_rank(best):
                            best = hit
            return best

        def carried_hidden_text(value):
            # The status file is untrusted input: well-typed entries only, re-sanitised, newest three.
            out = []
            for item in (value if isinstance(value, list) else [])[-HT_MAX_ENTRIES:]:
                if not isinstance(item, dict):
                    continue
                kind, where, preview = item.get("kind"), item.get("where"), item.get("preview")
                first = ht_int(item.get("first_ts"))
                if not isinstance(kind, str) or kind not in HT_KIND_RANK or first < HT_PLAUSIBLE_MS:
                    continue
                out.append({
                    "kind": kind,
                    "where": where if isinstance(where, str) and where in HT_WHERE_RANK else "other",
                    "tool": ht_token(item.get("tool")),
                    "chars": min(ht_int(item.get("chars")), 999999),
                    "events": max(1, min(ht_int(item.get("events"), 1), 999)),
                    "preview": printable_ascii(preview if isinstance(preview, str) else ""),
                    "first_ts": first,
                    "last_ts": max(first, ht_int(item.get("last_ts"))),
                    "tool_use_id": ht_token(item.get("tool_use_id")),
                })
            return out

        def record_hidden_text(entries, hit, now_ms, tool_name, tool_use_id):
            # True for a new sighting; False when it is the same tool call seen again (parallel
            # PreToolUse groups, PostToolUse after PreToolUse).
            kind, where, chars, preview = hit
            for entry in reversed(entries):
                if entry["kind"] != kind:
                    continue
                same_call = bool(tool_use_id) and entry["tool_use_id"] == tool_use_id
                same_place = entry["where"] == where and (now_ms - entry["last_ts"] <= HT_WINDOW_MS
                                                          or (preview != "" and preview == entry["preview"]))
                if same_call or same_place:
                    if not same_call:
                        entry["events"] = min(entry["events"] + 1, 999)
                    entry["chars"] = max(entry["chars"], min(chars, 999999))
                    if len(preview) > len(entry["preview"]):
                        entry["preview"] = preview
                    entry["last_ts"] = now_ms
                    if tool_use_id:
                        entry["tool_use_id"] = tool_use_id
                    return not same_call
            entries.append({"kind": kind, "where": where,
                            "tool": tool_name if where in ("tool_result", "tool_input") else "",
                            "chars": min(chars, 999999), "events": 1, "preview": preview,
                            "first_ts": now_ms, "last_ts": now_ms, "tool_use_id": tool_use_id})
            del entries[:-HT_MAX_ENTRIES]
            return True

        def hidden_notes(hit, tool_name):
            # (context for the model, line for the user). Factual: what, how many, where. Never the
            # decoded text, nothing imperative.
            kind, where, chars, preview = hit
            what = str(chars) + " invisible " + HT_KIND_WORDS[kind] + (" character" if chars == 1 else " characters")
            if where == "tool_result":
                place, seen = ("the result of this " + tool_name + " call", "a " + tool_name + " result") if tool_name else ("this tool result", "a tool result")
            elif where == "tool_input":
                place, seen = ("the input of this " + tool_name + " call", "the input of a " + tool_name + " call") if tool_name else ("the input of this tool call", "a tool call")
            elif where == "prompt":
                place, seen = "this prompt", "your prompt"
            else:
                place, seen = "this hook input", "hook input"
            if kind == "bidi":
                effect = "Characters like these change the order in which text is displayed, so what the user sees can differ from the text itself."
            else:
                effect = "Characters like these do not render, so the user cannot see the text they encode."
            return ("Kannu, a local monitor on this Mac, found " + what + " in " + place + ". " + effect,
                    "Kannu found " + what + " in " + seen + ". Details are in Kannu's security findings.")

        ALLOW_JSON = '{"permission":"allow","continue":true}'
        # Events whose documented output carries context to the model. Never Stop (context there makes
        # Claude keep going). Codex validates strictly: widen a set only after a live check on that host.
        HT_NOTE_EVENTS = {
            "claude": {"PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "PreToolUse"},
            "vscode": {"PostToolUse"},
            "codex": {"PostToolUse"},
            "cursor": {"postToolUse"},
        }

        def emit(notes=("", "")):
            # The only stdout this script writes. Codex rejects unknown keys ("permission") and takes
            # empty stdout with exit 0 as success; every other host keeps the historical line.
            agent_note, user_note = notes
            if not agent_note or hook_event not in HT_NOTE_EVENTS.get(provider, ()):
                if provider != "codex":
                    print(ALLOW_JSON)
                return
            context = {"hookEventName": hook_event, "additionalContext": agent_note}
            if provider == "codex":
                out = {"hookSpecificOutput": context}
            elif provider == "cursor":
                out = {"permission": "allow", "continue": True, "additional_context": agent_note}
            else:
                out = {"permission": "allow", "continue": True, "hookSpecificOutput": context}
                if provider == "claude":
                    out["systemMessage"] = user_note
            print(json.dumps(out, separators=(",", ":")))

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
        elif hook_event in {"postToolUse", "postToolUseFailure", "PostToolUse", "PostToolUseFailure", "PostInvocation"}:
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

        # v34: scanned before the directory lock below (it serialises every session's hooks; this is
        # the only non-trivial CPU work in the script).
        hidden_off = os.path.exists(str(status_dir / HT_OFF_MARKER))
        hidden_hit = None
        if not hidden_off and hook_event not in HT_SKIP_EVENTS:
            try:
                hidden_hit = scan_hidden_text(data, hook_event)
            except Exception:
                hidden_hit = None

        # Claude runs the matcher-scoped and generic hook groups for one event as separate
        # processes, in parallel, with no ordering guarantee. The STATE_PRIORITY merge below
        # compares against what is on disk, so without a lock both processes read the same
        # pre-race value, each finds nothing to preserve, and whichever writes second wins
        # outright — the exact downgrade (yellow "needs you" overwritten by green "running")
        # that the merge exists to prevent. Serialise the whole read-modify-write instead.
        #
        # The lock is advisory and held until this process exits. It is one file for the whole
        # status directory, never truncated and never unlinked: a per-conversation lock had to
        # be unlinked at session end to avoid piling up, and unlinking a lock file while another
        # hook has opened but not yet locked it hands that hook a lock on a dead inode — two
        # hooks then run the merge unserialised, the exact race the lock exists to stop. Hooks
        # hold it for milliseconds, so serialising across sessions costs nothing. Kannu takes
        # the same lock (non-blocking) before deleting a status file. If flock is unavailable or
        # the wait fails we proceed unlocked: a possible lost update beats a hung hook, which
        # would stall the agent itself.
        try:
            _lock_fh = open(status_dir / ".kannu-status.lock", "a")
            fcntl.flock(_lock_fh.fileno(), fcntl.LOCK_EX)
        except Exception:
            _lock_fh = None

        # SessionStart also fires for /compact and /resume, which happen mid-conversation —
        # writing "idle" there dims (or with the stopped-indicator on, reddens) a session that
        # is actively working. Only a genuine startup should seed the idle card.
        if hook_event == "SessionStart" and str(data.get("source", "")) in {"compact", "resume"}:
            emit()
            raise SystemExit(0)

        # The session is gone: drop the card outright rather than leaving a terminal state to
        # age out. Passive detection cannot resurrect it because the process has exited too.
        if state == "session_end":
            try:
                status_file.unlink()
            except Exception:
                pass
            # Legacy per-conversation lock files from script versions < 30. Nothing locks them
            # any more, so removing one cannot strand a concurrent hook; this just stops them
            # accumulating on upgraded installs.
            try:
                (status_dir / f".{provider}-{conversation_id}.lock").unlink()
            except Exception:
                pass
            emit()
            raise SystemExit(0)

        existing_state = ""
        existing = {}
        if status_file.exists():
            try:
                existing = json.loads(status_file.read_text())
                existing_state = str(existing.get("state", ""))
            except Exception:
                existing = {}

        # Permission checks bypassed: Claude sends permission_mode on every hook (bypassPermissions);
        # Codex hooks carry approval_policy when present. Sticky for the session — once seen, kept —
        # because it describes how the session was launched, not what it is doing right now. ADR
        # Discovery cannot observe this on macOS (its process listing has no argv), so this is the one
        # signal Kannu adds to a security finding itself.
        _mode = pick_str(data.get("permission_mode"), data.get("permissionMode"), data.get("approval_policy"))
        unattended = bool(existing.get("unattended")) or normalize_token(_mode) in {
            "bypasspermissions", "dangerouslyskippermissions", "never", "yolo", "autoapprove",
        }

        # Carried like `unattended`: every write keeps it, so a clean event cannot erase a sighting
        # before Kannu reads it. Detection off drops it.
        hidden_text = []
        hidden_notes_out = ("", "")
        if not hidden_off:
            try:
                hidden_text = carried_hidden_text(existing.get("hidden_text"))
            except Exception:
                hidden_text = []
            if hidden_hit:
                try:
                    _ht_tool = ht_token(tool)
                    _ht_new = record_hidden_text(hidden_text, hidden_hit, int(time.time() * 1000), _ht_tool,
                                                 ht_token(pick_str(data.get("tool_use_id"), data.get("toolUseId"))))
                    if _ht_new and os.path.exists(str(status_dir / HT_WARN_MARKER)):
                        hidden_notes_out = hidden_notes(hidden_hit, _ht_tool)
                except Exception:
                    pass

        # Tool failures since the last prompt. Stop never says whether the turn went well; the
        # failure events do. Reset when the user submits. Diagnostic only since v33: a failure the
        # agent recovered from is not the turn's outcome, so nothing displays the count. An Esc
        # interrupt is not an error.
        _raw_errors = existing.get("tool_errors")
        tool_errors = _raw_errors if isinstance(_raw_errors, int) and not isinstance(_raw_errors, bool) and _raw_errors >= 0 else 0
        antigravity_stop_error = provider == "antigravity" and hook_event == "Stop" and state != "quota_exceeded" and bool(pick_str(data.get("error")))
        if hook_event in {"UserPromptSubmit", "beforeSubmitPrompt"}:
            tool_errors = 0
        elif hook_event in {"PostToolUseFailure", "postToolUseFailure", "StopFailure"}:
            if data.get("is_interrupt") is not True:
                tool_errors = min(tool_errors + 1, 999)
        elif antigravity_stop_error:
            tool_errors = min(tool_errors + 1, 999)

        # What the card reports is a run that ENDED on an error, decided from this event's own
        # state before the parallel-group merge below can substitute a held yellow. A StopFailure,
        # or an Antigravity Stop carrying an error, is one; a later stopped write that learns
        # nothing new (Notification/agent_completed landing after Stop) keeps the verdict on disk
        # so the label cannot flicker. Any non-stopped write is a new turn: cleared.
        ended_on_error = state == "stopped" and (
            hook_event == "StopFailure" or antigravity_stop_error or existing.get("ended_on_error") is True
        )

        # Claude runs the matcher-scoped and generic groups for one event in parallel with no
        # ordering guarantee. If both land within the same instant, keep the more urgent verdict
        # so the winner of the race cannot silently downgrade the light.
        STATE_PRIORITY = {"quota_exceeded": 50, "awaiting_input": 40, "stopped": 30, "executing": 20, "thinking": 10, "idle": 0}
        preserved_ts = None
        # The merge is scoped to one event's parallel group (same hook_event) so consecutive
        # events are not re-arbitrated against each other. One cross-event case is carried
        # deliberately: Claude issues parallel tool calls, so a PermissionRequest ("needs you")
        # for one tool and a PreToolUse ("running") for its sibling can land within the same
        # 2s window, and the generic gate let green overwrite yellow while the prompt was still
        # open. Cost of the carry: after approval the light can stay yellow for the remainder
        # of the 2s window before the next event clears it.
        same_group = existing.get("hook_event") == hook_event
        urgent_carry = existing_state == "awaiting_input" and existing.get("hook_event") == "PermissionRequest"
        if existing_state and (same_group or urgent_carry):
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

        if hook_event in {"preToolUse", "beforeMCPExecution", "postToolUse", "postToolUseFailure", "PreToolUse", "PostToolUse", "PostToolUseFailure"}:
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
                    if tool_errors:
                        existing["tool_errors"] = tool_errors
                    else:
                        existing.pop("tool_errors", None)
                    if unattended:
                        existing["unattended"] = True
                    # Not a stopped write: whatever verdict the file held is over.
                    existing.pop("ended_on_error", None)
                    if hidden_text:
                        existing["hidden_text"] = hidden_text
                    else:
                        existing.pop("hidden_text", None)
                    write_status(status_file, existing)
                    emit(hidden_notes_out)
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
        if tool_errors:
            payload["tool_errors"] = tool_errors
        if unattended:
            payload["unattended"] = True
        if ended_on_error:
            payload["ended_on_error"] = True
        if hidden_text:
            payload["hidden_text"] = hidden_text
        write_status(status_file, payload)
        emit(hidden_notes_out)
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

    /// Mutates the caller's copy of settings.json; the caller owns the single read and write.
    private static func mergeClaudeHooks(into config: inout [String: Any]) {
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
    private static let usageScriptVersionMarker = "KANNU_USAGE_SCRIPT_VERSION=4"
    private static let usageChainMarkerPrefix = "# KANNU_USAGE_CHAIN_B64="

    static var claudeUsageScriptURL: URL { home.appendingPathComponent(".claude/\(usageScriptName)") }

    /// Standalone entry point (the usage-script version migration). `install(.claude)` folds the
    /// same mutation into its single settings.json read-modify-write instead.
    static func installClaudeUsageStatusLine() throws {
        var config = try readJSONForMerge(at: claudeSettingsURL)
        try setClaudeUsageStatusLine(in: &config)
        try writeJSON(config, to: claudeSettingsURL)
    }

    /// Writes the usage script and points `statusLine` at it in the caller's copy of
    /// settings.json. The chain decision reads the same copy, never the file again.
    static func setClaudeUsageStatusLine(in config: inout [String: Any]) throws {
        try FileManager.default.createDirectory(at: statusDirectory, withIntermediateDirectories: true)

        var chainCommand: String? = nil
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

        config["statusLine"] = [
            "type": "command",
            "command": claudeUsageScriptURL.path,
            "padding": 0
        ]
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

        # Severity is not in the statusline payload today (only /api/oauth/usage limits[] carries
        # it, which Kannu reads from ~/.claude.json). Forwarded only when a bucket supplies a
        # non-empty string, so a future CLI that adds it tints the bar with the server's word
        # instead of Kannu's fraction bands.
        def with_severity(window, bucket):
            severity = bucket.get("severity")
            if isinstance(severity, str) and severity:
                window["severity"] = severity
            return window

        for key, bucket in rl.items():
            if not isinstance(bucket, dict):
                continue
            pct = bucket.get("used_percentage")
            if pct is None:
                continue
            windows.append(with_severity(
                {"key": key, "pct": pct, "resets_at": bucket.get("resets_at")}, bucket))

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
                windows.append(with_severity(
                    {"key": f"model_scoped:{name}", "label": name, "pct": pct, "resets_at": resets},
                    bucket))
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
