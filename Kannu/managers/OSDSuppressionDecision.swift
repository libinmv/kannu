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

/// When OSDUIHelper actually needs a fresh `SIGSTOP`.
///
/// Kannu suppresses the native volume/brightness HUD by keeping OSDUIHelper stopped, and asks for
/// that on two schedules: a 150 ms watcher, and immediately on every media-key event so the
/// CoreAudio write cannot beat the watcher to waking the helper. The immediate path used to fork
/// `killall -STOP` unconditionally, and a held volume key fires it ten to twenty times a second —
/// the interceptor delegate and the CoreAudio callback it causes both call in — so a held key was
/// tens of `fork`/`exec`/`waitpid` cycles per second to re-stop a process that was already stopped.
///
/// **The obvious fix is a bug.** The key handler receives an `isRepeat` flag, and skipping repeats
/// would be wrong: macOS jetsam-exits OSDUIHelper when it goes idle and launchd respawns it with a
/// *fresh PID*, which is the entire reason the 150 ms watcher exists. Skip the burst and a native HUD
/// renders on top of Kannu's until the watcher catches up.
///
/// So the decision is made from state instead — two syscalls, no subprocess — and both schedules go
/// through this one function so they cannot disagree about what "already stopped" means.
enum OSDSuppressionDecision {
    /// - Parameters:
    ///   - currentPID: the newest OSDUIHelper PID, or `nil` when none is running.
    ///   - isStopped: whether that PID is `SSTOP`. `nil` means `proc_pidinfo` could not find it, so
    ///     the process vanished between the two calls — a respawn in flight, which is precisely the
    ///     case this mechanism exists to catch, so it counts as needing a stop rather than as
    ///     "nothing to do".
    ///   - lastSuspendedPID: the PID Kannu last stopped, or a value no PID can take.
    static func shouldSuspend(currentPID: Int32?, isStopped: Bool?, lastSuspendedPID: Int32) -> Bool {
        // Nothing running: a stop would find no process. The watcher picks up the respawn.
        guard let currentPID else { return false }
        // A different PID is a respawn, so stop it even if that PID happens to be stopped already.
        if currentPID != lastSuspendedPID { return true }
        // Same PID: stop it again only if it is not currently stopped — an external SIGCONT, or a
        // lookup that came back empty. PID equality alone would miss both for the rest of the run.
        return isStopped != true
    }
}
