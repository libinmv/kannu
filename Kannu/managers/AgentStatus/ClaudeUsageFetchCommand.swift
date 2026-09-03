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

/// How Kannu invokes Claude Code to refresh usage — extracted so the decisions are testable.
///
/// Two shipped regressions came from "harmless" additions to this invocation, each of which broke
/// the fetch silently while everything still looked healthy:
///
/// 1. `--no-session-persistence` — rejected outside `--print` ("can only be used with --print
///    mode"), so the session exited before `/usage` was ever typed.
/// 2. `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` — suppresses nonessential network traffic, and
///    the usage fetch is a network call, so the session ran and fetched nothing.
///
/// Both were reasoned about rather than verified. The rules below are pinned by
/// `ClaudeUsageFetchCommandTests`; see docs/REGRESSIONS.md.
enum ClaudeUsageFetchCommand {
    /// Flags Claude Code accepts only alongside `--print`. Passing one to the interactive session
    /// this fetch needs makes the CLI exit immediately.
    static let printOnlyFlags: Set<String> = [
        "--no-session-persistence",
        "--input-format",
        "--output-format",
        "--replay-user-messages"
    ]

    /// Environment variables that break the fetch. `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`
    /// silences exactly the request we are trying to make.
    static let forbiddenEnvironmentKeys: Set<String> = [
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
    ]

    /// Attempts in order. The first tries to suppress the remote-control device registration (the
    /// phantom chat); the last is bare, which is the invocation observed to actually fetch, so it
    /// must stay as the final fallback.
    static let attempts: [[String]] = [
        ["--settings", #"{"disableRemoteControl":true}"#],
        []
    ]

    /// `/usage` needs an interactive session (the command is declared `requires: {ink}`), so any
    /// print-only flag is invalid here.
    static func isValidForInteractiveSession(arguments: [String]) -> Bool {
        !arguments.contains { printOnlyFlags.contains($0) }
    }

    /// The child's environment. Returning nil means plain inheritance — what the working version
    /// did. Anything else risks re-introducing regression 2, so this deliberately offers no way to
    /// add variables.
    static func environment() -> [String: String]? { nil }
}
