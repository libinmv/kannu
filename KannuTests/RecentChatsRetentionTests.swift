//
//  RecentChatsRetentionTests.swift
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

/// Pins the list-only retention of chats that went red and then ended.
final class RecentChatsRetentionTests: XCTestCase {
    typealias Mapper = AgentTrafficLightMapper
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func session(_ id: String, _ state: AgentTrafficLightState, visible: Bool = true,
                         toolErrors: Int = 0, runError: RunError? = nil,
                         desktopSessionID: String? = nil) -> AgentSessionStatus {
        var s = AgentSessionStatus(
            id: "claude-\(id)", provider: "claude", conversationID: id, chatName: "Chat \(id)",
            projectName: "proj", rawState: state == .stopped ? "stopped" : "executing",
            displayState: state, updatedAt: t0, isVisible: visible, executionStartedAt: nil,
            cwd: nil, hostPID: nil
        )
        s.toolErrorCount = toolErrors
        s.runError = runError
        s.desktopSessionID = desktopSessionID
        return s
    }

    func testRedThenGoneIsRetainedAsADimVisibleCard() {
        let out = Mapper.retainEndedSessions(previous: [session("a", .stopped, toolErrors: 2, runError: .failed,
                                                                 desktopSessionID: "local_x")],
                                             current: [], retained: [:], now: t0.addingTimeInterval(10))
        XCTAssertEqual(out.sessions.count, 1)
        XCTAssertEqual(out.sessions[0].conversationID, "a")
        XCTAssertEqual(out.sessions[0].displayState, .inactive)
        XCTAssertTrue(out.sessions[0].isVisible)
        XCTAssertEqual(out.sessions[0].toolErrorCount, 2, "the count survives on the retained card")
        XCTAssertEqual(out.sessions[0].runError, .failed, "so does the verdict — the dim card still says why")
        XCTAssertEqual(out.sessions[0].desktopSessionID, "local_x", "and the dim card still opens the exact Desktop chat")
        XCTAssertEqual(out.sessions[0].chatName, "Chat a")
        XCTAssertEqual(out.retained["a"]?.endedAt, t0.addingTimeInterval(10))
    }

    func testRedThenAgedOutIsReplacedByTheRetainedCard() {
        let out = Mapper.retainEndedSessions(previous: [session("a", .stopped)],
                                             current: [session("a", .inactive, visible: false)],
                                             retained: [:], now: t0.addingTimeInterval(10))
        XCTAssertEqual(out.sessions.count, 1)
        XCTAssertTrue(out.sessions[0].isVisible)
        XCTAssertEqual(out.sessions[0].displayState, .inactive)
    }

    func testStillRedOrStillRunningIsNotRetained() {
        let red = Mapper.retainEndedSessions(previous: [session("a", .stopped)], current: [session("a", .stopped)],
                                             retained: [:], now: t0)
        XCTAssertTrue(red.retained.isEmpty)
        XCTAssertEqual(red.sessions.map(\.displayState), [.stopped])

        let running = Mapper.retainEndedSessions(previous: [session("b", .executing)], current: [],
                                                 retained: [:], now: t0)
        XCTAssertTrue(running.retained.isEmpty, "only a chat that was red counts as ended")
        XCTAssertTrue(running.sessions.isEmpty)
    }

    func testRetainedCardExpiresAfterRetention() {
        let first = Mapper.retainEndedSessions(previous: [session("a", .stopped)], current: [],
                                               retained: [:], now: t0)
        let later = Mapper.retainEndedSessions(previous: first.sessions, current: [], retained: first.retained,
                                               now: t0.addingTimeInterval(68))
        XCTAssertEqual(later.sessions.count, 1, "still listed inside the window")
        let expired = Mapper.retainEndedSessions(previous: later.sessions, current: [], retained: later.retained,
                                                 now: t0.addingTimeInterval(69))
        XCTAssertTrue(expired.sessions.isEmpty)
        XCTAssertTrue(expired.retained.isEmpty)
    }

    func testReappearingLiveDropsTheRetention() {
        let first = Mapper.retainEndedSessions(previous: [session("a", .stopped)], current: [],
                                               retained: [:], now: t0)
        let back = Mapper.retainEndedSessions(previous: first.sessions, current: [session("a", .executing)],
                                              retained: first.retained, now: t0.addingTimeInterval(5))
        XCTAssertTrue(back.retained.isEmpty)
        XCTAssertEqual(back.sessions.map(\.displayState), [.executing])
    }

    func testACarriedInactiveCopyDoesNotDuplicateOrDropTheRetention() {
        // The hook-only quick rescan carries the previous list's non-hook rows forward, so the
        // retained copy itself can arrive in `current`. It must neither duplicate nor end retention.
        let first = Mapper.retainEndedSessions(previous: [session("a", .stopped)], current: [],
                                               retained: [:], now: t0)
        let carried = Mapper.retainEndedSessions(previous: first.sessions, current: first.sessions,
                                                 retained: first.retained, now: t0.addingTimeInterval(5))
        XCTAssertEqual(carried.sessions.count, 1)
        XCTAssertEqual(carried.retained.count, 1)
    }

    func testSimulationSessionsAreNeverRetained() {
        let out = Mapper.retainEndedSessions(previous: [session("kannu-test-1", .stopped)], current: [],
                                             retained: [:], now: t0)
        XCTAssertTrue(out.sessions.isEmpty)
    }
}

/// The `/usage` probe bookkeeping that keeps Kannu's own spawned session out of the chat list.
final class UsageProbeExclusionTests: XCTestCase {
    typealias Mapper = AgentTrafficLightMapper

    func testRememberedIDsAreRecognised() {
        let ids = Mapper.rememberingProbeConversationID("p1", in: [])
        XCTAssertTrue(Mapper.isUsageProbeSession(conversationID: "p1", probeIDs: ids))
        XCTAssertFalse(Mapper.isUsageProbeSession(conversationID: "real", probeIDs: ids))
    }

    func testRememberingDedupesAndMovesToNewest() {
        let ids = Mapper.rememberingProbeConversationID("p1", in: ["p1", "p2"])
        XCTAssertEqual(ids, ["p2", "p1"])
    }

    func testRememberingIsCapped() {
        var ids: [String] = []
        for index in 0..<40 { ids = Mapper.rememberingProbeConversationID("p\(index)", in: ids) }
        XCTAssertEqual(ids.count, Mapper.usageProbeIDCap)
        XCTAssertEqual(ids.first, "p8")
        XCTAssertEqual(ids.last, "p39")
    }
}
