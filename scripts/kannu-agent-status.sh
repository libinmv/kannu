#!/bin/bash
# Installed by Kannu: reports AI agent status for the notch traffic light.
# KANNU_HOOK_SCRIPT_VERSION=30
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
    print('{"permission":"allow","continue":true}')
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
