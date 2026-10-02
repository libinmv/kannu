//
//  AgentClickThroughPolicyTests.swift
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

/// REGRESSIONS entry 13: a live Claude session is never resumed; only a gone one, once dim.
final class AgentClickThroughPolicyTests: XCTestCase {
    typealias P = AgentClickThroughPolicy

    func testLiveSessionWithoutAHostNeverResumes() {
        XCTAssertEqual(P.claude(hasDesktopRoute: false, liveProcess: true, host: .none, displayState: .executing, canResume: true), .none)
    }

    func testInactiveLiveSessionNeverResumes() {
        // The bug: a live session in screen or ssh, dim because it was idle, fell through to
        // claude://resume and spawned a second host.
        XCTAssertEqual(P.claude(hasDesktopRoute: false, liveProcess: true, host: .none, displayState: .inactive, canResume: true), .none)
    }

    func testStoppedDeadSessionResumes() {
        XCTAssertEqual(P.claude(hasDesktopRoute: false, liveProcess: false, host: .none, displayState: .inactive, canResume: true), .resume)
        XCTAssertEqual(P.claude(hasDesktopRoute: false, liveProcess: false, host: .none, displayState: .stopped, canResume: true), .none,
                       "only once the card is dim")
        XCTAssertEqual(P.claude(hasDesktopRoute: false, liveProcess: false, host: .none, displayState: .inactive, canResume: false), .none)
    }

    func testDesktopRouteAlwaysWins() {
        XCTAssertEqual(P.claude(hasDesktopRoute: true, liveProcess: true, host: .app, displayState: .executing, canResume: true), .desktopRoute)
        XCTAssertEqual(P.claude(hasDesktopRoute: true, liveProcess: false, host: .none, displayState: .inactive, canResume: true), .desktopRoute)
    }

    func testTerminalAndTmuxHostedSessionsGoToTheirTerminal() {
        XCTAssertEqual(P.claude(hasDesktopRoute: false, liveProcess: true, host: .app, displayState: .awaitingInput, canResume: true), .terminalHost)
        XCTAssertEqual(P.claude(hasDesktopRoute: false, liveProcess: true, host: .tmux, displayState: .inactive, canResume: true), .tmuxPane)
    }

    func testCLISessionWithoutHostIsInert() {
        XCTAssertEqual(P.cli(host: .none), .none)
        XCTAssertEqual(P.cli(host: .app), .terminalHost)
        XCTAssertEqual(P.cli(host: .tmux), .tmuxPane)
    }

    // MARK: - Cloud sessions (docs/CLOUD-SESSIONS.md)

    /// A cloud card opens its session's page on claude.ai, and nothing else, whatever the relay sent.
    func testACloudCardOpensOnlyItsClaudeAiPage() throws {
        let url = try XCTUnwrap(P.claudeCloudSessionURL(conversationID: "claudecloud.session_01AbC"))
        XCTAssertEqual(url.absoluteString, "https://claude.ai/code/session_01AbC")
        XCTAssertTrue(P.isClaudeCloudSessionURL(url))
        for conversationID in ["session_01AbC", "claude.session_01AbC", "claudecloud.session_../x",
                               "claudecloud.session_a?b", "claudecloud.cse_01AbC", "claudecloud."] {
            XCTAssertNil(P.claudeCloudSessionURL(conversationID: conversationID), conversationID)
        }
        for other in ["https://claude.ai/code/session_01AbC?x=1", "https://claude.ai/code/session_01AbC#top",
                      "https://claude.ai.evil.example/code/session_01AbC", "http://claude.ai/code/session_01AbC",
                      "https://claude.ai:8443/code/session_01AbC", "https://user@claude.ai/code/session_01AbC",
                      "https://claude.ai/code/session_01AbC/../../settings", "https://claude.ai/settings"] {
            XCTAssertFalse(P.isClaudeCloudSessionURL(try XCTUnwrap(URL(string: other))), other)
        }
    }

    func testAFindingMayOpenACloudSessionsPage() {
        XCTAssertTrue(P.findingMayOpen(.webPage), "the page is where the chat already is: nothing is imported or launched")
    }
}
