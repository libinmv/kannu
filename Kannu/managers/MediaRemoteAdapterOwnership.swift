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

/// Which `mediaremote-adapter.pl` processes this build of Kannu may terminate.
///
/// `NowPlayingController` spawns the adapter as a long-lived `perl` child that streams now-playing
/// JSON. It outlived its parent for a long time — measured on the development machine: nine alive at
/// once, eight of them reparented to `launchd`, the oldest fourteen hours, across four different
/// bundle paths, **three of them from `/Applications`** — so this is not only a side effect of
/// rebuilding. The leak itself is fixed by `NowPlayingController.stop()`; this exists because the app
/// is force-quit and does crash, and those orphans have to be cleared at the next launch.
///
/// The predicate has to be exact, and the tempting shortcuts are all wrong:
///
/// - `killall perl` would take out unrelated user processes.
/// - Matching the basename `mediaremote-adapter.pl` would take out the helpers of *other* Kannu
///   bundles — a `/Applications` install and several build products coexist on a developer's machine,
///   and terminating another build's live helper looks exactly like a bug in that build.
/// - Ignoring the parent would take out a helper whose Kannu is running and using it.
///
/// So: the argv must name **this** bundle's own script path, as a whole token, and the process must
/// already be orphaned to `launchd`.
enum MediaRemoteAdapterOwnership {
    /// PID 1 — `launchd`. A helper reparented here has lost the Kannu that spawned it.
    static let orphanParentPID: Int32 = 1

    /// - Parameters:
    ///   - command: the process's full argv, space-joined.
    ///   - parentPID: its current parent.
    ///   - ownScriptPath: the absolute path of *this* bundle's `mediaremote-adapter.pl`.
    static func isReapable(command: String, parentPID: Int32, ownScriptPath: String) -> Bool {
        guard parentPID == orphanParentPID else { return false }
        guard !ownScriptPath.isEmpty else { return false }
        return commandNamesScript(command, ownScriptPath)
    }

    /// Whether `command` runs `path` as its script argument.
    ///
    /// Positional, not a search: the script must be the argument immediately after the interpreter.
    /// `Process` sets `argv[0]` to the executable path and appends `arguments` after it, so the adapter
    /// reconstructs as `/usr/bin/perl <script> <framework> stream` — index 0 is `perl`, index 1 is the
    /// script. (Confirmed against real `ps` output, and pinned by the tests.)
    ///
    /// A whole-token search anywhere in the command would also accept a `perl` process that merely
    /// *mentions* the path — reading it, linting it, passing it to something else. Requiring the
    /// position fails closed: if argv ever does not look like this, nothing is reaped, which leaks at
    /// worst. Searching fails open, which signals someone else's process.
    static func commandNamesScript(_ command: String, _ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let tokens = command.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 2 else { return false }
        return tokens[1] == path
    }
}
