//
//  GitLabRequestTests.swift
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

/// Every GitLab request: the token only in the `PRIVATE-TOKEN` header, never in a URL and never as
/// `Authorization`, and only for the credential's own server. The values are dummies; no request is
/// sent.
final class GitLabRequestTests: XCTestCase {
    private let token = "glpat-dummy-token-not-real"
    private lazy var credential = GitLabCredential(baseURL: "https://gitlab.example.com/gitlab", token: token)

    private func assertTokenOnlyInItsHeader(_ request: URLRequest, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(request.value(forHTTPHeaderField: "PRIVATE-TOKEN"), token, file: file, line: line)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "the token is never a bearer or basic credential", file: file, line: line)
        XCTAssertEqual(request.allHTTPHeaderFields?.count, 2, "Accept and PRIVATE-TOKEN only: \(request.allHTTPHeaderFields ?? [:])", file: file, line: line)
        let url = try XCTUnwrap(request.url?.absoluteString, file: file, line: line)
        XCTAssertFalse(url.contains(token), url, file: file, line: line)
        XCTAssertFalse((request.url?.query ?? "").contains("token"), "no private_token or access_token parameter: \(url)", file: file, line: line)
        XCTAssertNil(request.url?.user, file: file, line: line)
        XCTAssertNil(request.url?.password, file: file, line: line)
        XCTAssertEqual(request.httpMethod, "GET", file: file, line: line)
        XCTAssertNil(request.httpBody, file: file, line: line)
        XCTAssertEqual(request.timeoutInterval, 20, file: file, line: line)
        XCTAssertFalse(request.httpShouldHandleCookies, file: file, line: line)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData, file: file, line: line)
    }

    func testTheVerifyRequests() throws {
        let user = try XCTUnwrap(GitLabAPI.userRequest(credential))
        XCTAssertEqual(user.url?.absoluteString, "https://gitlab.example.com/gitlab/api/v4/user")
        XCTAssertEqual(user.value(forHTTPHeaderField: "Accept"), "application/json")
        try assertTokenOnlyInItsHeader(user)

        let scopes = try XCTUnwrap(GitLabAPI.tokenInfoRequest(credential))
        XCTAssertEqual(scopes.url?.absoluteString, "https://gitlab.example.com/gitlab/api/v4/personal_access_tokens/self")
        try assertTokenOnlyInItsHeader(scopes)
    }

    func testTheIssueList() throws {
        let request = try XCTUnwrap(GitLabAPI.listRequest(credential, list: .assignedIssues, page: 1))
        XCTAssertEqual(request.url?.absoluteString,
                       "https://gitlab.example.com/gitlab/api/v4/issues?scope=assigned_to_me&state=opened&per_page=100&page=1")
        try assertTokenOnlyInItsHeader(request)
    }

    func testTheMergeRequestLists() throws {
        let assigned = try XCTUnwrap(GitLabAPI.listRequest(credential, list: .assignedMergeRequests, page: 2))
        XCTAssertEqual(assigned.url?.absoluteString,
                       "https://gitlab.example.com/gitlab/api/v4/merge_requests?scope=assigned_to_me&state=opened&per_page=100&page=2")
        try assertTokenOnlyInItsHeader(assigned)

        let reviewing = try XCTUnwrap(GitLabAPI.listRequest(credential, list: .reviewRequests(username: "dana.smith-2"), page: 1))
        XCTAssertEqual(reviewing.url?.absoluteString,
                       "https://gitlab.example.com/gitlab/api/v4/merge_requests?reviewer_username=dana.smith-2&state=opened&scope=all&per_page=100&page=1")
        try assertTokenOnlyInItsHeader(reviewing)
    }

    func testOnlyTheFirstTwoPagesAreEverBuilt() {
        XCTAssertNil(GitLabAPI.listRequest(credential, list: .assignedIssues, page: 0))
        XCTAssertNil(GitLabAPI.listRequest(credential, list: .assignedIssues, page: 3))
        XCTAssertNotNil(GitLabAPI.listRequest(credential, list: .assignedIssues, page: GitLabAPI.maxPages))
    }

    func testAUserNameThatIsNotOneNeverReachesAQuery() {
        for name in ["", "dana&scope=all", "dana smith", "dana/../x", "dana%40", "dána", String(repeating: "a", count: 256)] {
            XCTAssertNil(GitLabAPI.listRequest(credential, list: .reviewRequests(username: name), page: 1), name)
            XCTAssertFalse(GitLabAPI.isUsername(name), name)
        }
        XCTAssertTrue(GitLabAPI.isUsername("dana_smith.2-x"))
    }

    func testNoRequestIsBuiltForAnotherServer() {
        for base in ["http://gitlab.com", "gitlab.com", "https://GitLab.com", "https://gitlab.com/", "https://u@gitlab.com", "", "https://gitlab.com/?x=1"] {
            let other = GitLabCredential(baseURL: base, token: token)
            XCTAssertNil(GitLabAPI.userRequest(other), base)
            XCTAssertNil(GitLabAPI.tokenInfoRequest(other), base)
            XCTAssertNil(GitLabAPI.listRequest(other, list: .assignedIssues, page: 1), base)
        }
    }

    func testXNextPage() {
        let full = GitLabAPI.pageSize
        XCTAssertEqual(GitLabAPI.nextStep(nextPageHeader: "2", page: 1, itemCount: full, pagesFetched: 1), .next(2))
        XCTAssertEqual(GitLabAPI.nextStep(nextPageHeader: "", page: 1, itemCount: 12, pagesFetched: 1), .done(complete: true), "empty: the last page")
        XCTAssertEqual(GitLabAPI.nextStep(nextPageHeader: " ", page: 2, itemCount: full, pagesFetched: 2), .done(complete: true))
        XCTAssertEqual(GitLabAPI.nextStep(nextPageHeader: "3", page: 2, itemCount: full, pagesFetched: 2), .capped, "more than two pages: incomplete")
        XCTAssertEqual(GitLabAPI.nextStep(nextPageHeader: nil, page: 1, itemCount: 12, pagesFetched: 1), .done(complete: true), "no header, a short page")
        XCTAssertEqual(GitLabAPI.nextStep(nextPageHeader: nil, page: 1, itemCount: full, pagesFetched: 1), .done(complete: false), "no header, a full page: unknown")
        XCTAssertEqual(GitLabAPI.nextStep(nextPageHeader: "7", page: 1, itemCount: full, pagesFetched: 1), .done(complete: false), "not the next page: not trusted")
        XCTAssertEqual(GitLabAPI.nextStep(nextPageHeader: "1", page: 1, itemCount: full, pagesFetched: 1), .done(complete: false), "never loops")
        XCTAssertEqual(GitLabAPI.nextStep(nextPageHeader: "two", page: 1, itemCount: full, pagesFetched: 1), .done(complete: false))
    }

    func testTheTokenIsCheckedBeforeItIsSent() {
        XCTAssertTrue(GitLabAPI.isPlausibleToken("glpat-AbC_123-xyz"))
        XCTAssertTrue(GitLabAPI.isPlausibleToken("abcdef0123456789abcd"), "a token from before the glpat- prefix")
        XCTAssertFalse(GitLabAPI.isPlausibleToken(""))
        XCTAssertFalse(GitLabAPI.isPlausibleToken("glpat abc"))
        XCTAssertFalse(GitLabAPI.isPlausibleToken("glpat-abc\r\nX-Evil: 1"), "no header injection")
        XCTAssertFalse(GitLabAPI.isPlausibleToken("glpat-ab€"))
    }

    func testTheCredentialNeverPrintsItsToken() {
        var dumped = ""
        dump(credential, to: &dumped)
        for text in ["\(credential)", String(reflecting: credential), String(describing: credential), dumped] {
            XCTAssertFalse(text.contains(token), text)
        }
        XCTAssertTrue("\(credential)".contains("gitlab.example.com"), "the server is not a secret")
    }

    func testTheKeychainFormRoundTrips() throws {
        let encoded = try XCTUnwrap(credential.encoded())
        XCTAssertEqual(encoded, #"{"baseURL":"https://gitlab.example.com/gitlab","token":"glpat-dummy-token-not-real"}"#)
        XCTAssertEqual(GitLabCredential.decoded(encoded), credential)
        XCTAssertNil(GitLabCredential.decoded("not json"))
        XCTAssertNil(GitLabCredential.decoded(#"{"baseURL":"https://gitlab.com"}"#))
    }

    func testTheMatchKeyKeepsIssuesAndMergeRequestsApart() {
        XCTAssertEqual(GitLabAPI.remoteID(kind: .issue, id: 76), "issue:76")
        XCTAssertEqual(GitLabAPI.remoteID(kind: .mergeRequest, id: 76), "mr:76")
    }
}
