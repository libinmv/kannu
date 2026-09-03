#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="$HOME/.cursor/hooks"
HOOKS_CONFIG="$HOME/.cursor/hooks.json"
SCRIPT_NAME="kannu-agent-status.sh"

mkdir -p "$HOOKS_DIR"
cp "$REPO_ROOT/scripts/$SCRIPT_NAME" "$HOOKS_DIR/$SCRIPT_NAME"
chmod 755 "$HOOKS_DIR/$SCRIPT_NAME"

python3 <<'PY'
import json
from pathlib import Path

config_path = Path.home() / ".cursor/hooks.json"
events = [
    ("beforeSubmitPrompt", "thinking"),
    ("afterAgentThought", "thinking"),
    ("afterAgentResponse", "executing"),
    ("preToolUse", "executing"),
    ("postToolUse", "executing"),
    ("postToolUseFailure", "executing"),
    ("beforeMCPExecution", "executing"),
    ("stop", "stopped"),
]
config = {}
if config_path.exists():
    try:
        config = json.loads(config_path.read_text())
    except json.JSONDecodeError:
        config = {}

hooks = config.get("hooks", {})
for event, state in events:
    entries = hooks.get(event, [])
    entries = [
        entry for entry in entries
        if "kannu-agent-status" not in (entry.get("command") or "")
        and "atoll-agent-status" not in (entry.get("command") or "")
    ]
    entries.append({"command": f"hooks/{Path('kannu-agent-status.sh').name} {state} cursor {event}"})
    hooks[event] = entries

config["version"] = config.get("version", 1)
config["hooks"] = hooks
config_path.write_text(json.dumps(config, indent=2) + "\n")
print(f"Installed hooks into {config_path}")
PY

echo "Hook script: $HOOKS_DIR/$SCRIPT_NAME"
head -3 "$HOOKS_DIR/$SCRIPT_NAME"
