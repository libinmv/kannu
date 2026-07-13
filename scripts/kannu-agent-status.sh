#!/bin/bash
# Installed by Kannu: reports AI agent status for the notch traffic light.
# KANNU_HOOK_SCRIPT_VERSION=23
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
