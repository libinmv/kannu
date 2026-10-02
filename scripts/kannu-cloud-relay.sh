#!/usr/bin/env bash
# KANNU_CLOUD_RELAY_VERSION=1
#
# Kannu (കണ്ണ്) — Copyright (C) 2024-2026 Kannu Contributors — GPL-3.0-or-later.
#
# Tells Kannu, on your Mac, what a Claude Code *cloud* session is doing. Commit this file to a
# repository as .claude/hooks/kannu-cloud-relay.sh, with the hooks Kannu gives you in
# .claude/settings.json. It does nothing at all unless it runs inside a cloud session
# (CLAUDE_CODE_REMOTE=true) whose environment holds KANNU_RELAY_SECRET.
#
# What leaves the session, signed with a key derived from the secret: the session id, the
# light's state, the hook event, the notification kind, the repository folder's name and a
# timestamp. Never a prompt, a command, a file, a path or any output. It is sent to an ntfy
# relay (https://ntfy.sh unless KANNU_RELAY_URL says otherwise) on a topic derived from the
# secret, and only when the light changes colour or every 4 minutes while it stays the same.
#
#   bash .claude/hooks/kannu-cloud-relay.sh --check     # explain the setup, send a test message
if [ "${1:-}" != "--check" ]; then
  [ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
  [ -n "${KANNU_RELAY_SECRET:-}" ] || exit 0
fi
if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  [ "${1:-}" = "--check" ] && echo "Kannu cloud relay: python3 and curl are both required."
  exit 0
fi
read -r -d '' KANNU_RELAY_PROGRAM <<'PY' || true
import fcntl, hashlib, hmac, json, os, re, stat, subprocess, sys, time

VERSION = 1
REFRESH_MS = 240000
YELLOW_HOLD_MS = 2000
STATES = {"idle", "thinking", "executing", "awaiting_input", "stopped", "session_end"}
EVENTS = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
          "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"}
NOTES = {"permission_prompt", "idle_prompt", "agent_needs_input", "agent_completed"}
QUESTION_TOOLS = {"AskUserQuestion", "ExitPlanMode"}
SESSION_RE = re.compile(r"^(session|cse)_[A-Za-z0-9]{1,64}$")
SECRET_RE = re.compile(r"^[0-9a-f]{64}$")
URL_RE = re.compile(r"^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~-]+)*$")
DEFAULT_URL = "https://ntfy.sh"


def secret():
    value = os.environ.get("KANNU_RELAY_SECRET", "").strip().lower()
    return value if SECRET_RE.match(value) else None


def server_url():
    value = (os.environ.get("KANNU_RELAY_URL", "").strip() or DEFAULT_URL).rstrip("/")
    return value if URL_RE.match(value) and "@" not in value else None


def derive(key):
    topic = "kannu-" + hashlib.sha256(("kannu-relay-topic|" + key).encode()).hexdigest()[:32]
    mac_key = hashlib.sha256(("kannu-relay-mac|" + key).encode()).digest()
    return topic, mac_key


def session_id():
    value = os.environ.get("CLAUDE_CODE_REMOTE_SESSION_ID", "").strip()
    return value if SESSION_RE.match(value) else None


def repo_name(data):
    base = os.environ.get("CLAUDE_PROJECT_DIR", "") or str(data.get("cwd") or "")
    name = os.path.basename(base.rstrip("/"))
    return re.sub(r"[^A-Za-z0-9._-]", "-", name)[:64]


def now_ms():
    return int(time.time() * 1000)


def body(key, session, state, event, note, repo, ts):
    topic, mac_key = derive(key)
    payload = json.dumps({"event": event, "kind": "kannu-cloud", "note": note, "repo": repo,
                          "session": session, "state": state, "ts": ts, "v": VERSION},
                         sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    mac = hmac.new(mac_key, payload.encode("ascii"), hashlib.sha256).hexdigest()
    return topic, "KC1 " + mac + " " + payload


def post(url, text):
    """The HTTP status as a string, or an error message. Never raises."""
    command = ["curl", "-sS", "--proto", "=https", "--max-redirs", "0", "--connect-timeout", "3",
               "-m", "5", "-o", "/dev/null", "-w", "%{http_code}", "-H", "Firebase: no",
               "-H", "Content-Type: text/plain", "--data-binary", "@-", url]
    try:
        done = subprocess.run(command, input=text.encode("ascii"), stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=8)
    except Exception as error:  # noqa: BLE001
        return "error: " + type(error).__name__
    code = done.stdout.decode("ascii", "replace").strip()
    if done.returncode != 0 and not code.strip("0"):
        return "error: curl exit " + str(done.returncode)
    return code


def read_payload():
    try:
        raw = sys.stdin.buffer.read(16 * 1024 * 1024)
        data = json.loads(raw.decode("utf-8", "replace")) if raw.strip() else {}
    except Exception:  # noqa: BLE001
        return {}
    return data if isinstance(data, dict) else {}


def colour_key(state, note, event):
    if state in ("thinking", "executing"):
        return "green"
    if state == "awaiting_input":
        return "yellow:idle" if note == "idle_prompt" else "yellow"
    if state == "stopped":
        return "red:fail" if event == "StopFailure" else "red"
    return "end" if state == "session_end" else "idle"


class StateFile:
    """Per-session memory of what was last sent, under an exclusive lock in a private folder."""

    def __init__(self, session):
        self.data = {}
        self.lock = None
        self.path = None
        base = os.path.join(os.environ.get("TMPDIR") or "/tmp", "kannu-cloud-relay-" + str(os.getuid()))
        try:
            os.makedirs(base, mode=0o700, exist_ok=True)
            info = os.lstat(base)
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                return
            self.lock = open(os.path.join(base, ".lock"), "a")
            fcntl.flock(self.lock, fcntl.LOCK_EX)
            self.path = os.path.join(base, session + ".json")
            with open(self.path) as handle:
                loaded = json.load(handle)
            self.data = loaded if isinstance(loaded, dict) else {}
        except Exception:  # noqa: BLE001
            pass

    def save(self, **values):
        self.data.update(values)
        if not self.path:
            return
        try:
            temporary = self.path + ".tmp"
            with open(temporary, "w") as handle:
                json.dump(self.data, handle)
            os.replace(temporary, self.path)
        except Exception:  # noqa: BLE001
            pass

    def close(self):
        if self.lock:
            try:
                fcntl.flock(self.lock, fcntl.LOCK_UN)
                self.lock.close()
            except Exception:  # noqa: BLE001
                pass


def hook(arguments):
    state = arguments[0] if len(arguments) > 0 else ""
    event = arguments[1] if len(arguments) > 1 else ""
    matcher = arguments[2] if len(arguments) > 2 else ""
    key, session, url = secret(), session_id(), server_url()
    if not key or not session or not url or state not in STATES or event not in EVENTS:
        return
    data = read_payload()
    tool_input = data.get("tool_input")
    if event == "SessionStart" and data.get("source") in ("compact", "resume"):
        return
    if event == "PreToolUse" and not matcher and (
            str(data.get("tool_name") or "") in QUESTION_TOOLS
            or (isinstance(tool_input, dict) and "questions" in tool_input)):
        return  # the question's own matcher group reports it, as yellow
    if event == "PostToolUseFailure" and data.get("is_interrupt") is True:
        state = "stopped"
    note = ""
    if event == "Notification":
        kind = str(data.get("notification_type") or "")
        note = kind if kind in NOTES else ""
    colour = colour_key(state, note, event)
    memory = StateFile(session)
    try:
        last = str(memory.data.get("key") or "")
        last_ms = int(memory.data.get("sent_ms") or 0)
        last_event = str(memory.data.get("event") or "")
        now = now_ms()
        if data.get("agent_id") and not colour.startswith("yellow") and last != "green":
            return  # a subagent never relights a chat that has finished
        if colour == "green" and last.startswith("yellow") and last_event in (
                "PermissionRequest", "Notification", "PreToolUse") and now - last_ms < YELLOW_HOLD_MS:
            return  # a sibling tool call must not paint over an open prompt
        if colour == last and now - last_ms < REFRESH_MS:
            return
        ts = max(now, int(memory.data.get("ts") or 0) + 1)
        topic, text = body(key, session, state, event, note, repo_name(data), ts)
        status = post(url + "/" + topic, text)
        if status == "200":
            memory.save(key=colour, event=event, sent_ms=now, ts=ts)
        else:
            memory.save(ts=ts)
    finally:
        memory.close()


def check():
    say = print
    say("Kannu cloud relay check (v%d)" % VERSION)
    remote = os.environ.get("CLAUDE_CODE_REMOTE") == "true"
    say("- Cloud session: " + ("yes" if remote else "no (this only reports from cloud sessions)"))
    session = session_id()
    say("- Session id: " + ("found" if session else "missing (CLAUDE_CODE_REMOTE_SESSION_ID)"))
    raw_secret = os.environ.get("KANNU_RELAY_SECRET", "")
    key = secret()
    say("- KANNU_RELAY_SECRET: " + ("set" if key else ("malformed: copy it again from Kannu" if raw_secret else
                                                        "missing: paste Kannu's variables into this environment")))
    url = server_url()
    say("- Relay server: " + (url if url else "KANNU_RELAY_URL is not a plain https:// address"))
    if not key or not url:
        return
    topic, text = body(key, session or "session_Check", "idle", "Check", "", "", now_ms())
    status = post(url + "/" + topic, text)
    host = url.split("/")[2]
    if status == "200":
        say("- Test message: delivered. Kannu should now say \"test received\".")
    elif status == "403":
        say("- Test message: refused (HTTP 403). Set this environment's Network access to Custom and allow " + host + ".")
    elif status == "429":
        say("- Test message: refused (HTTP 429). The relay's quota for this network is used up; try later or self-host ntfy.")
    else:
        say("- Test message: failed (" + status + "). Check that " + host + " is allowed in Network access.")
    if url == DEFAULT_URL:
        try:
            done = subprocess.run(["curl", "-sS", "-m", "5", url + "/v1/account"], stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, timeout=8)
            remaining = json.loads(done.stdout.decode("utf-8", "replace")).get("stats", {}).get("messages_remaining")
            if isinstance(remaining, int):
                say("- ntfy.sh messages left today from this network: %d" % remaining)
        except Exception:  # noqa: BLE001
            pass


if len(sys.argv) > 1 and sys.argv[1] == "--check":
    check()
else:
    hook(sys.argv[1:])
PY
if [ "${1:-}" = "--check" ]; then
  python3 -I -c "$KANNU_RELAY_PROGRAM" "$@"
  exit 0
fi
python3 -I -c "$KANNU_RELAY_PROGRAM" "$@" >/dev/null 2>&1
exit 0
