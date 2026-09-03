//
//  AgentActivityPulseLatchTests.swift
//  KannuTests
//
//  Copyright (C) 2026 Kannu contributors
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import XCTest

/// One `rescan()` turn can publish several `activityPulse` bumps — a session-list change, a
/// traffic-light transition, and finally the running-agent heartbeat — but SwiftUI delivers
/// them to `onChange` as a single observation. A "was the last bump a heartbeat" flag therefore
/// answered for the heartbeat alone and swallowed the transition it rode in with. The latch
/// answers for the whole window since the observer last looked.
final class AgentActivityPulseLatchTests: XCTestCase {

    func testFreshLatchReportsHeartbeatOnly() {
        var latch = AgentActivityPulseLatch()
        XCTAssertTrue(latch.consume())
    }

    func testTransitionFollowedByHeartbeatIsNotHeartbeatOnly() {
        var latch = AgentActivityPulseLatch()
        latch.noteTransition()
        latch.noteHeartbeat()
        XCTAssertFalse(latch.consume(), "the heartbeat must not mask a transition published in the same window")
    }

    func testHeartbeatFollowedByTransitionIsNotHeartbeatOnly() {
        var latch = AgentActivityPulseLatch()
        latch.noteHeartbeat()
        latch.noteTransition()
        XCTAssertFalse(latch.consume())
    }

    func testHeartbeatsAloneStayHeartbeatOnly() {
        var latch = AgentActivityPulseLatch()
        latch.noteHeartbeat()
        latch.noteHeartbeat()
        XCTAssertTrue(latch.consume())
    }

    func testConsumeResetsForTheNextWindow() {
        var latch = AgentActivityPulseLatch()
        latch.noteTransition()
        XCTAssertFalse(latch.consume())
        latch.noteHeartbeat()
        XCTAssertTrue(latch.consume(), "a transition consumed earlier must not leak into the next window")
    }
}
