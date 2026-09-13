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

import XCTest

/// When OSDUIHelper needs a fresh `SIGSTOP`.
///
/// This exists because the cheap-looking fix for the cost here — gating on the media key's
/// `isRepeat` flag — silently breaks suppression, and because the whole path is a no-op on this Mac
/// (`osdHelperDrawsSystemHUD` returns false on macOS 26), so nothing here can be caught by running
/// the app. The respawn case is the one that matters and the one a later "optimisation" will break.
final class OSDSuppressionDecisionTests: XCTestCase {
    func testAnAlreadyStoppedHelperIsLeftAlone() {
        // The common case during a held key: dozens of calls a second, all answered with no fork.
        XCTAssertFalse(
            OSDSuppressionDecision.shouldSuspend(currentPID: 812, isStopped: true, lastSuspendedPID: 812)
        )
    }

    func testARespawnedHelperIsStoppedEvenMidBurst() {
        // launchd gives the respawn a fresh PID. Gating on `isRepeat` would skip exactly this and
        // let the native HUD render until the 150 ms watcher caught up.
        XCTAssertTrue(
            OSDSuppressionDecision.shouldSuspend(currentPID: 913, isStopped: false, lastSuspendedPID: 812)
        )
    }

    func testARespawnThatIsSomehowAlreadyStoppedIsStillClaimed() {
        // A different PID is a different process; stopping it again is harmless and recording it is
        // what lets the "same PID, already stopped" fast path work at all afterwards.
        XCTAssertTrue(
            OSDSuppressionDecision.shouldSuspend(currentPID: 913, isStopped: true, lastSuspendedPID: 812)
        )
    }

    func testTheSamePIDResumedBehindOurBackIsStoppedAgain() {
        // An external SIGCONT. PID equality alone would miss it for the rest of the session.
        XCTAssertTrue(
            OSDSuppressionDecision.shouldSuspend(currentPID: 812, isStopped: false, lastSuspendedPID: 812)
        )
    }

    func testAVanishedLookupCountsAsNeedingAStop() {
        // `isPIDStopped` returns nil when `proc_pidinfo` cannot find the process, which means it
        // exited between the two syscalls — a respawn in flight. Treating that as "nothing to do"
        // is the failure mode; it must fork.
        XCTAssertTrue(
            OSDSuppressionDecision.shouldSuspend(currentPID: 812, isStopped: nil, lastSuspendedPID: 812)
        )
    }

    func testNoHelperRunningNeedsNoStop() {
        // Nothing to signal. The watcher picks up the respawn when it appears.
        XCTAssertFalse(
            OSDSuppressionDecision.shouldSuspend(currentPID: nil, isStopped: nil, lastSuspendedPID: 812)
        )
        XCTAssertFalse(
            OSDSuppressionDecision.shouldSuspend(currentPID: nil, isStopped: nil, lastSuspendedPID: -1)
        )
    }

    func testTheFirstHelperOfTheSessionIsStopped() {
        // `lastSuspendedPID` starts at a value no PID can take, so the first sighting always stops.
        XCTAssertTrue(
            OSDSuppressionDecision.shouldSuspend(currentPID: 812, isStopped: false, lastSuspendedPID: -1)
        )
    }
}
