//
//  SourceSyncStateTests.swift
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

/// When the Tasks page appearing may sync a source (Jira, GitLab) by itself. The page appears often,
/// so a refused token must never be sent again from here: repeated failed sign-ins can lock the
/// Atlassian account behind a CAPTCHA, or get the address banned by GitLab. Only the user's own
/// click retries one.
final class SourceSyncStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let staleAfter: TimeInterval = 5 * 60

    private func allows(_ state: SourceSyncState, lastSuccess: Date?) -> Bool {
        state.allowsSyncOnAppear(lastSuccess: lastSuccess, now: now, staleAfter: staleAfter)
    }

    private var stale: Date { now.addingTimeInterval(-staleAfter) }
    private var fresh: Date { now.addingTimeInterval(-staleAfter + 1) }

    func testARefusedTokenIsNeverRetriedOnAppear() {
        XCTAssertFalse(allows(.authFailed(status: 401), lastSuccess: nil), "never synced: still no retry")
        XCTAssertFalse(allows(.authFailed(status: 401), lastSuccess: now.addingTimeInterval(-86_400)), "however old")
        XCTAssertFalse(allows(.needsReconnect, lastSuccess: nil))
        XCTAssertFalse(allows(.needsReconnect, lastSuccess: stale))
    }

    func testTheFiveMinuteWindowCountsFromTheLastSuccess() {
        XCTAssertTrue(allows(.idle, lastSuccess: nil), "never synced")
        XCTAssertFalse(allows(.synced(at: fresh, count: 3, complete: true), lastSuccess: fresh))
        XCTAssertTrue(allows(.synced(at: stale, count: 3, complete: true), lastSuccess: stale), "exactly 5 minutes is stale")
    }

    func testARunningRateLimitHoldsAndAnEndedOneDoesNot() {
        XCTAssertFalse(allows(.rateLimited(until: now.addingTimeInterval(1)), lastSuccess: nil))
        XCTAssertTrue(allows(.rateLimited(until: now), lastSuccess: nil))
        XCTAssertFalse(allows(.rateLimited(until: now), lastSuccess: fresh), "and the window still applies")
    }

    func testFailuresThatAreNotTheCredentialsRetryOnceStale() {
        // Offline, a refused filter, a slow answer and a Keychain read that needs approval send no
        // refused credential: the next appearance after the window may try again. A Keychain read
        // that needs approval stays non-interactive (IntegrationSecretRulesTests).
        for state: SourceSyncState in [.offline, .failed("Jira did not answer in time."), .needsKeychainApproval] {
            XCTAssertTrue(allows(state, lastSuccess: nil), "\(state)")
            XCTAssertTrue(allows(state, lastSuccess: stale), "\(state)")
            XCTAssertFalse(allows(state, lastSuccess: fresh), "\(state)")
        }
    }
}
