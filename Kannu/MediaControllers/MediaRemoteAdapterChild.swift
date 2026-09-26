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

/// Shutting down a `mediaremote-adapter.pl` child, in the one order that works.
///
/// Two controllers run one of these — `NowPlayingController` and `AmazonMusicController` — and they
/// are otherwise near-copies of each other. That is not incidental: `e7dfc83` found nine orphaned
/// helpers, fixed the teardown in `NowPlayingController`, and the copy kept leaking one per Music
/// Source change for months, because nothing connected the two. The same disease as
/// `docs/REGRESSIONS.md` entry 1 — two copies of one artifact and only one of them exercised — in
/// Swift instead of in the hook script.
///
/// So the part that must never diverge again lives here, once. The setup and streaming paths stay in
/// each controller, because those genuinely differ in what they subscribe to.
enum MediaRemoteAdapterChild {

    /// Releases a helper and everything attached to it. Safe to call with any of them nil.
    ///
    /// The order is load-bearing:
    ///
    /// 1. **Clear the stderr handler first.** Terminating the child closes the write end, and a
    ///    `readabilityHandler` still installed then reads EOF forever — `availableData` returns empty,
    ///    the closure returns, GCD re-arms the source, repeat — burning idle wakeups for the life of
    ///    the process.
    /// 2. **Close the JSON pipe next.** That is what makes the stream loop return: `close()` resumes
    ///    its pending continuation with `CancellationError`, which unwinds the `while true` read loop
    ///    and finally releases the controller the running task was holding. Do it before terminating,
    ///    so the child is left with nowhere to write rather than writing into a closed pipe.
    /// 3. **Then ask the child to exit.**
    static func tearDown(
        process: Process?,
        pipeHandler: JSONLinesPipeHandler?,
        stderrPipe: Pipe?
    ) async {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if let pipeHandler {
            await pipeHandler.close()
        }

        if let process, process.isRunning {
            process.terminate()
        }
    }

    /// The `applicationWillTerminate` half: signal the child and return.
    ///
    /// Nothing is awaited and nothing else is released, because the process is exiting — the pipe and
    /// the stream task die with it either way. Only the child needs saying, because it does not: it is
    /// reparented to `launchd` and outlives the app that spawned it.
    static func terminateForAppExit(process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
    }
}
