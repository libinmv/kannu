import Foundation
import os

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

    static let scriptName = AgentHookLayout.scriptName
    private static let scriptVersionMarker = "KANNU_HOOK_SCRIPT_VERSION=39"

    private static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// Shared directory all hooks write status files into.
    static var statusDirectory: URL {
        home.appendingPathComponent(".kannu/agent-status", isDirectory: true)
    }

    // MARK: - Per-provider paths (all from `AgentHookLayout`; REGRESSIONS entry 6)

    static var layout: AgentHookLayout { AgentHookLayout(home: home) }

    static var cursorHooksConfigURL: URL { layout.cursorHooksConfig }
    static var cursorScriptURL: URL { layout.cursorScript }

    static var vscodeHookFileURL: URL { layout.vscodeHookFile }
    static var vscodeScriptURL: URL { layout.vscodeScript }

    static var codexHooksConfigURL: URL { layout.codexHooksConfig }
    static var codexConfigTomlURL: URL { layout.codexConfigToml }
    static var codexScriptURL: URL { layout.codexScript }

    static var claudeSettingsURL: URL { layout.claudeSettings }
    static var claudeScriptURL: URL { layout.claudeScript }

    static var antigravityHooksConfigURL: URL { layout.antigravityIDEHooks }
    static var antigravityConfigHooksURL: URL { layout.antigravityConfigHooks }
    static var antigravityRootHooksURL: URL { layout.antigravityRootHooks }
    static var antigravityScriptURL: URL { layout.antigravityScript }

    static func scriptURL(for provider: AgentHookProvider) -> URL {
        layout.files(for: provider).script
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
        migrateOpencodePluginIfNeeded()
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
            case .gemini:
                // Timeouts in milliseconds; the name shows in Gemini's "hook running" indicator.
                try Self.installSharedSettingsHooks(for: .gemini, events: AgentHookLayout.geminiEvents,
                                                    handlerName: AgentHookLayout.handlerName, timeout: 10_000)
            case .qwen:
                try Self.installSharedSettingsHooks(for: .qwen, events: AgentHookLayout.qwenEvents,
                                                    handlerName: nil, timeout: 10)
            case .opencode:
                let files = Self.layout.files(for: .opencode)
                try Self.writeScript(to: files.script)
                if let plugin = files.configs.first?.url {
                    try Self.writeOpencodePlugin(to: plugin, scriptPath: files.script.path)
                }
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
            let files = Self.layout.files(for: provider)
            // Every file the layout lists, whatever install's write policy: install may have found
            // an optional one present and merged into it. Only a file install always writes may
            // fail the uninstall; a broken optional one is skipped.
            for config in files.configs {
                switch (config.shape, config.write) {
                case (.ownFile, _):
                    try Self.removeIfExists(config.url)
                case (_, .always):
                    try Self.stripEntries(config)
                case (_, .onlyIfPresent):
                    try? Self.stripEntries(config)
                }
            }
            try Self.removeIfExists(files.script)
            if provider == .claude {
                try Self.stripClaudeUsageStatusLine()
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

    /// VS Code Copilot / Codex hook events — see `AgentHookLayout.claudeStyleEvents`.
    private static var claudeStyleEvents: [(event: String, state: String)] { AgentHookLayout.claudeStyleEvents }

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
          # Gemini CLI parses stdout as JSON; Qwen Code and Copilot CLI need nothing: an empty object.
          case "$KANNU_PROVIDER" in
            codex) ;;
            gemini|qwen) echo '{}' ;;
            vscode) if [ -n "$COPILOT_CLI" ]; then echo '{}'; else echo '{"permission":"allow","continue":true}'; fi ;;
            *) echo '{"permission":"allow","continue":true}' ;;
          esac
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
        HT_POST_EVENTS = {"PostToolUse", "postToolUse", "PostToolUseFailure", "postToolUseFailure", "AfterTool"}
        HT_POST_SKIP_KEYS = {"tool_input", "input", "arguments", "tool"}
        HT_WHERE = {
            "tool_response": "tool_result", "tool_output": "tool_result", "result_json": "tool_result",
            "output": "tool_result", "error": "tool_result", "error_message": "tool_result",
            "prompt": "prompt",
            "tool_input": "tool_input", "input": "tool_input", "arguments": "tool_input",
            "tool": "tool_input", "command": "tool_input", "edits": "tool_input",
            "last_assistant_message": "agent_reply", "text": "agent_reply", "prompt_response": "agent_reply",
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

        EMPTY_OBJECT_PROVIDERS = {"gemini", "qwen", "copilot"}

        def emit(notes=("", "")):
            # The only stdout this script writes. Codex rejects unknown keys ("permission") and takes
            # empty stdout with exit 0 as success; every other host keeps the historical line. Gemini
            # CLI parses stdout as JSON (and falls back to stderr when it is empty); Qwen Code and
            # Copilot CLI need nothing from Kannu. An empty object says nothing.
            agent_note, user_note = notes
            if provider in EMPTY_OBJECT_PROVIDERS:
                print("{}")
                return
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

        # --- Terminal, secrets and sensitive files (v35) ------------------------------------------
        # Three more local, model-free checks, each written by this script and read by Kannu.
        # Terminal: the controlling terminal of the session the agent runs in, so a click can open its
        # exact tab. Secrets: API keys and private keys in a prompt or in what the agent hands a tool --
        # never in a tool's result; only the kind, the vendor prefix, the length and a 12-hex SHA-256
        # fingerprint are kept, never the secret. Sensitive files: after a tool ran, the paths it read or
        # changed, matched against keys, credential and password stores, browser data, shell history,
        # and files that run code at login or configure an agent. Still no backslash anywhere.
        SEC_OFF_MARKER = ".kannu-secrets-off"
        SP_OFF_MARKER = ".kannu-sensitive-paths-off"
        SEC_PROMPT_EVENTS = {"UserPromptSubmit", "beforeSubmitPrompt", "BeforeAgent"}
        SEC_TOOL_EVENTS = {"PreToolUse", "preToolUse", "beforeShellExecution", "beforeMCPExecution", "BeforeTool"}
        SP_EVENTS = {"PostToolUse", "postToolUse", "PostToolUseFailure", "postToolUseFailure", "AfterTool"}
        SP_FAILURE_EVENTS = {"PostToolUseFailure", "postToolUseFailure"}
        SEC_MAX_ENTRIES = 5
        SP_MAX_ENTRIES = 5
        SEC_BUDGET = 2000000
        TTY_DEVICE_RE = "tty[A-Za-z0-9]{1,12}"
        TTY_PATH_RE = "/dev/tty[A-Za-z0-9]{1,12}"
        FP_RE = "[0-9a-f]{12}"
        # (kind, literal anchors checked first, pattern). Every pattern starts with its literal so the
        # regex engine can skip ahead; the "no word character before" edge is checked in code (a leading
        # lookbehind made a 1 MB scan 40 times slower).
        SEC_PATTERNS = [
            ("private_key", ("PRIVATE KEY",), "-----BEGIN (?:[A-Z0-9]{2,12} ){0,2}PRIVATE KEY(?: BLOCK)?-----"),
            ("anthropic_key", ("sk-ant-",), "sk-ant-[A-Za-z0-9_-]{32,300}"),
            ("openai_key", ("sk-",), "sk-(?!ant-)(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{32,300}"),
            ("aws_access_key", ("AKIA", "ASIA"), "(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Za-z0-9])"),
            ("github_token", ("ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"),
             "(?:gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{50,255})(?![A-Za-z0-9_])"),
            ("gitlab_token", ("glpat-",), "glpat-[A-Za-z0-9_-]{20,64}"),
            ("slack_token", ("xox",), "xox[abprs]-[A-Za-z0-9-]{10,250}"),
            ("stripe_key", ("k_live_",), "(?:sk|rk)_live_[A-Za-z0-9]{20,250}"),
            ("google_api_key", ("AIza",), "AIza[A-Za-z0-9_-]{35}(?![A-Za-z0-9_-])"),
            ("npm_token", ("npm_",), "npm_[A-Za-z0-9]{36}(?![A-Za-z0-9])"),
            ("huggingface_token", ("hf_",), "hf_[A-Za-z0-9]{34,64}(?![A-Za-z0-9])"),
        ]
        SEC_WORD_CHARS = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        SEC_KINDS = {kind for kind, _, _ in SEC_PATTERNS}
        SEC_LITERAL_PREFIXES = ("github_pat_", "sk-svcacct-", "sk-admin-", "sk-proj-", "sk-ant-",
                                "sk_live_", "rk_live_", "glpat-", "npm_", "hf_")
        SEC_PLACEHOLDER_WORDS = ("EXAMPLE", "XXXXXXXX", "PLACEHOLDER", "REDACTED", "YOUR_", "DUMMY")
        _sec_re = {}

        def iter_strings(value, limit=20000):
            # Every string inside a JSON value, depth-first, bounded.
            stack = [(value, 0)]
            nodes = 0
            while stack and nodes < limit:
                item, depth = stack.pop()
                nodes += 1
                if isinstance(item, str):
                    if item:
                        yield item
                elif isinstance(item, dict):
                    if depth < 8:
                        stack.extend((v, depth + 1) for v in item.values())
                elif isinstance(item, list):
                    if depth < 8:
                        stack.extend((v, depth + 1) for v in item)

        def sec_prefix(kind, token):
            if kind == "private_key":
                return token.strip("-")[6:]
            for literal in SEC_LITERAL_PREFIXES:
                if token.startswith(literal):
                    return literal
            if kind == "slack_token":
                return token[:5]
            if kind == "openai_key":
                return "sk-"
            return token[:4]

        def sec_plausible(token, prefix):
            upper = token.upper()
            if any(word in upper for word in SEC_PLACEHOLDER_WORDS):
                return False
            body = token[len(prefix):]
            return len(set(body)) >= 8 and any(c.isdigit() for c in body) and any(c.isalpha() for c in body)

        def sec_fingerprint(material):
            import hashlib
            return hashlib.sha256(material.encode("utf-8", "replace")).hexdigest()[:12]

        def sec_texts(payload, event, tool_input):
            # What the check reads: the prompt, or what the agent hands a tool. Never a tool result.
            if event in SEC_PROMPT_EVENTS:
                return [("prompt", payload.get("prompt"))]
            if event in SEC_TOOL_EVENTS:
                return [("tool_input", tool_input), ("tool_input", payload.get("command"))]
            return []

        def scan_secrets(texts):
            # [(kind, where, prefix, length, fingerprint)], one per distinct secret, at most the cap.
            hits, seen, budget = [], set(), SEC_BUDGET
            for where, value in texts:
                for text in iter_strings(value):
                    budget -= len(text)
                    if budget < 0:
                        return hits
                    for kind, anchors, pattern in SEC_PATTERNS:
                        if not any(anchor in text for anchor in anchors):
                            continue
                        regex = _sec_re.get(pattern)
                        if regex is None:
                            regex = _sec_re[pattern] = re.compile(pattern)
                        for m in regex.finditer(text):
                            if kind != "private_key" and m.start() > 0 and text[m.start() - 1] in SEC_WORD_CHARS:
                                continue
                            token = m.group(0)
                            prefix = sec_prefix(kind, token)
                            if kind == "private_key":
                                end = text.find("-----END", m.end(), m.end() + 20000)
                                close = text.find("-----", end + 8, end + 80) if end >= 0 else -1
                                if close < 0:
                                    continue
                                material = "".join(text[m.start():close + 5].split())
                                if len(material) - 2 * len(token) < 64:
                                    continue
                            else:
                                if not sec_plausible(token, prefix):
                                    continue
                                material = token
                            fp = sec_fingerprint(material)
                            if (fp, where) in seen:
                                continue
                            seen.add((fp, where))
                            hits.append((kind, where, prefix, len(material), fp))
                            if len(hits) >= SEC_MAX_ENTRIES:
                                return hits
            return hits

        def carried_secrets(value):
            out = []
            for item in (value if isinstance(value, list) else [])[-SEC_MAX_ENTRIES:]:
                if not isinstance(item, dict):
                    continue
                kind, where, fp = item.get("kind"), item.get("where"), item.get("fp")
                first = ht_int(item.get("first_ts"))
                if (kind not in SEC_KINDS or where not in ("prompt", "tool_input") or not isinstance(fp, str)
                        or not re.fullmatch(FP_RE, fp) or first < HT_PLAUSIBLE_MS):
                    continue
                prefix = item.get("prefix")
                out.append({"kind": kind, "where": where, "tool": ht_token(item.get("tool")),
                            "prefix": printable_ascii(prefix if isinstance(prefix, str) else "", 40),
                            "length": min(ht_int(item.get("length")), 99999), "fp": fp,
                            "events": max(1, min(ht_int(item.get("events"), 1), 999)),
                            "first_ts": first, "last_ts": max(first, ht_int(item.get("last_ts"))),
                            "tool_use_id": ht_token(item.get("tool_use_id"))})
            return out

        def record_secret(entries, hit, now_ms, tool_name, tool_use_id):
            # The same secret in the same place is one sighting; the same tool call never counts twice.
            kind, where, prefix, length, fp = hit
            for entry in reversed(entries):
                if entry["fp"] == fp and entry["where"] == where:
                    if not (tool_use_id and entry["tool_use_id"] == tool_use_id):
                        entry["events"] = min(entry["events"] + 1, 999)
                    entry["last_ts"] = now_ms
                    if tool_use_id:
                        entry["tool_use_id"] = tool_use_id
                    return
            entries.append({"kind": kind, "where": where, "tool": tool_name if where == "tool_input" else "",
                            "prefix": prefix, "length": length, "fp": fp, "events": 1,
                            "first_ts": now_ms, "last_ts": now_ms, "tool_use_id": tool_use_id})
            del entries[:-SEC_MAX_ENTRIES]

        SP_SHELL_TOOLS = {"bash", "shell", "runterminalcmd", "localshell", "execcommand", "runshellcommand",
                          "terminal", "exec", "execute", "runcommand"}
        SP_LISTING_TOOLS = {"glob", "ls", "listdir", "listdirectory", "filesearch", "globfilesearch"}
        SP_WRITE_WORDS = ("write", "edit", "replace", "patch", "create", "move", "rename", "copy",
                          "delete", "insert", "append", "update", "save")
        SP_PATH_KEYS = ("file_path", "filePath", "path", "target_file", "targetFile", "notebook_path",
                        "absolute_path", "filename", "file", "source", "destination", "target")
        SP_WRAPPERS = {"sudo", "env", "command", "exec", "nohup", "time", "nice", "doas", "builtin", "caffeinate"}
        SP_SEPARATOR_CHARS = set(";&|(){}!")
        SP_REDIRECTS_OUT = {">", ">>", ">|", "&>", "&>>", ">&", "1>", "2>"}
        SP_COPY_CMDS = {"cp", "mv", "ln", "install", "rsync", "ditto", "scp"}
        SP_WRITE_CMDS = {"tee", "touch", "rm", "truncate", "chmod", "chown", "shred", "unlink", "srm"}
        SP_INPLACE_CMDS = {"sed", "gsed", "perl"}
        SP_NAME_ONLY_CMDS = {"ls", "stat", "file", "du", "cd", "pushd", "popd", "mkdir", "echo", "printf",
                             "which", "type", "realpath", "dirname", "basename", "readlink", "test", "[", "[["}
        SP_KEYCHAIN_READS = {"find-generic-password", "find-internet-password", "dump-keychain", "export"}
        SP_LAUNCHCTL_WRITES = {"load", "bootstrap", "enable", "submit"}
        SP_PATCH_MARKERS = ("*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: ")
        SP_WRITE_ONLY = {"autorun", "shell_startup", "agent_config"}
        SP_ENV_SAFE = {"example", "sample", "template", "dist", "defaults", "schema", "tpl", "tmpl"}
        SP_HOME_DIRS = {".ssh": "ssh_key", ".gnupg": "gpg_key", ".aws": "cloud_credentials",
                        ".password-store": "password_store", "Library/Keychains": "keychain",
                        ".config/gcloud": "cloud_credentials", ".kube": "cloud_credentials"}
        SP_HOME_FILES = {
            ".aws/credentials": "cloud_credentials", ".kube/config": "cloud_credentials",
            ".docker/config.json": "cloud_credentials", ".terraform.d/credentials.tfrc.json": "cloud_credentials",
            ".config/gcloud/credentials.db": "cloud_credentials", ".config/gcloud/access_tokens.db": "cloud_credentials",
            ".config/gcloud/application_default_credentials.json": "cloud_credentials",
            ".git-credentials": "token_file", ".config/git/credentials": "token_file", ".netrc": "token_file",
            ".config/gh/hosts.yml": "token_file", ".npmrc": "token_file", ".pypirc": "token_file",
            ".gem/credentials": "token_file", ".cargo/credentials": "token_file", ".cargo/credentials.toml": "token_file",
            ".codex/auth.json": "agent_credentials", ".claude/.credentials.json": "agent_credentials",
            ".gemini/oauth_creds.json": "agent_credentials", ".qwen/oauth_creds.json": "agent_credentials",
            ".local/share/opencode/auth.json": "agent_credentials",
            ".gnupg/secring.gpg": "gpg_key",
            ".zsh_history": "shell_history", ".bash_history": "shell_history", ".zhistory": "shell_history",
            ".sh_history": "shell_history", ".history": "shell_history", ".python_history": "shell_history",
            ".node_repl_history": "shell_history", ".psql_history": "shell_history", ".mysql_history": "shell_history",
            ".sqlite_history": "shell_history", ".irb_history": "shell_history",
            ".ssh/authorized_keys": "autorun",
            ".zshrc": "shell_startup", ".zshenv": "shell_startup", ".zprofile": "shell_startup",
            ".zlogin": "shell_startup", ".zlogout": "shell_startup", ".bashrc": "shell_startup",
            ".bash_profile": "shell_startup", ".bash_login": "shell_startup", ".profile": "shell_startup",
            ".config/fish/config.fish": "shell_startup",
            ".claude.json": "agent_config", ".codex/config.toml": "agent_config",
            ".config/opencode/opencode.json": "agent_config", ".config/opencode/opencode.jsonc": "agent_config",
            "Library/Application Support/Claude/claude_desktop_config.json": "agent_config",
            "Library/Application Support/Code/User/settings.json": "agent_config",
            "Library/Application Support/Code/User/mcp.json": "agent_config",
            "Library/Application Support/Cursor/User/settings.json": "agent_config",
        }
        SP_HOME_PREFIXES = [
            (".aws/sso/cache/", "cloud_credentials"), (".config/gcloud/legacy_credentials/", "cloud_credentials"),
            (".azure/", "cloud_credentials"), (".config/github-copilot/", "agent_credentials"),
            (".gnupg/private-keys-v1.d/", "gpg_key"), (".password-store/", "password_store"),
            ("Library/Application Support/1Password/", "password_store"),
            ("Library/Group Containers/2BUA8C4S2C.com.1password/", "password_store"),
            ("Library/Application Support/Bitwarden/", "password_store"),
            ("Library/Keychains/", "keychain"),
            ("Library/Application Support/Google/Chrome/", "browser_data"),
            ("Library/Application Support/BraveSoftware/", "browser_data"),
            ("Library/Application Support/Microsoft Edge/", "browser_data"),
            ("Library/Application Support/Arc/User Data/", "browser_data"),
            ("Library/Application Support/Firefox/Profiles/", "browser_data"),
            ("Library/Safari/", "browser_data"), ("Library/Cookies/", "browser_data"),
            ("Library/Containers/com.apple.Safari/", "browser_data"),
            (".zsh_sessions/", "shell_history"),
            ("Library/LaunchAgents/", "autorun"),
            (".kannu/", "agent_config"),
        ]
        SP_ROOT_PREFIXES = [("/Library/LaunchAgents/", "autorun"), ("/Library/LaunchDaemons/", "autorun"),
                            ("/Library/Keychains/", "keychain"), ("/etc/periodic/", "autorun")]
        SP_ANY_SUFFIXES = [("/.claude/settings.json", "agent_config"), ("/.claude/settings.local.json", "agent_config"),
                           ("/.mcp.json", "agent_config"), ("/.cursor/mcp.json", "agent_config"),
                           ("/.cursor/hooks.json", "agent_config"), ("/.gemini/settings.json", "agent_config"),
                           ("/.qwen/settings.json", "agent_config"), ("/.vscode/settings.json", "agent_config"),
                           ("/.vscode/mcp.json", "agent_config"), ("/.codex/config.toml", "agent_config")]
        SP_CATEGORIES = ({c for c in SP_HOME_DIRS.values()} | {c for c in SP_HOME_FILES.values()}
                         | {c for _, c in SP_HOME_PREFIXES} | {"env_file", "autorun", "keychain", "agent_config"})

        def early_cwd(payload):
            roots = payload.get("workspace_roots") or payload.get("workspacePaths") or payload.get("workspace_paths")
            root = str(roots[0]) if isinstance(roots, list) and roots else ""
            return pick_str(payload.get("cwd"), root).replace("file://", "").rstrip("/")

        def sp_norm(token, cwd, home):
            t = token.strip().replace("file://", "")
            if t.startswith("@"):
                t = t[1:]
            if t.startswith("-") or ("=" in t and not t.startswith(("/", "~", "."))):
                if "=" not in t:
                    return ""
                t = t.split("=", 1)[1]
            if not t or len(t) > 1024 or t.startswith(("http:", "https:")):
                return ""
            if t == "~" or t.startswith("~/"):
                t = home + t[1:]
            elif t.startswith("$HOME/"):
                t = home + t[5:]
            elif t.startswith("${HOME}/"):
                t = home + t[7:]
            if not t.startswith("/") and cwd:
                t = cwd + "/" + t
            return os.path.normpath(t)

        def sp_classify(path, home):
            rel = path[len(home) + 1:] if home and path.startswith(home + "/") else ""
            base = path.rsplit("/", 1)[-1]
            if rel:
                if rel.startswith(".ssh/") and "/" not in rel[5:] and (
                        (base.startswith("id_") and not base.endswith(".pub")) or "*" in base
                        or base.endswith((".pem", ".key", ".ppk"))):
                    return "ssh_key"
                category = SP_HOME_DIRS.get(rel) or SP_HOME_FILES.get(rel)
                if category:
                    return category
                # A directory itself counts too: `cp x ~/Library/LaunchAgents/` normalises to no slash.
                for prefix, category in SP_HOME_PREFIXES:
                    if (rel + "/").startswith(prefix):
                        return category
            for prefix, category in SP_ROOT_PREFIXES:
                if (path + "/").startswith(prefix):
                    return category
            for suffix, category in SP_ANY_SUFFIXES:
                if path.endswith(suffix) or path == suffix[1:]:
                    return category
            if "/.git/hooks/" in path or path.startswith(".git/hooks/"):
                return "autorun"
            if base == ".env" or (base.startswith(".env.") and base[5:].lower() not in SP_ENV_SAFE):
                return "env_file"
            return ""

        def sp_simple_command(words):
            # [(token, access, special)] for one simple command: redirections, then its operands.
            i = 0
            while i < len(words):
                word = words[i]
                if word in SP_WRAPPERS or (i > 0 and words[i - 1] in SP_WRAPPERS and word.startswith("-")):
                    i += 1
                elif "=" in word and word.split("=", 1)[0].replace("_", "").isalnum():
                    i += 1
                else:
                    break
            if i >= len(words):
                return []
            name, args = words[i].rsplit("/", 1)[-1], words[i + 1:]
            out = []
            operands = [a for a in args if not a.startswith("-") or "=" in a]
            if name == "security":
                sub = operands[0] if operands else ""
                if sub in SP_KEYCHAIN_READS:
                    out.append(("security " + sub, "read", "keychain"))
            elif name == "crontab" and args and "-l" not in args:
                out.append(("crontab", "write", "autorun"))
            elif name == "launchctl" and args and args[0] in SP_LAUNCHCTL_WRITES:
                out.append(("launchctl " + args[0], "write", "autorun"))
            elif name == "apply_patch":
                out.extend(sp_patch_paths(args))
            plain, redirect = [], ""
            for arg in args:
                if arg in SP_REDIRECTS_OUT:
                    redirect = "write"
                elif arg == "<":
                    redirect = "read"
                elif redirect:
                    out.append((arg, redirect, ""))
                    redirect = ""
                elif not arg.startswith("-") or "=" in arg:
                    plain.append(arg)
            if name in SP_NAME_ONLY_CMDS:
                return out
            if name in SP_WRITE_CMDS:
                out.extend((a, "write", "") for a in plain)
            elif name in SP_COPY_CMDS and plain:
                out.extend((a, "read", "") for a in plain[:-1])
                out.append((plain[-1], "write", ""))
            elif name in SP_INPLACE_CMDS and any(a.startswith(("-i", "-pi", "--in-place")) for a in args):
                out.extend((a, "write", "") for a in plain)
            else:
                out.extend((a, "read", "") for a in plain)
            return out

        def sp_command_paths(command):
            if isinstance(command, list):
                parts = [p for p in command if isinstance(p, str)]
                if len(parts) >= 3 and parts[1] in ("-c", "-lc", "-ic", "-lic"):
                    command = parts[2]
                else:
                    return sp_simple_command(parts)
            if not isinstance(command, str):
                return []
            import shlex
            out = []
            for line in command.split(chr(10))[:200]:
                if not line.strip():
                    continue
                try:
                    lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
                    lexer.whitespace_split = True
                    words = list(lexer)
                except Exception:
                    words = line.split()
                current = []
                for word in words + [";"]:
                    if word and all(c in SP_SEPARATOR_CHARS for c in word):
                        if current:
                            out.extend(sp_simple_command(current))
                        current = []
                    else:
                        current.append(word)
                if len(out) > 200:
                    break
            return out

        def sp_patch_paths(value):
            out = []
            for text in iter_strings(value, 200):
                if "*** " not in text:
                    continue
                for line in text.split(chr(10))[:5000]:
                    for marker in SP_PATCH_MARKERS:
                        if line.startswith(marker):
                            out.append((line[len(marker):].strip(), "write", ""))
            return out

        def scan_paths(tool_name, tool_input, cwd, home):
            # [(category, access, display path)], distinct, at most the cap.
            compact = normalize_token(tool_name)
            if compact in SP_LISTING_TOOLS:
                return []
            if isinstance(tool_input, str) and tool_input.lstrip()[:1] == "{":
                try:
                    parsed = json.loads(tool_input)
                except Exception:
                    parsed = None
                if isinstance(parsed, dict):
                    tool_input = parsed
            candidates = []
            if isinstance(tool_input, dict):
                command = tool_input.get("command", tool_input.get("cmd"))
                if command is not None and (compact in SP_SHELL_TOOLS or not any(k in tool_input for k in SP_PATH_KEYS)):
                    candidates.extend(sp_command_paths(command))
                else:
                    access = "write" if any(word in compact for word in SP_WRITE_WORDS) else "read"
                    for key in SP_PATH_KEYS:
                        value = tool_input.get(key)
                        if isinstance(value, str) and value:
                            candidates.append((value, access, ""))
                    paths = tool_input.get("paths")
                    if isinstance(paths, list):
                        candidates.extend((p, "read", "") for p in paths[:50] if isinstance(p, str))
                if "patch" in compact:
                    candidates.extend(sp_patch_paths(tool_input))
            elif isinstance(tool_input, (str, list)) and compact in SP_SHELL_TOOLS:
                candidates.extend(sp_command_paths(tool_input))
            elif isinstance(tool_input, str) and "patch" in compact:
                candidates.extend(sp_patch_paths(tool_input))
            hits = []
            for token, access, special in candidates[:400]:
                if special:
                    hit = (special, access, printable_ascii(token, 160))
                else:
                    path = sp_norm(token, cwd, home)
                    category = sp_classify(path, home) if path else ""
                    if (not category or (category in SP_WRITE_ONLY and access != "write")
                            or (category == "env_file" and access != "read")):
                        continue
                    shown = "~/" + path[len(home) + 1:] if home and path.startswith(home + "/") else path
                    hit = (category, access, printable_ascii(shown, 160))
                if hit[2] and hit not in hits:
                    hits.append(hit)
                    if len(hits) >= SP_MAX_ENTRIES:
                        break
            return hits

        def carried_paths(value):
            out = []
            for item in (value if isinstance(value, list) else [])[-SP_MAX_ENTRIES:]:
                if not isinstance(item, dict):
                    continue
                category, access, path = item.get("category"), item.get("access"), item.get("path")
                first = ht_int(item.get("first_ts"))
                path = printable_ascii(path, 160) if isinstance(path, str) else ""
                if category not in SP_CATEGORIES or access not in ("read", "write") or not path or first < HT_PLAUSIBLE_MS:
                    continue
                out.append({"category": category, "access": access, "path": path, "tool": ht_token(item.get("tool")),
                            "failed": item.get("failed") is True,
                            "events": max(1, min(ht_int(item.get("events"), 1), 999)),
                            "first_ts": first, "last_ts": max(first, ht_int(item.get("last_ts"))),
                            "tool_use_id": ht_token(item.get("tool_use_id"))})
            return out

        def record_path(entries, hit, now_ms, tool_name, tool_use_id, failed):
            # One sighting per (category, access, path); "failed" stays only while every attempt failed.
            category, access, path = hit
            for entry in reversed(entries):
                if entry["category"] == category and entry["access"] == access and entry["path"] == path:
                    if not (tool_use_id and entry["tool_use_id"] == tool_use_id):
                        entry["events"] = min(entry["events"] + 1, 999)
                    entry["failed"] = entry["failed"] and failed
                    entry["last_ts"] = now_ms
                    if tool_use_id:
                        entry["tool_use_id"] = tool_use_id
                    return
            entries.append({"category": category, "access": access, "path": path, "tool": tool_name,
                            "failed": failed, "events": 1, "first_ts": now_ms, "last_ts": now_ms,
                            "tool_use_id": tool_use_id})
            del entries[:-SP_MAX_ENTRIES]

        TERMINAL_PROVIDERS = {"codex", "copilot", "gemini", "qwen", "opencode"}
        TTY_PROBE_EVENTS = {"SessionStart", "UserPromptSubmit", "beforeSubmitPrompt", "BeforeAgent"}

        def ancestor_terminal(max_hops=12):
            # (tty, session leader pid, its start time) of the nearest process, this one or an ancestor,
            # that has a controlling terminal. An agent may start each hook in a session of its own --
            # Claude Code does -- so the hook's own session says nothing; the agent that spawned it still
            # sits in the terminal. libproc's proc_bsdinfo gives the parent (byte 16), the terminal
            # (e_tdev, byte 108) and the start time (byte 120); about 2 ms, no process spawned.
            import ctypes
            lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
            lib.devname.restype = ctypes.c_char_p

            def bsdinfo(pid):
                buf = ctypes.create_string_buffer(136)
                if lib.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(3), ctypes.c_uint64(0), buf, ctypes.c_int(136)) != 136:
                    return None
                raw = buf.raw
                return raw if int.from_bytes(raw[12:16], "little") == pid else None

            pid = os.getpid()
            for _ in range(max_hops):
                raw = bsdinfo(pid)
                if raw is None:
                    break
                tdev = int.from_bytes(raw[108:112], "little", signed=True)
                if tdev != -1:
                    name = lib.devname(ctypes.c_int32(tdev), ctypes.c_uint16(0o020000))
                    name = name.decode("ascii", "replace") if name else ""
                    sid = os.getsid(pid)
                    leader = bsdinfo(sid) if sid > 1 else None
                    if not re.fullmatch(TTY_DEVICE_RE, name) or leader is None:
                        return ("", 0, 0)
                    return ("/dev/" + name, sid, int.from_bytes(leader[120:128], "little"))
                parent = int.from_bytes(raw[16:20], "little")
                if parent <= 1 or parent == pid:
                    break
                pid = parent
            return ("", 0, 0)

        def session_terminal(existing):
            # Only terminal agents need it: Claude's own session file already names its process, and the
            # IDE agents have no terminal. Looked up when a session starts, on each prompt and on a
            # conversation's first event; carried in between (a session does not change terminals).
            if provider not in TERMINAL_PROVIDERS:
                return ("", 0, 0)
            if hook_event in TTY_PROBE_EVENTS or not existing:
                return ancestor_terminal()
            tty = existing.get("tty")
            if isinstance(tty, str) and re.fullmatch(TTY_PATH_RE, tty) and ht_int(existing.get("tty_sid")) > 1:
                return (tty, ht_int(existing.get("tty_sid")), ht_int(existing.get("tty_start")))
            return ("", 0, 0)

        # --- Turn metrics (v39) ----------------------------------------------------------------
        # A turn is one request: it starts when the user sends a prompt and ends at the Stop that
        # answers it. Work after that Stop without a new prompt -- a background task finishing, a stop
        # hook sending the agent back -- reopens the same turn, so its time still counts from the
        # prompt. Kannu shows how long the turn ran and how many tools it called, and for Claude adds
        # up the tokens the transcript gained after the size recorded at the start. Carried on every
        # write; never touches state or ts.
        TURN_KEYS = ("turn_started_ms", "turn_ended_ms", "turn_tool_calls", "turn_tool_ids", "turn_transcript_offset")
        TURN_PROMPT_EVENTS = {"UserPromptSubmit", "beforeSubmitPrompt", "BeforeAgent"}
        TURN_WAKE_EVENTS = {"PreToolUse", "preToolUse", "beforeShellExecution", "beforeMCPExecution",
                            "BeforeTool", "PreInvocation", "PermissionRequest"}
        TURN_END_EVENTS = {"Stop", "StopFailure", "stop", "AfterAgent"}
        TURN_DONE_EVENTS = HT_POST_EVENTS
        TURN_MAX_IDS = 16
        TURN_MAX_CALLS = 99999
        TURN_MAX_OFFSET = 9007199254740992
        TURN_PATH_MAX = 1024
        TURN_NOID_WINDOW_MS = 2000
        TURN_ROOT = os.path.expanduser("~") + "/.claude/projects/"

        def turn_path(value):
            # Claude's main transcript only: under ~/.claude/projects, a .jsonl, never a subagent's.
            # Kannu checks the same rule again before it reads the file.
            if not isinstance(value, str) or not value or len(value) > TURN_PATH_MAX:
                return ""
            if printable_ascii(value, TURN_PATH_MAX) != value or os.path.normpath(value) != value:
                return ""
            if not value.startswith(TURN_ROOT) or not value.endswith(".jsonl") or "/subagents/" in value:
                return ""
            return value

        def turn_size(path):
            # The transcript's size, without following a symlink: None while it does not exist yet,
            # -1 when it is not a plain file or cannot be read (then no offset is recorded).
            try:
                st = os.lstat(path)
            except FileNotFoundError:
                return None
            except Exception:
                return -1
            if (st.st_mode & 0o170000) != 0o100000:
                return -1
            return min(st.st_size, TURN_MAX_OFFSET)

        def turn_ids(value):
            out = []
            for item in (value if isinstance(value, list) else [])[-TURN_MAX_IDS:]:
                token = ht_token(item)
                if token:
                    out.append(token)
            return out

        def carried_turn(doc, now_ms):
            # The turn keys of a status file (untrusted input), re-checked; {} without a plausible start.
            start = ht_int(doc.get("turn_started_ms"))
            if start < HT_PLAUSIBLE_MS or start > now_ms + 60000:
                return {}
            turn = {"turn_started_ms": start,
                    "turn_tool_calls": min(ht_int(doc.get("turn_tool_calls")), TURN_MAX_CALLS),
                    "turn_tool_ids": turn_ids(doc.get("turn_tool_ids"))}
            end = ht_int(doc.get("turn_ended_ms"))
            if start <= end <= now_ms + 60000:
                turn["turn_ended_ms"] = end
            offset = ht_int(doc.get("turn_transcript_offset"), -1)
            if 0 <= offset <= TURN_MAX_OFFSET:
                turn["turn_transcript_offset"] = offset
            return turn

        def parent_turn_start():
            # When the current turn of a subagent's chat began (0 when unknown). Read under the lock.
            try:
                doc = json.loads((status_dir / (provider + "-" + parent_id + ".json")).read_text())
                return ht_int(doc.get("turn_started_ms")) if isinstance(doc, dict) else 0
            except Exception:
                return 0

        def turn_call_key(turn, now_ms):
            # (key, already counted). The tool call's id when the agent sends one; otherwise the tool and
            # the size of its input, so one completion delivered twice within 2 s counts once.
            if sighting_call:
                return sighting_call, sighting_call in turn["turn_tool_ids"]
            stem = "nx:" + sighting_tool[:24] + ":" + str(len(str(tool_input))) + ":"
            for token in turn["turn_tool_ids"]:
                tail = token[len(stem):] if token.startswith(stem) else ""
                if tail.isdigit() and now_ms - int(tail) <= TURN_NOID_WINDOW_MS:
                    return "", True
            return stem + str(now_ms), False

        def next_turn(existing, now_ms):
            # (turn keys, transcript path) for this write.
            turn = carried_turn(existing, now_ms)
            previous = existing.get("hook_event") if isinstance(existing.get("hook_event"), str) else ""
            main_thread = provider == "claude" and not parent_id
            transcript = turn_path(existing.get("transcript_path")) if main_thread else ""
            fresh = turn_path(data.get("transcript_path")) if main_thread else ""
            if fresh and fresh != transcript:
                # First seen, or the chat moved to another file mid-turn: no offset rather than a wrong one.
                turn.pop("turn_transcript_offset", None)
                transcript = fresh
            if hook_event == "SessionStart":
                # A startup or /clear. opencode spawns SessionStart and the first prompt without waiting,
                # so a prompt that won the lock keeps its open turn.
                if "turn_ended_ms" in turn or previous not in TURN_PROMPT_EVENTS:
                    turn = {}
                return turn, transcript
            starts = hook_event in TURN_PROMPT_EVENTS or (hook_event in TURN_WAKE_EVENTS and not turn)
            if parent_id and turn and hook_event in TURN_WAKE_EVENTS and parent_turn_start() > turn["turn_started_ms"]:
                # A subagent resumed in a later request of its chat.
                starts = True
            if starts:
                turn = {"turn_started_ms": now_ms, "turn_tool_calls": 0, "turn_tool_ids": []}
                if transcript:
                    size = turn_size(transcript)
                    if size is None:
                        # Not written yet: the whole file is this turn, but only for a chat that has just
                        # started. Any other chat may be about to copy an earlier history into it.
                        if previous == "SessionStart":
                            turn["turn_transcript_offset"] = 0
                    elif size >= 0:
                        turn["turn_transcript_offset"] = size
            elif turn and hook_event in TURN_WAKE_EVENTS:
                # Working again after the Stop without a new prompt: still the same request.
                turn.pop("turn_ended_ms", None)
            if turn and hook_event in TURN_DONE_EVENTS:
                key, seen = turn_call_key(turn, now_ms)
                if not seen:
                    turn["turn_tool_calls"] = min(turn["turn_tool_calls"] + 1, TURN_MAX_CALLS)
                    turn["turn_tool_ids"] = (turn["turn_tool_ids"] + [key])[-TURN_MAX_IDS:]
            if turn and hook_event in TURN_END_EVENTS and ("turn_ended_ms" not in turn or data.get("stop_hook_active") is True):
                # The first Stop ends the turn; a Stop after a stop hook's continuation moves the end.
                turn["turn_ended_ms"] = now_ms
            return turn, transcript

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

        # v38: Claude Code (and Qwen Code) fire a subagent's hooks with its agent_id beside the parent's
        # session_id. The file stays the subagent's own, as before; parent_id names the chat it belongs
        # to, so Kannu folds it into that chat's card instead of showing a nameless one. Cursor's agentId
        # is its own conversation and is left alone.
        parent_id = ""
        if provider in {"claude", "qwen"} and pick_str(data.get("agent_id"), data.get("agentId")):
            parent_id = re.sub("[^A-Za-z0-9_-]", "", pick_str(data.get("session_id"), data.get("sessionId")))[:64]
            if parent_id == conversation_id:
                parent_id = ""

        # v36: Copilot CLI reads the same ~/.copilot/hooks file as VS Code, so its events arrive as
        # "vscode". The CLI sets COPILOT_CLI for what it spawns and runs in a terminal; VS Code's extension
        # host has neither. A conversation already filed either way keeps it (the process walk runs once);
        # anything unclear stays vscode, as before.
        def has_controlling_terminal():
            try:
                fd = os.open("/dev/tty", os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
            except Exception:
                return False
            os.close(fd)
            return True

        if provider == "vscode":
            if (os.environ.get("COPILOT_CLI") or has_controlling_terminal()
                    or (status_dir / ("copilot-" + conversation_id + ".json")).exists()):
                provider = "copilot"
            elif not (status_dir / ("vscode-" + conversation_id + ".json")).exists():
                try:
                    if ancestor_terminal()[0]:
                        provider = "copilot"
                except Exception:
                    pass

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
        elif hook_event == "PermissionRequest" and provider == "copilot":
            # Copilot CLI fires this before its own rules, session approvals and auto-allow, so most
            # never become a prompt. Its Notification says when one is on screen.
            emit()
            raise SystemExit(0)
        elif hook_event in {"PermissionRequest"}:
            state = "awaiting_input"
        elif hook_event == "Notification":
            # Notifications without a matcher (VS Code and Copilot CLI, Gemini CLI, Qwen Code): only a
            # prompt on screen is yellow. Idle reminders and other notices change nothing. Claude's
            # Notification groups carry matcher keys and never get here.
            if pick_str(data.get("notification_type"), data.get("notificationType")) in {"ToolPermission", "permission_prompt", "elicitation_dialog"}:
                state = "awaiting_input"
            else:
                emit()
                raise SystemExit(0)
        elif hook_event == "BeforeAgent":
            # Gemini CLI: a prompt was submitted.
            state = "thinking"
        elif hook_event == "BeforeTool":
            # Gemini CLI runs this before its policy check; a prompt, if any, follows as a Notification.
            state = "executing"
        elif hook_event == "AfterTool":
            state = "thinking"
        elif hook_event == "AfterAgent":
            # Gemini CLI: the turn ended. (Esc does not fire it; the stale ladder ends that card.)
            state = "stopped"
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

        # v35: the secret and sensitive-file checks, also before the lock.
        secrets_off = os.path.exists(str(status_dir / SEC_OFF_MARKER))
        paths_off = os.path.exists(str(status_dir / SP_OFF_MARKER))
        secret_hits = []
        if not secrets_off and (hook_event in SEC_PROMPT_EVENTS or hook_event in SEC_TOOL_EVENTS):
            try:
                secret_hits = scan_secrets(sec_texts(data, hook_event, tool_input))
            except Exception:
                secret_hits = []
        path_hits = []
        if not paths_off and hook_event in SP_EVENTS:
            try:
                path_hits = scan_paths(tool, tool_input, early_cwd(data), os.path.expanduser("~"))
            except Exception:
                path_hits = []

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

        # A Copilot CLI session that a v35 hook filed as vscode: drop that card, it is this one.
        if provider == "copilot":
            try:
                (status_dir / ("vscode-" + conversation_id + ".json")).unlink()
            except Exception:
                pass

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

        # v35: carried like hidden_text -- every write keeps them; a check that is off drops its list.
        sighting_tool = ht_token(tool)
        sighting_call = ht_token(pick_str(data.get("tool_use_id"), data.get("toolUseId")))
        sighting_ms = int(time.time() * 1000)
        secrets = []
        if not secrets_off:
            try:
                secrets = carried_secrets(existing.get("secrets"))
            except Exception:
                secrets = []
            for _hit in secret_hits:
                try:
                    record_secret(secrets, _hit, sighting_ms, sighting_tool, sighting_call)
                except Exception:
                    pass
        sensitive_paths = []
        if not paths_off:
            try:
                sensitive_paths = carried_paths(existing.get("sensitive_paths"))
            except Exception:
                sensitive_paths = []
            for _hit in path_hits:
                try:
                    record_path(sensitive_paths, _hit, sighting_ms, sighting_tool, sighting_call,
                                hook_event in SP_FAILURE_EVENTS)
                except Exception:
                    pass
        try:
            terminal = session_terminal(existing)
        except Exception:
            terminal = ("", 0, 0)

        # Tool failures since the last prompt. Stop never says whether the turn went well; the
        # failure events do. Reset when the user submits. Diagnostic only since v33: a failure the
        # agent recovered from is not the turn's outcome, so nothing displays the count. An Esc
        # interrupt is not an error.
        _raw_errors = existing.get("tool_errors")
        tool_errors = _raw_errors if isinstance(_raw_errors, int) and not isinstance(_raw_errors, bool) and _raw_errors >= 0 else 0
        antigravity_stop_error = provider == "antigravity" and hook_event == "Stop" and state != "quota_exceeded" and bool(pick_str(data.get("error")))
        if hook_event in {"UserPromptSubmit", "beforeSubmitPrompt", "BeforeAgent"}:
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

        # v39: after the merge, which changes only state and ts, so the turn rides every write. A
        # failure here must cost neither the light nor the allow line: fall back to what was on disk.
        try:
            turn, transcript = next_turn(existing, sighting_ms)
        except Exception:
            try:
                turn = carried_turn(existing, sighting_ms)
            except Exception:
                turn = {}
            transcript = ""

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

        if hook_event in {"preToolUse", "beforeMCPExecution", "postToolUse", "postToolUseFailure", "PreToolUse", "PostToolUse", "PostToolUseFailure", "BeforeTool", "AfterTool"}:
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
                    for _key, _value in (("secrets", secrets), ("sensitive_paths", sensitive_paths),
                                         ("tty", terminal[0]), ("tty_sid", terminal[1]), ("tty_start", terminal[2])):
                        if _value:
                            existing[_key] = _value
                        else:
                            existing.pop(_key, None)
                    for _key in TURN_KEYS + ("transcript_path",):
                        existing.pop(_key, None)
                    existing.update(turn)
                    if transcript:
                        existing["transcript_path"] = transcript
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
        if secrets:
            payload["secrets"] = secrets
        if parent_id:
            payload["parent_id"] = parent_id
        if sensitive_paths:
            payload["sensitive_paths"] = sensitive_paths
        if terminal[1]:
            payload["tty_sid"] = terminal[1]
        if terminal[0]:
            payload["tty"] = terminal[0]
            if terminal[2]:
                payload["tty_start"] = terminal[2]
        payload.update(turn)
        if transcript:
            payload["transcript_path"] = transcript
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
        for (event, state) in AgentHookLayout.vscodeEvents {
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
        var primaryError: Error?

        for config in layout.files(for: .antigravity).configs {
            let target = config.url
            // The documented path is authoritative and always written. The others are only
            // updated when they already exist — creating them would scatter config the user
            // never asked for, and uninstall only strips what it finds.
            let isPrimary = config.write == .always
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

    /// The events whose entries must be present for a provider to count as installed.
    private static func requiredInstalledEvents(_ provider: AgentHookProvider) -> [String] {
        switch provider {
        case .cursor: return cursorEvents.map(\.event)
        case .vscode: return []
        case .codex: return claudeStyleEvents.map(\.event)
        case .claude:
            // Only the core events, deliberately. Requiring every entry in `claudeHookEntries`
            // would make an install from an older Kannu report "not installed" the moment the
            // table grows — which flips the Settings toggle off and, worse, makes the version
            // migration skip the very installs that need upgrading.
            return claudeCoreInstalledEvents
        case .antigravity: return antigravityEvents.map(\.event)
        case .gemini: return ["BeforeAgent", "BeforeTool", "AfterAgent"]
        case .qwen: return ["UserPromptSubmit", "PreToolUse", "Stop"]
        case .opencode: return []
        }
    }

    /// Installed: the script exists and ANY file the layout lists carries every required entry —
    /// Antigravity reads whichever of its files exists, and older installs seeded only one.
    private static func checkInstalled(_ provider: AgentHookProvider) -> Bool {
        let files = layout.files(for: provider)
        guard FileManager.default.fileExists(atPath: files.script.path) else { return false }
        if provider == .opencode {
            // The plugin file is Kannu's only if it carries Kannu's marker.
            guard let plugin = files.configs.first?.url,
                  let text = try? String(contentsOf: plugin, encoding: .utf8) else { return false }
            return text.contains(OpencodePluginSource.markerPrefix)
        }
        let events = requiredInstalledEvents(provider)
        return files.configs.contains { hasEntries(in: $0, events: events) }
    }

    private static func writeOpencodePlugin(to url: URL, scriptPath: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(OpencodePluginSource.source(scriptPath: scriptPath).utf8).write(to: url, options: .atomic)
    }

    /// Rewrites Kannu's opencode plugin when its own version marker moved (the shared script is
    /// covered by the script-version migration like every other provider's).
    private func migrateOpencodePluginIfNeeded() {
        guard let plugin = Self.layout.files(for: .opencode).configs.first?.url,
              let text = try? String(contentsOf: plugin, encoding: .utf8),
              text.contains(OpencodePluginSource.markerPrefix),
              !text.contains(OpencodePluginSource.versionMarker) else { return }
        install(.opencode)
    }

    private static func hasEntries(in config: AgentHookLayout.ConfigFile, events: [String]) -> Bool {
        if config.shape == .ownFile {
            return FileManager.default.fileExists(atPath: config.url.path)
        }
        guard let json = readJSON(at: config.url), let hooks = json["hooks"] as? [String: Any] else { return false }
        func isOurs(_ handler: [String: Any]) -> Bool { ((handler["command"] as? String)?.contains(scriptName)) == true }
        return events.allSatisfy { event in
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            switch config.shape {
            case .flatEntries:
                return entries.contains(where: isOurs)
            case .matcherGroups:
                return entries.contains { (($0["hooks"] as? [[String: Any]])?.contains(where: isOurs)) == true }
            case .ownFile:
                return true
            }
        }
    }

    /// Strips Kannu's entries in the shape the layout says the file has. Routing by a separate list
    /// once sent two Antigravity files to the flat-entry stripper, which matched nothing and left
    /// live entries behind in the file install always writes.
    private static func stripEntries(_ config: AgentHookLayout.ConfigFile) throws {
        guard var json = readJSON(at: config.url),
              var hooks = json["hooks"] as? [String: Any] else { return }
        switch config.shape {
        case .matcherGroups: stripCodexEntries(from: &hooks)
        case .flatEntries: stripCursorEntries(from: &hooks)
        case .ownFile: return
        }
        json["hooks"] = hooks
        try writeJSON(json, to: config.url)
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
        let scriptURLs = AgentHookProvider.allCases.map(Self.scriptURL(for:))
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
            case .codex, .claude, .antigravity:
                // The same files `checkInstalled` accepts: the layout's.
                configURLs = Self.layout.files(for: provider).configs.filter { $0.shape == .matcherGroups }.map(\.url)
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
            let scriptURL = Self.scriptURL(for: provider)
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
    /// Gemini CLI and Qwen Code: the script first, then Kannu's groups merged into the tool's own
    /// settings.json (a file the user edits by hand — refused, not rewritten, when it has comments).
    private static func installSharedSettingsHooks(for provider: AgentHookProvider, events: [(event: String, state: String)],
                                                   handlerName: String?, timeout: Int) throws {
        let files = layout.files(for: provider)
        guard let target = files.configs.first(where: { $0.write == .always }) else { return }
        let config = try readJSONRefusingComments(at: target.url)
        try writeScript(to: files.script)
        let merged = AgentHookLayout.mergingKannuGroups(into: config, events: events, script: files.script,
                                                        provider: provider.rawValue, handlerName: handlerName, timeout: timeout)
        try writeJSON(merged, to: target.url)
    }

    /// Gemini CLI and Qwen Code read settings.json with comments allowed. Kannu's writer would
    /// drop them, so such a file is refused with a plain reason instead of being rewritten.
    private static func readJSONRefusingComments(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        if let json = readJSON(at: url) { return json }
        if let data = try? Data(contentsOf: url),
           (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) is [String: Any] {
            throw NSError(
                domain: "Kannu.AgentHookInstaller", code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "\(url.lastPathComponent) has comments or trailing commas. Kannu won't rewrite it and lose them — remove them, or add the hook by hand (nothing was changed)."]
            )
        }
        return try readJSONForMerge(at: url)
    }

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
