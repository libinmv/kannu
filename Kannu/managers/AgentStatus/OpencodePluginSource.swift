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

/// The opencode plugin Kannu installs (`~/.config/opencode/plugins/kannu-agent-status.js`).
/// opencode has no shell-hook settings; it loads every plugin in that folder into its Bun runtime.
/// The plugin only maps opencode's events onto the shared status script, which does the rest.
/// Kept here, not beside the hook script in `AgentHookInstaller.swift`: the pre-commit hook and
/// `HookScriptTests` take the first `let script = """` literal in that file to be the hook script.
///
/// Event mapping (subagent sessions — those with a `parentID` — are skipped):
/// `session.created` SessionStart · `chat.message` UserPromptSubmit · `tool.execute.before`
/// PreToolUse · `tool.execute.after` PostToolUse · `permission.asked` / `permission.updated` /
/// `question.asked` PermissionRequest · their `…replied`/`rejected` PermissionReplied (thinking)
/// · `session.idle` Stop · `session.error` StopFailure · `session.deleted` SessionEnd. Titles come
/// from `session.updated`. `permission.updated` is the older name (renamed January 2026).
enum OpencodePluginSource {
    static let versionMarker = "KANNU_OPENCODE_PLUGIN_VERSION=1"
    static let markerPrefix = "KANNU_OPENCODE_PLUGIN_VERSION="
    static let fileName = "kannu-agent-status.js"
    private static let scriptPlaceholder = "__KANNU_SCRIPT_PATH__"

    /// The plugin with the status script's path baked in as a JavaScript string literal.
    static func source(scriptPath: String) -> String {
        template.replacingOccurrences(of: scriptPlaceholder, with: javaScriptString(scriptPath))
    }

    static func javaScriptString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    private static let template = #"""
// Installed by Kannu: reports opencode session status for the notch traffic light.
// KANNU_OPENCODE_PLUGIN_VERSION=1
// Every event is handed to Kannu's shared status script as an argv array (never a shell
// string) with the details as JSON on stdin, exactly like the other agents' hooks. Nothing is
// awaited and every call is wrapped, so status reporting can never slow or break a session.
const KANNU_SCRIPT = __KANNU_SCRIPT_PATH__;
const KANNU_MAX_TEXT = 200000;
const KANNU_NEWLINE = String.fromCharCode(10);

const KannuAgentStatus = async ({ directory }) => {
  const subagents = new Set();
  const titles = new Map();
  const toolArgs = new Map();

  const send = (state, event, sessionID, extra) => {
    if (typeof sessionID !== "string" || !sessionID || subagents.has(sessionID)) return;
    try {
      const payload = Object.assign({ session_id: sessionID, hook_event_name: event, cwd: directory || "" }, extra || {});
      const title = titles.get(sessionID);
      if (title) payload.conversation_title = title;
      Bun.spawn([KANNU_SCRIPT, state, "opencode", event], {
        stdin: new Blob([JSON.stringify(payload)]),
        stdout: "ignore",
        stderr: "ignore",
      });
    } catch (error) {
      // Status reporting must never disturb the session.
    }
  };

  const clip = (value) => (typeof value === "string" ? value.slice(0, KANNU_MAX_TEXT) : "");

  const textOf = (parts) => (Array.isArray(parts) ? parts : [])
    .filter((part) => part && part.type === "text" && typeof part.text === "string")
    .map((part) => part.text)
    .join(KANNU_NEWLINE);

  return {
    event: async ({ event }) => {
      try {
        const type = event && event.type;
        const props = (event && event.properties) || {};
        const info = props.info || {};
        switch (type) {
          case "session.created":
            if (info.parentID) {
              subagents.add(info.id);
              return;
            }
            if (info.title) titles.set(info.id, info.title);
            send("idle", "SessionStart", info.id, { source: "startup" });
            return;
          case "session.updated":
            if (!info.parentID && info.id && info.title) titles.set(info.id, info.title);
            return;
          case "permission.asked":
          case "permission.updated":
          case "question.asked":
            send("awaiting_input", "PermissionRequest", props.sessionID);
            return;
          case "permission.replied":
          case "question.replied":
          case "question.rejected":
            send("thinking", "PermissionReplied", props.sessionID);
            return;
          case "session.idle":
            send("stopped", "Stop", props.sessionID);
            return;
          case "session.error":
            send("stopped", "StopFailure", props.sessionID);
            return;
          case "session.deleted":
            send("session_end", "SessionEnd", info.id);
            subagents.delete(info.id);
            titles.delete(info.id);
            return;
          default:
            return;
        }
      } catch (error) {
        // Never disturb the session.
      }
    },
    "chat.message": async (input, output) => {
      try {
        send("thinking", "UserPromptSubmit", input && input.sessionID, { prompt: clip(textOf(output && output.parts)) });
      } catch (error) {
        // Never disturb the session.
      }
    },
    "tool.execute.before": async (input, output) => {
      try {
        const args = (output && output.args) || {};
        if (input && input.callID) {
          toolArgs.set(input.callID, args);
          if (toolArgs.size > 200) toolArgs.delete(toolArgs.keys().next().value);
        }
        send("executing", "PreToolUse", input && input.sessionID,
             { tool_name: input && input.tool, tool_input: args, tool_use_id: input && input.callID });
      } catch (error) {
        // Never disturb the session.
      }
    },
    "tool.execute.after": async (input, output) => {
      try {
        const args = (input && input.args) || toolArgs.get(input && input.callID) || {};
        if (input && input.callID) toolArgs.delete(input.callID);
        send("thinking", "PostToolUse", input && input.sessionID,
             { tool_name: input && input.tool, tool_input: args, tool_use_id: input && input.callID,
               tool_response: { output: clip(output && output.output) } });
      } catch (error) {
        // Never disturb the session.
      }
    },
  };
};

export { KannuAgentStatus };
"""#
}
