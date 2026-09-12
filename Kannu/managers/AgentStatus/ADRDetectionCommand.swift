/*
 * Kannu (കണ്ണ്)
 * Copyright (C) 2024-2026 Kannu Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation

/// The ADR Detection invocation as data — docs/REGRESSIONS.md entry 8: a subprocess Kannu spawns
/// is pinned by tests, never assembled ad hoc. Kannu ships nothing of ADR: the user prepares a
/// Detection checkout (`git clone` + `uv sync`, Python 3.10–3.12), and Kannu runs its own GPL
/// adapter inside that project's environment with `uv run --project`.
///
/// What leaves the Mac when this runs: the transcript text goes to Anthropic through the Claude
/// CLI (the user's login, or `ANTHROPIC_API_KEY` when they chose that) and, only with triage on,
/// to OpenAI. Off by default; Kannu runs it on explicit request only.
enum ADRDetectionCommand {
    static let adapterFileName = "adr-analyze-session.py"
    static let adapterVersionMarker = "KANNU_ADR_ADAPTER_VERSION=2"
    /// Placeholder the adapter sets itself when triage is off; listed here so the environment
    /// builder never has to hand a real key to a run that will not use it.
    static let triageDisabledPlaceholder = "kannu-triage-disabled"
    /// Upstream's reasoning timeout is the largest single wait; the rest is uv/MCP start-up.
    static func processTimeout(forReasoningTimeout seconds: Int) -> TimeInterval {
        TimeInterval(seconds) + 120
    }

    struct Options: Equatable {
        var triageEnabled = false
        var triageModel = "gpt-4o"
        var reasoningModel = "claude-sonnet-4-6"
        var threatIntelligence = true
        var sourceCode = true
        var policy = true
        var timeoutSeconds = 300
        var maxTurns = 60
        var maxMessages = 400

        var contextList: String {
            [threatIntelligence ? "threat_intelligence" : nil,
             sourceCode ? "source_code" : nil,
             policy ? "policy" : nil].compactMap { $0 }.joined(separator: ",")
        }
    }

    /// `uv run --project <checkout> python <adapter> --transcript … --report … <options>`.
    static func arguments(checkout: URL, adapter: URL, transcript: URL, report: URL, options: Options) -> [String] {
        [
            "run", "--project", checkout.path,
            "python", adapter.path,
            "--transcript", transcript.path,
            "--report", report.path,
            "--triage", options.triageEnabled ? "on" : "off",
            "--triage-model", options.triageModel,
            "--reasoning-model", options.reasoningModel,
            "--context", options.contextList,
            "--timeout", String(options.timeoutSeconds),
            "--max-turns", String(options.maxTurns),
            "--max-messages", String(options.maxMessages)
        ]
    }

    /// The only shape Kannu may spawn: our adapter, inside the user's project, on one transcript.
    static func isValidAnalysis(arguments: [String]) -> Bool {
        guard arguments.count >= 8,
              arguments[0] == "run", arguments[1] == "--project", arguments[3] == "python",
              arguments[4].hasSuffix("/" + adapterFileName),
              let transcriptIndex = arguments.firstIndex(of: "--transcript"), transcriptIndex + 1 < arguments.count,
              arguments.contains("--report") else { return false }
        // The adapter alone decides how upstream runs its Claude session; Kannu never passes
        // permission or tool flags through.
        return !arguments.contains { $0.hasPrefix("--dangerously") || $0 == "--allowedTools" || $0 == "--disallowedTools" }
    }

    /// A whitelist, never the inherited environment: the keys Kannu chose to hand over, plus
    /// what `uv` and the Claude CLI need to find themselves.
    static func environment(openAIKey: String?, anthropicKey: String?, path: String, home: String) -> [String: String] {
        var env: [String: String] = ["PATH": path, "HOME": home, "LANG": "en_US.UTF-8"]
        if let key = openAIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            env["OPENAI_API_KEY"] = key
        }
        if let key = anthropicKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            env["ANTHROPIC_API_KEY"] = key
        }
        return env
    }

    static func producedVerdict(exitStatus: Int32) -> Bool { exitStatus == 0 }

    /// Where Kannu keeps the adapter it writes and the reports it reads.
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kannu/adr/detection", isDirectory: true)
    }

    /// The adapter, authoritative here and mirrored at `scripts/adr-analyze-session.py`
    /// (a test pins the two identical). Raw literal: backslashes and quotes stay verbatim; the
    /// trailing newline is added back because a multi-line literal drops the one before its
    /// closing delimiter.
    static let adapterSource = #"""
#!/usr/bin/env python3
# KANNU_ADR_ADAPTER_VERSION=2
#
# Kannu (കണ്ണ്) — Copyright (C) 2024-2026 Kannu Contributors — GPL-3.0-or-later.
#
# Kannu-owned adapter: run ADR Detection's ADRBaseline (github.com/uber/ADR, Apache-2.0) over
# one Claude Code transcript and print a small JSON verdict. Nothing of ADR is copied here; it
# is imported from the user's own Detection checkout, which `uv run --project` puts on the path.
#
# What leaves the Mac when this runs: the transcript text goes to Anthropic through the Claude
# CLI (the user's login, or ANTHROPIC_API_KEY when set) and, only with --triage on, to OpenAI.
# Kannu runs this on explicit request only.
import argparse
import dataclasses
import json
import os
import sys
import time
from pathlib import Path

TOOL_RESULT_CAP = 4000
TEXT_CAP = 20000


def _text_of(content):
    """Flatten a Claude Code content field (string or block list) into text."""
    if isinstance(content, str):
        return content
    parts = []
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict):
                if block.get("type") == "text" and isinstance(block.get("text"), str):
                    parts.append(block["text"])
                elif block.get("type") == "tool_result":
                    parts.append(_text_of(block.get("content")))
            elif isinstance(block, str):
                parts.append(block)
    return "\n".join(p for p in parts if p)


def load_transcript(path, max_messages):
    """Claude Code JSONL -> the message list ADRBaseline.analyze_conversation expects,
    mirroring main_detector._convert_conversation_to_messages: user text -> user, assistant
    text -> assistant with [TOOL_USE: name (id: id)] tags appended, tool results -> role tool."""
    messages = []
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue
            kind = record.get("type")
            message = record.get("message") if isinstance(record.get("message"), dict) else {}
            content = message.get("content")
            if kind == "user":
                blocks = content if isinstance(content, list) else []
                results = [b for b in blocks if isinstance(b, dict) and b.get("type") == "tool_result"]
                text = _text_of([b for b in blocks if not (isinstance(b, dict) and b.get("type") == "tool_result")]
                                if blocks else content)
                for result in results:
                    messages.append({"role": "tool", "content": _text_of(result.get("content"))[:TOOL_RESULT_CAP]})
                if text:
                    messages.append({"role": "user", "content": text[:TEXT_CAP]})
            elif kind == "assistant":
                blocks = content if isinstance(content, list) else []
                text = _text_of(content)[:TEXT_CAP]
                tags = []
                for block in blocks:
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        tags.append("[TOOL_USE: %s (id: %s)]" % (block.get("name", "unknown_tool"), block.get("id", "unknown_id")))
                combined = (text + " " + " ".join(tags)).strip() if tags else text
                if combined:
                    messages.append({"role": "assistant", "content": combined})
    if max_messages > 0 and len(messages) > max_messages:
        messages = messages[-max_messages:]
    return messages


def _first(mapping, keys):
    for key in keys:
        if isinstance(mapping, dict) and mapping.get(key) not in (None, ""):
            return mapping.get(key)
    return None


def main():
    parser = argparse.ArgumentParser(description="Run ADR Detection over one Claude Code transcript.")
    parser.add_argument("--transcript", required=True)
    parser.add_argument("--report", default="")
    parser.add_argument("--triage", choices=["on", "off"], default="off")
    parser.add_argument("--triage-model", default="gpt-4o")
    parser.add_argument("--reasoning-model", default="claude-sonnet-4-6")
    parser.add_argument("--context", default="threat_intelligence,source_code,policy")
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--max-turns", type=int, default=60)
    parser.add_argument("--max-messages", type=int, default=400)
    parser.add_argument("--convert-only", action="store_true")
    args = parser.parse_args()

    # Kannu builds these arguments itself (ADRDetectionCommand, pinned by tests), but this script
    # reads a file full of secrets and writes a report, so it checks them rather than trusting the
    # caller: the transcript is a .jsonl file that exists under the home folder, and the report can
    # only be written inside ~/.kannu.
    home = Path.home().resolve()
    transcript = Path(args.transcript).expanduser().resolve()
    if transcript.suffix != ".jsonl" or not transcript.is_file() or home not in transcript.parents:
        print(json.dumps({"schema": 1, "error": "the transcript must be an existing .jsonl file under the home folder"}))
        return 2
    report = None
    if args.report:
        report = Path(args.report).expanduser().resolve()
        if (home / ".kannu") not in report.parents:
            print(json.dumps({"schema": 1, "error": "the report must be written under ~/.kannu"}))
            return 2

    messages = load_transcript(transcript, args.max_messages)
    if args.convert_only:
        print(json.dumps({"schema": 1, "messages": messages}))
        return 0
    if not messages:
        print(json.dumps({"schema": 1, "error": "transcript holds no conversational records"}))
        return 3

    # ADRBaseline builds its OpenAI client eagerly even when triage is off; a placeholder keeps
    # the constructor happy and is never sent anywhere because triage never runs.
    if args.triage == "off":
        os.environ["OPENAI_API_KEY"] = "kannu-triage-disabled"
    elif not os.environ.get("OPENAI_API_KEY"):
        print(json.dumps({"schema": 1, "error": "triage is on but no OpenAI API key was provided"}))
        return 4

    try:
        from guardrail.adr_agent.adr_baseline import ADRBaseline
    except Exception as error:  # noqa: BLE001
        print(json.dumps({"schema": 1, "error": "cannot import ADR Detection: %s" % error}))
        return 5

    context = {token.strip() for token in args.context.split(",") if token.strip()}
    config = {
        "adr_framework": {
            "enable_triage": args.triage == "on",
            "triage_llm": {"model": args.triage_model, "temperature": 0, "max_tokens": 1000},
            "reasoning_agent": {
                "model": args.reasoning_model,
                "max_turns": args.max_turns,
                "timeout": args.timeout,
                "max_tokens": 10000,
                "enable_threat_intelligence": "threat_intelligence" in context,
                "enable_source_code": "source_code" in context,
                "enable_policy": "policy" in context,
            },
        }
    }
    started = time.time()
    try:
        detector = ADRBaseline(config_data=config, benchmark_type="adr_bench")
        result = detector.analyze_conversation(messages)
    except Exception as error:  # noqa: BLE001
        print(json.dumps({"schema": 1, "error": "analysis failed: %s" % error}))
        return 6

    if dataclasses.is_dataclass(result):
        raw = dataclasses.asdict(result)
    elif isinstance(result, dict):
        raw = result
    else:
        raw = {k: v for k, v in vars(result).items() if not k.startswith("_")}
    detections = raw.get("detections") or []
    first = detections[0] if detections and isinstance(detections[0], dict) else {}
    out = {
        "schema": 1,
        "is_malicious": bool(raw.get("is_malicious", False)),
        "confidence": float(raw.get("confidence_score") or 0.0),
        "tactic": _first(raw, ["threat_tactic", "tactic"]) or _first(first, ["tactic", "threat_tactic", "category", "technique"]),
        "explanation": str(_first(first, ["description", "explanation", "reasoning"]) or _first(raw, ["explanation", "reasoning"]) or ""),
        "threat_messages": raw.get("threat_messages"),
        "total_messages": raw.get("total_messages", len(messages)),
        "method": raw.get("method"),
        "model_used": raw.get("model_used"),
        "input_tokens": raw.get("input_tokens"),
        "output_tokens": raw.get("output_tokens"),
        "cost_usd": raw.get("cost_usd"),
        "analysis_seconds": round(time.time() - started, 1),
        "triage": args.triage,
        "messages_analyzed": len(messages),
    }
    if report is not None:
        try:
            report.parent.mkdir(parents=True, exist_ok=True)
            with open(report, "w", encoding="utf-8") as handle:
                json.dump({"verdict": out, "raw": raw}, handle, indent=2, default=str)
        except OSError as error:
            out["report_error"] = str(error)
    print(json.dumps(out, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
"""# + "\n"
}
