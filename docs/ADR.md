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

## 3. Run it on a schedule (optional)

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

## 4. Tenant policy (optional)

Discovery accepts `--policy policy.json` with `approved`, `forbidden` and `tenant_domains` lists;
`tenant_domains` enables the *third-party destination* finding. See the upstream Discovery README
for the format.

## 5. ADR Sensor (optional)

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
