#!/bin/bash
# Installed by Kannu: reports AI agent status for the notch traffic light.
# KANNU_HOOK_SCRIPT_VERSION=34
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
