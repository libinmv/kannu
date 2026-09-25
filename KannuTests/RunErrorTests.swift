//
//  RunErrorTests.swift
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

/// The run verdict: what a stopped card may say, and how it crosses every reconstruction seam.
final class RunErrorTests: XCTestCase {
    private func session(_ state: AgentTrafficLightState, runError: RunError?) -> AgentSessionStatus {
        var s = AgentSessionStatus(
            id: "claude-a", provider: "claude", conversationID: "a", chatName: "Chat", projectName: "proj",
            rawState: state == .stopped ? "stopped" : "executing", displayState: state,
            updatedAt: Date(timeIntervalSince1970: 1_000), isVisible: true, executionStartedAt: nil,
            cwd: nil, hostPID: nil
        )
        s.runError = runError
        return s
    }

    func testPreferredKeepsTheMoreSpecificVerdictAndNeverInventsOne() {
        XCTAssertNil(RunError.preferred(nil, nil))
        XCTAssertEqual(RunError.preferred(.failed, nil), .failed)
        XCTAssertEqual(RunError.preferred(nil, .apiError(status: 529)), .apiError(status: 529))
        XCTAssertEqual(RunError.preferred(.failed, .apiError(status: 429)), .apiError(status: 429))
        XCTAssertEqual(RunError.preferred(.apiError(status: 429), .failed), .apiError(status: 429))
        XCTAssertEqual(RunError.preferred(.apiError(status: 429), .apiError(status: 529)), .apiError(status: 429),
                       "a tie keeps the own side")
    }

    func testLabelsNameTheCommonStatuses() {
        XCTAssertEqual(RunError.apiError(status: 429).label, "rate limited (429)")
        XCTAssertEqual(RunError.apiError(status: 529).label, "API overloaded (529)")
        XCTAssertEqual(RunError.apiError(status: 401).label, "signed out (401)")
        XCTAssertEqual(RunError.apiError(status: 400).label, "API error 400")
        XCTAssertEqual(RunError.apiError(status: nil).label, "API error")
        XCTAssertEqual(RunError.failed.label, "failed")
    }

    func testSuffixRendersOnlyOnceStopped() {
        XCTAssertEqual(session(.stopped, runError: .failed).runOutcomeSuffix, " · failed")
        XCTAssertEqual(session(.inactive, runError: .apiError(status: 429)).runOutcomeSuffix, " · rate limited (429)")
        XCTAssertEqual(session(.executing, runError: .failed).runOutcomeSuffix, "")
        XCTAssertEqual(session(.stopped, runError: nil).runOutcomeSuffix, "")
    }

    func testVerdictSurvivesReconstruction() {
        let flagged = session(.stopped, runError: .failed)
        XCTAssertEqual(flagged.withDisplayState(.inactive, visible: true).runError, .failed)
        XCTAssertEqual(flagged.replacingChatName("x").runError, .failed)
        XCTAssertEqual(flagged.replacingProjectName("y").runError, .failed)
        let clean = session(.stopped, runError: nil)
        XCTAssertEqual(clean.carryingExtras(from: flagged).runError, .failed, "nil yields to the other side")
        XCTAssertEqual(flagged.carryingExtras(from: clean).runError, .failed)
        XCTAssertNil(clean.carryingExtras(from: clean).runError)
    }
}
