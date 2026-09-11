# Connecting ADR to Kannu

Kannu can show security findings from [ADR](https://github.com/uber/ADR) — Uber's open-source
Agentic Detection and Response toolkit (Apache-2.0). ADR is a **separate install** that you own;
Kannu connects to it. Kannu never installs ADR, never edits your MCP configurations, and never
sends a finding anywhere unless you turn on push notifications.

## 1. Install ADR Discovery (once)

Discovery inventories the AI tools on this Mac and raises findings such as an MCP server that
resolves an unpinned package at launch, or one reached over plain HTTP. It needs Python 3.11 or
newer; `uv` brings its own interpreter, so nothing else is required.

```bash
uv tool install "adr-discovery @ git+https://github.com/uber/ADR#subdirectory=Discovery"
```

pipx works the same way:

```bash
pipx install "git+https://github.com/uber/ADR#subdirectory=Discovery"
```

Then open Kannu → Settings → Agents → **Security findings** and press **Check again**. Kannu looks
in `~/.local/bin`, uv's tool directory, `/opt/homebrew/bin` and `/usr/local/bin`; a different
location can be set with the "ADR tool directory" setting.

## 2. Produce a snapshot

Kannu reads the newest `snapshot-*.json` in its snapshot folder (default
`~/.kannu/adr/discovery`, changeable in Settings). Run a scan into it:

```bash
adr-discovery --json --output-dir ~/.kannu/adr/discovery > /dev/null
```

Findings appear in Settings within a second of the file landing. Exit code `2` means the scan
could not read everything (a denied directory, an unavailable probe); Kannu shows that as
*partial coverage* rather than claiming the machine is clean.

To see exactly what Discovery collects before you run it:

```bash
adr-discovery --dry-run --explain
```

It reports paths, metadata and allowlisted config keys — never file contents; environment variable
*names* only; credential-bearing flag values replaced; URLs stripped of user info and query strings;
and no access at all under personal folders such as `~/.ssh`, `Documents`, `Mail` and `Messages`.

## 3. Let Kannu run it (default once connected)

With Discovery connected, Settings → Agents → Security findings → **Let Kannu run scans** makes
Kannu invoke `adr-discovery --json --output-dir <snapshot folder>` itself: once a day, sooner
after one of your MCP configuration files changes on disk (`~/.claude.json`, `~/.claude/mcp.json`,
`~/.cursor/mcp.json`, `~/.codex/config.toml`, Claude Desktop's config), and whenever you press
**Scan now**. The exact command is fixed in code and pinned by tests; Kannu never adds flags to it.
Turn the toggle off if something else already schedules Discovery — Kannu then only reads.

## 4. How a high-severity finding gets your attention

- **In the closed notch:** a monochrome shield pill beside the traffic light — never a fourth
  light colour — that stays until you acknowledge the finding (default). Settings offers
  *For 5 seconds, then glyph*, *Glyph only* and *Off*. While a Focus mode is on, only the small
  glyph shows; the pill appears when Focus ends. Clicking the pill opens the panel.
- **In the panel:** the finding is pinned above the primary session with Details and Acknowledge;
  medium findings appear as a count beside "Recent chats".
- **On your phone:** with mobile notifications on, each new high finding is pushed once
  (priority 5, the same as "needs input"); medium ones only if you enable that.
- **Kannu's own findings:** a session started with permission checks bypassed
  (`claude --dangerously-skip-permissions`, Codex `approval_policy = never`) is reported by Kannu
  from the hook payload — Discovery cannot see process arguments on macOS.
- **Hidden text (Kannu's own, on by default, local):** the hook looks at what agents read and write
  — prompts, tool results, tool input — for characters a person cannot see but a model reads:
  Unicode tag characters ("ASCII smuggling"), bytes hidden in variation selectors, right-to-left
  overrides on a line with no right-to-left letters (Trojan Source), long zero-width runs. No model,
  nothing sent. A sighting is high when it decodes to readable text; the decoded text is only ever
  shown inside Kannu, never pushed. "Tell the agent when hidden text is found" (off by default)
  adds one factual sentence to the agent's context — never the hidden text.
- **Secrets (Kannu's own, on by default, local):** API keys and private keys in a prompt or in what
  an agent hands a tool (AWS, GitHub, GitLab, Slack, Stripe live, Anthropic, OpenAI, Google, npm,
  Hugging Face, PEM/OpenSSH/PGP private keys). Tool results are never scanned. The hook keeps only
  the kind, the vendor prefix, the length and the first 12 hex digits of the SHA-256 — never the
  key. High when the agent used a key in a command or any non-file tool; medium for a file edit or
  your own prompt.
- **Sensitive files (Kannu's own, on by default, local):** after a tool ran, the paths it read or
  changed — SSH and GPG keys, cloud and Git credentials, AI tools' sign-in files, password stores,
  the keychain (including `security find-generic-password`), browser profiles, `.env` files, shell
  history — and changes to files that run code on their own (LaunchAgents, `crontab`, Git hooks,
  `authorized_keys`), shell startup files and agent settings (`.claude/settings.json`, `.mcp.json`,
  Codex `config.toml`, Kannu's own `~/.kannu`). Reading a startup file or an agent's settings is
  ordinary and not reported. Paths come from file tools and from parsing shell commands; code that
  opens a file from inside `python -c` is not seen.

## 5. Run it on your own schedule (optional)

Kannu does not install launch agents. If you want a daily scan, save this as
`~/Library/LaunchAgents/dev.kannu.adr-discovery.plist` and load it with
`launchctl load ~/Library/LaunchAgents/dev.kannu.adr-discovery.plist`. Adjust the path to
`adr-discovery` (`which adr-discovery`).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.kannu.adr-discovery</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/YOU/.local/bin/adr-discovery</string>
    <string>--json</string>
    <string>--output-dir</string>
    <string>/Users/YOU/.kannu/adr/discovery</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>/Users/YOU/.kannu/adr/discovery/launchd.log</string>
</dict>
</plist>
```

Fleet deployments that already run Discovery from their own scheduler only need to point Kannu's
snapshot folder at wherever those snapshots land.

## 6. Tenant policy (optional)

Discovery accepts `--policy policy.json` with `approved`, `forbidden` and `tenant_domains` lists;
`tenant_domains` enables the *third-party destination* finding. See the upstream Discovery README
for the format. Point Kannu at it with Settings → Security findings → **Policy file**; Kannu passes
it to every scan it runs.

## 8. Session analysis with ADR Detection (opt-in, off by default)

Detection (`ADR/Detection`) judges a *finished* chat's transcript: a local hidden-Unicode check,
an optional gpt-4o triage pass (OpenAI), then a Claude reasoning agent that runs as an unattended
`claude -p` session on your Mac with three local MCP context servers. It is Uber's research tool
(Apache-2.0, "not for production"); Kannu only runs it when you ask, and never ships it.

Setup, all yours:

```bash
git clone https://github.com/uber/ADR && cd ADR/Detection && uv sync   # Python 3.10–3.12
npm install -g @anthropic-ai/claude-code && claude auth login           # if not already
```

Then Settings → Agents → Security findings → **Analyze chats with ADR Detection** (a consent
alert names what leaves the Mac), choose the `Detection` folder, and optionally store keys:
an OpenAI key if you turn **Triage with OpenAI first** on (off = Claude only), an Anthropic API
key if you would rather spend API credits than your subscription's 5-hour/weekly quota.
Model names, the three context servers, the reasoning timeout and the message cap (newest N
messages, because upstream sends the whole transcript and a long one exceeds the model's
context) are all editable.

Run one: right-click a finished Claude Code chat in the notch → **Analyze with ADR Detection…**.
By default a confirmation names the transcript and the providers every time. The verdict shows
under the chat ("ADR: clean · 0.08" or the tactic and confidence); a malicious verdict becomes a
finding — high when confidence ≥ 0.8, medium otherwise — and rides the same shield/pill/card/push
path as every other finding. Reports are kept under `~/.kannu/adr/detection/` (reveal from the
chat's menu or Settings).

What leaves the Mac, exactly: the chosen transcript text, to Anthropic (your login or your key)
and, only with triage on, to OpenAI. Nothing else, nothing automatic, nothing without your click.
The adapter Kannu runs is its own GPL script (`scripts/adr-analyze-session.py`, written to
`~/.kannu/adr/detection/` at run time); it imports ADR from your checkout and copies nothing.

## 7. ADR Sensor (optional)

`adr-sensor` exports normalised session records for Claude Code, Cursor, Codex, Warp, Claude
Desktop, Cline and opencode. Kannu already reads those sources itself; the Sensor is useful when
your security team wants sessions in a SIEM. Install with `uv tool install adr-sensor`. Kannu will
read `adr-sensor --save-sessions` output from `~/.cache/adr_sensor` (changeable) in a later
release.

## What Kannu does with findings

- Lists them in Settings → Agents → Security findings, highest severity first, with Acknowledge
  and Snooze. Acknowledgements are per finding: if a finding disappears and later returns with
  different evidence, it is shown again.
- Never changes the traffic light. Green, yellow and red keep meaning working, needs input, and
  finished; a security finding is shown with a shield instead.
- Never terminates a process, edits a configuration file, or installs software.

## Licence

ADR is licensed under the Apache License 2.0 and is not distributed with Kannu. Kannu (GPL-3.0-or-later)
runs the separately installed programs and reads the files they write; no ADR code is included in
Kannu. "ADR" and "Uber" are their owners' marks; Kannu references them only to identify the tool.
