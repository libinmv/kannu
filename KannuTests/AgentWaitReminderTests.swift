//
//  AgentWaitReminderTests.swift
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

/// One reminder per wait, never a burst on relaunch, and nothing for sessions that are not waiting.
final class AgentWaitReminderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_788_000_000)
    private let threshold: TimeInterval = 180

    private func session(_ id: String = "a", _ state: AgentTrafficLightState = .awaitingInput, updatedAt: Date? = nil,
                         visible: Bool = true, provider: String = "claude") -> AgentSessionStatus {
        AgentSessionStatus(id: "\(provider)-\(id)", provider: provider, conversationID: id, chatName: "Chat", projectName: "proj",
                           rawState: "awaiting_input", displayState: state, updatedAt: updatedAt ?? t0,
                           isVisible: visible, executionStartedAt: nil, cwd: nil, hostPID: nil)
    }

    func testRemindsOnceAfterTheThreshold() {
        var reminder = AgentWaitReminder()
        XCTAssertEqual(reminder.update([session()], now: t0.addingTimeInterval(60), threshold: threshold, suppressOverdue: false), [])
        let due = reminder.update([session()], now: t0.addingTimeInterval(200), threshold: threshold, suppressOverdue: false)
        XCTAssertEqual(due, [.init(sessionID: "claude-a", provider: "claude", minutes: 3)])
        XCTAssertEqual(reminder.update([session()], now: t0.addingTimeInterval(900), threshold: threshold, suppressOverdue: false), [],
                       "one reminder per wait")
    }

    func testNewWaitAfterLeavingYellowRemindsAgain() {
        var reminder = AgentWaitReminder()
        _ = reminder.update([session()], now: t0.addingTimeInterval(200), threshold: threshold, suppressOverdue: false)
        _ = reminder.update([session("a", .executing)], now: t0.addingTimeInterval(300), threshold: threshold, suppressOverdue: false)
        let secondWait = session(updatedAt: t0.addingTimeInterval(400))
        XCTAssertEqual(reminder.update([secondWait], now: t0.addingTimeInterval(450), threshold: threshold, suppressOverdue: false), [])
        XCTAssertEqual(reminder.update([secondWait], now: t0.addingTimeInterval(600), threshold: threshold, suppressOverdue: false).count, 1)
    }

    func testMovingTimestampWhileYellowDoesNotRemindTwice() {
        var reminder = AgentWaitReminder()
        _ = reminder.update([session()], now: t0.addingTimeInterval(200), threshold: threshold, suppressOverdue: false)
        // Cursor's transcript yellow moves its timestamp with activity; the wait started at t0.
        let moved = session(updatedAt: t0.addingTimeInterval(500))
        XCTAssertEqual(reminder.update([moved], now: t0.addingTimeInterval(900), threshold: threshold, suppressOverdue: false), [])
    }

    func testLeavingYellowCancels() {
        var reminder = AgentWaitReminder()
        _ = reminder.update([session()], now: t0.addingTimeInterval(60), threshold: threshold, suppressOverdue: false)
        XCTAssertEqual(reminder.update([session("a", .executing)], now: t0.addingTimeInterval(200), threshold: threshold, suppressOverdue: false), [])
        XCTAssertNil(reminder.nextCheck(now: t0.addingTimeInterval(200), threshold: threshold))
    }

    func testOverdueWaitsAtLaunchAreNotBurst() {
        var reminder = AgentWaitReminder()
        XCTAssertEqual(reminder.update([session()], now: t0.addingTimeInterval(3600), threshold: threshold, suppressOverdue: true), [])
        XCTAssertEqual(reminder.update([session()], now: t0.addingTimeInterval(3700), threshold: threshold, suppressOverdue: false), [],
                       "marked as reminded, so it stays quiet")
    }

    func testOffClearsState() {
        var reminder = AgentWaitReminder()
        _ = reminder.update([session()], now: t0.addingTimeInterval(200), threshold: threshold, suppressOverdue: false)
        XCTAssertEqual(reminder.update([session()], now: t0.addingTimeInterval(300), threshold: nil, suppressOverdue: false), [])
        XCTAssertTrue(reminder.waits.isEmpty)
        XCTAssertTrue(reminder.reminded.isEmpty)
    }

    func testNextCheckIsTheEarliestPendingReminder() {
        var reminder = AgentWaitReminder()
        _ = reminder.update([session("a"), session("b", updatedAt: t0.addingTimeInterval(60))], now: t0.addingTimeInterval(90),
                            threshold: threshold, suppressOverdue: false)
        XCTAssertEqual(reminder.nextCheck(now: t0.addingTimeInterval(90), threshold: threshold), t0.addingTimeInterval(180))
    }

    func testSimulationAndHiddenSessionsAreIgnored() {
        var reminder = AgentWaitReminder()
        let hidden = session("h", visible: false)
        XCTAssertEqual(reminder.update([hidden], now: t0.addingTimeInterval(900), threshold: threshold, suppressOverdue: false), [])
        XCTAssertTrue(reminder.waits.isEmpty)
    }
}
