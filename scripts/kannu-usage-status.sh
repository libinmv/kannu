#!/bin/bash
# Installed by Kannu: forwards Claude Code rate-limit usage to the notch.
# KANNU_USAGE_SCRIPT_VERSION=4
# KANNU_USAGE_CHAIN_B64=
# Reads the Claude Code statusLine JSON from stdin, writes rate-limit usage to
# the Kannu status directory, then chains the user's original statusLine (if any).
# NOTE: generated mirror of the embedded script in AgentHookInstaller.swift
# (writeUsageScript). Do not edit directly; keep in lockstep with the embedded copy.

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

CHAIN_B64="$(grep -m1 '^# KANNU_USAGE_CHAIN_B64=' "$0" | cut -d= -f2-)"
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
