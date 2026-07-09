#!/bin/bash
# Installed by Kannu: reports AI agent status for the notch traffic light.
# KANNU_HOOK_SCRIPT_VERSION=14
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
    } or lower in {"web_search", "web_fetch", "ask_question"}

def looks_gated_payload(payload: str) -> bool:
    lower = payload.lower()
    return any(
        token in lower
        for token in (
            "search_term", "searchterm", "websearch", "webfetch",
            "askquestion", "ask_question", '"questions"',
        )
    )

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

def is_ask_question() -> bool:
    compact = (tool or "").lower().replace("_", "").replace("-", "")
    if compact in {"askquestion", "userquestion"}:
        return True
    return isinstance(tool_input, dict) and "questions" in tool_input

# Timing (Cursor):
# - WebSearch approval card appears BEFORE preToolUse. preToolUse runs after approve.
# - So WebSearch must NOT set awaiting_input on preToolUse (that paints yellow too late).
# - afterAgentResponse / transcript catch the proposal while the card is open.
# - AskQuestion still uses preToolUse for yellow (card is the tool itself).
if hook_event == "afterAgentResponse":
    if looks_gated_payload(raw):
        state = "awaiting_input"
elif hook_event in {"preToolUse", "beforeMCPExecution"}:
    if is_ask_question():
        state = "awaiting_input"
    else:
        # Includes WebSearch/WebFetch: approval already granted; tool is running.
        state = "executing"
elif hook_event in {"postToolUse", "postToolUseFailure"}:
    state = "executing"
elif hook_event == "stop":
    state = "stopped"

conversation_id = pick_str(
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

# Sticky yellow only against thinking noise — never block preToolUse from clearing
# to green (WebSearch starts after the user already approved).
if existing_state == "awaiting_input" and state not in {"awaiting_input", "stopped"}:
    if hook_event in {"beforeSubmitPrompt", "afterAgentThought"}:
        existing["state"] = "awaiting_input"
        existing["ts"] = int(time.time() * 1000)
        existing["provider"] = provider
        status_file.write_text(json.dumps(existing, separators=(",", ":")))
        print('{"permission":"allow","continue":true}')
        raise SystemExit(0)

name = pick_str(data.get("name"), data.get("title"), data.get("conversation_title"))
roots = data.get("workspace_roots")
project = ""
if isinstance(roots, list) and roots:
    root = str(roots[0]).replace("file://", "").rstrip("/")
    if root:
        project = Path(root).name

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
