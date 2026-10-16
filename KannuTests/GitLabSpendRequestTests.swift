//
//  GitLabSpendRequestTests.swift
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

/// The one write to GitLab: `POST …/issues/:iid/add_spent_time` or `…/merge_requests/:iid/…`, the
/// length as `1h15m`, and the token only in the `PRIVATE-TOKEN` header. Dummy values; nothing is
/// sent.
final class GitLabSpendRequestTests: XCTestCase {
    private let token = "glpat-dummy-token-not-real"
    private lazy var credential = GitLabCredential(baseURL: "https://gitlab.example.com/gitlab", token: token)

    private func assertTokenOnlyInItsHeader(_ request: URLRequest, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(request.value(forHTTPHeaderField: "PRIVATE-TOKEN"), token, file: file, line: line)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "the token is never a bearer or basic credential", file: file, line: line)
        XCTAssertEqual(request.allHTTPHeaderFields?.count, 2, "Accept and PRIVATE-TOKEN only: \(request.allHTTPHeaderFields ?? [:])", file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json", file: file, line: line)
        let url = try XCTUnwrap(request.url?.absoluteString, file: file, line: line)
        XCTAssertFalse(url.contains(token), url, file: file, line: line)
        XCTAssertFalse((request.url?.query ?? "").contains("token"), "no private_token or access_token parameter: \(url)", file: file, line: line)
        XCTAssertNil(request.url?.user, file: file, line: line)
        XCTAssertNil(request.httpBody, "everything GitLab needs is in the path and the duration", file: file, line: line)
        XCTAssertEqual(request.httpMethod, "POST", file: file, line: line)
        XCTAssertEqual(request.timeoutInterval, 20, file: file, line: line)
        XCTAssertFalse(request.httpShouldHandleCookies, file: file, line: line)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData, file: file, line: line)
    }

    func testAnIssue() throws {
        let request = try XCTUnwrap(GitLabAPI.addSpentTimeRequest(credential, kind: .issue, projectID: 8, iid: 45, seconds: 4_500))
        XCTAssertEqual(request.url?.absoluteString,
                       "https://gitlab.example.com/gitlab/api/v4/projects/8/issues/45/add_spent_time?duration=1h15m")
        try assertTokenOnlyInItsHeader(request)
    }

    func testAMergeRequest() throws {
        let request = try XCTUnwrap(GitLabAPI.addSpentTimeRequest(credential, kind: .mergeRequest, projectID: 8, iid: 12, seconds: 2_700))
        XCTAssertEqual(request.url?.absoluteString,
                       "https://gitlab.example.com/gitlab/api/v4/projects/8/merge_requests/12/add_spent_time?duration=45m")
        try assertTokenOnlyInItsHeader(request)
    }

    func testOnGitLabDotCom() throws {
        let dotCom = GitLabCredential(baseURL: "https://gitlab.com", token: token)
        let request = try XCTUnwrap(GitLabAPI.addSpentTimeRequest(dotCom, kind: .issue, projectID: 278_964, iid: 1, seconds: 3_600))
        XCTAssertEqual(request.url?.absoluteString, "https://gitlab.com/api/v4/projects/278964/issues/1/add_spent_time?duration=1h")
        try assertTokenOnlyInItsHeader(request)
    }

    func testTheDurationIsHoursAndMinutesOnly() {
        XCTAssertEqual(GitLabAPI.spentTimeDuration(4_500), "1h15m")
        XCTAssertEqual(GitLabAPI.spentTimeDuration(2_700), "45m")
        XCTAssertEqual(GitLabAPI.spentTimeDuration(3_600), "1h")
        XCTAssertEqual(GitLabAPI.spentTimeDuration(60), "1m")
        XCTAssertEqual(GitLabAPI.spentTimeDuration(119), "1m", "whole minutes, rounded down")
        XCTAssertEqual(GitLabAPI.spentTimeDuration(9 * 3_600), "9h", "never 1d1h: GitLab's day is 8 hours")
        XCTAssertEqual(GitLabAPI.spentTimeDuration(45 * 3_600 + 30 * 60), "45h30m", "never weeks either")
        XCTAssertNil(GitLabAPI.spentTimeDuration(59))
        XCTAssertNil(GitLabAPI.spentTimeDuration(0))
        XCTAssertNil(GitLabAPI.spentTimeDuration(-60))
    }

    func testNothingIsBuiltForWhatKannuWouldNotSend() {
        XCTAssertNil(GitLabAPI.addSpentTimeRequest(credential, kind: .issue, projectID: 0, iid: 45, seconds: 900))
        XCTAssertNil(GitLabAPI.addSpentTimeRequest(credential, kind: .issue, projectID: 8, iid: -1, seconds: 900))
        XCTAssertNil(GitLabAPI.addSpentTimeRequest(credential, kind: .issue, projectID: 8, iid: 45, seconds: 30), "under a minute")
        XCTAssertNil(GitLabAPI.addSpentTimeRequest(credential, kind: .issue, projectID: 8, iid: 45, seconds: WorkDuration.maxSeconds + 60))
        for base in ["http://gitlab.example.com", "https://user@gitlab.example.com", "https://gitlab.example.com/?x=1", ""] {
            let other = GitLabCredential(baseURL: base, token: token)
            XCTAssertNil(GitLabAPI.addSpentTimeRequest(other, kind: .issue, projectID: 8, iid: 45, seconds: 900), base)
        }
    }

    func testGitLabsReasonIsReadAndCleaned() {
        XCTAssertEqual(GitLabAPI.refusalReason(Data(#"{"message":"403 Forbidden"}"#.utf8)), "403 Forbidden")
        XCTAssertEqual(GitLabAPI.refusalReason(Data(#"{"error":"duration is missing"}"#.utf8)), "duration is missing")
        XCTAssertEqual(GitLabAPI.refusalReason(Data(#"{"message":{"base":["Time to subtract exceeds the total time spent"]}}"#.utf8)),
                       "base Time to subtract exceeds the total time spent")
        XCTAssertNil(GitLabAPI.refusalReason(Data("<html></html>".utf8)))
        XCTAssertNil(GitLabAPI.refusalReason(nil))
    }
}
