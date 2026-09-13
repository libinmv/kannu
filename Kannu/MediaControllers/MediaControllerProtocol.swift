/*
 * Kannu (കണ്ണ്)
 * Copyright (C) 2024-2026 Kannu Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Kannu (കണ്ണ്)
 * See NOTICE for details.
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
import AppKit
import Combine

protocol MediaControllerProtocol: ObservableObject {
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { get }
    var isWorking: Bool { get }
    func play() async
    func pause() async
    func seek(to time: Double) async
    func nextTrack() async
    func previousTrack() async
    func togglePlay() async
    func toggleShuffle() async
    func toggleRepeat() async
    func isActive() -> Bool
    func updatePlaybackInfo() async

    /// Releases anything the controller owns outside the process — a child process, a pipe, a stream
    /// task. Most controllers own nothing of the sort and take the default no-op.
    ///
    /// This exists because `deinit` is not a teardown path for a controller that keeps a live child.
    /// `NowPlayingController` holds a `Task` that holds the controller (its stream loop never returns,
    /// so the strong reference the call takes is never released) — a retain cycle that makes `deinit`
    /// unreachable, so dropping the last visible reference left the `mediaremote-adapter.pl` helper
    /// streaming to nobody, reparented to `launchd`. Whoever stops using a controller must say so.
    func stop() async

    /// Signals any child process to exit, synchronously, for `applicationWillTerminate`.
    ///
    /// Separate from `stop()` because that is `async` and app termination does not wait for a task.
    /// Terminating the child is the only part that must happen before the process exits — the pipe and
    /// the stream task die with it either way.
    func terminateChildProcessesForAppExit()
}

extension MediaControllerProtocol {
    func stop() async {}
    func terminateChildProcessesForAppExit() {}
}
