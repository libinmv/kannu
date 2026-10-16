//
//  GitLabDecodingTests.swift
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

/// GitLab's answers, from handwritten fixtures shaped like the documented API (trimmed to the
/// fields Kannu reads, plus a few it ignores), and what a task keeps of them.
final class GitLabDecodingTests: XCTestCase {
    private let base = "https://gitlab.example.com"

    static let issuesPage = """
    [
      {
        "id": 76, "iid": 45, "project_id": 8,
        "title": "Login  redirect\\nloops", "state": "opened",
        "description": "ignored", "labels": ["bug"],
        "web_url": "https://gitlab.example.com/group/app/-/issues/45",
        "references": {"short": "#45", "relative": "app#45", "full": "group/app#45"},
        "time_stats": {"time_estimate": 7200, "total_time_spent": 10800, "human_time_estimate": "2h", "human_total_time_spent": "3h"}
      },
      {
        "id": 77, "iid": 46, "project_id": 8,
        "title": "", "state": "opened",
        "web_url": "https://evil.example/group/app/-/issues/46",
        "references": {"full": "group/app#46"},
        "time_stats": {"time_estimate": 0, "total_time_spent": 0}
      },
      {
        "id": 78, "iid": 3, "project_id": 9,
        "title": "Old server", "state": "opened"
      }
    ]
    """

    static let mergeRequestsPage = """
    [
      {
        "id": 31, "iid": 12, "project_id": 8,
        "title": "Draft: Fix the redirect", "state": "opened", "draft": true,
        "web_url": "https://gitlab.example.com/group/app/-/merge_requests/12",
        "references": {"short": "!12", "relative": "!12", "full": "group/app!12"},
        "time_stats": {"time_estimate": 1800, "total_time_spent": 0},
        "reviewers": [{"id": 1, "username": "dana"}]
      }
    ]
    """

    private func items(_ json: String) throws -> [GitLabItem] {
        try XCTUnwrap(GitLabAPI.decodeItems(Data(json.utf8)))
    }

    func testAnIssuePage() throws {
        let page = try items(Self.issuesPage)
        XCTAssertEqual(page.count, 3)
        XCTAssertEqual(page[0].id, 76)
        XCTAssertEqual(page[0].iid, 45)
        XCTAssertEqual(page[0].projectID, 8)
        XCTAssertEqual(page[0].references?.full, "group/app#45")
        XCTAssertEqual(page[0].timeStats, GitLabItem.TimeStats(timeEstimate: 7200, totalTimeSpent: 10800))
        XCTAssertNil(page[2].timeStats, "an older server sends no time_stats")
        XCTAssertNil(page[2].references)
    }

    func testAnIssueAsATask() throws {
        let page = try items(Self.issuesPage)
        let issue = GitLabAPI.remoteIssue(from: page[0], kind: .issue, base: base, reviewRequested: false)
        XCTAssertEqual(issue.remoteID, "issue:76", "the global id, with its kind")
        XCTAssertEqual(issue.key, "group/app#45")
        XCTAssertEqual(issue.title, "Login redirect loops", "one clean line")
        XCTAssertEqual(issue.status, "opened")
        XCTAssertFalse(issue.isDoneRemotely)
        XCTAssertEqual(issue.estimateSeconds, 7200)
        XCTAssertEqual(issue.spentSeconds, 10800)
        XCTAssertEqual(issue.gitlab, RemoteIssue.GitLabRef(kind: .issue, projectID: 8, iid: 45,
                                                           webURL: "https://gitlab.example.com/group/app/-/issues/45"))
    }

    func testWhatAnAnswerCannotSlipIn() throws {
        let page = try items(Self.issuesPage)
        let other = GitLabAPI.remoteIssue(from: page[1], kind: .issue, base: base, reviewRequested: false)
        XCTAssertNil(other.gitlab?.webURL, "a page on another host is never kept")
        XCTAssertEqual(other.title, "group/app#46", "no title: the key")
        XCTAssertNil(other.estimateSeconds, "0 is no estimate")
        XCTAssertNil(other.spentSeconds)

        let old = GitLabAPI.remoteIssue(from: page[2], kind: .issue, base: base, reviewRequested: false)
        XCTAssertEqual(old.key, "#3", "a server too old for references")
        XCTAssertNil(old.estimateSeconds)
        XCTAssertNil(old.gitlab?.webURL)
    }

    func testAMergeRequestAsATask() throws {
        let item = try XCTUnwrap(try items(Self.mergeRequestsPage).first)
        let reviewing = GitLabAPI.remoteIssue(from: item, kind: .mergeRequest, base: base, reviewRequested: true)
        XCTAssertEqual(reviewing.remoteID, "mr:31")
        XCTAssertEqual(reviewing.key, "group/app!12")
        XCTAssertEqual(reviewing.title, "Draft: Fix the redirect")
        XCTAssertEqual(reviewing.status, "review requested")
        XCTAssertEqual(reviewing.estimateSeconds, 1800)
        XCTAssertEqual(reviewing.gitlab?.kind, .mergeRequest)
        XCTAssertEqual(reviewing.gitlab?.webURL, "https://gitlab.example.com/group/app/-/merge_requests/12")
        let assigned = GitLabAPI.remoteIssue(from: item, kind: .mergeRequest, base: base, reviewRequested: false)
        XCTAssertEqual(assigned.status, "assigned to you")
    }

    func testClosedAndMergedAreDone() throws {
        let json = #"[{"id": 1, "iid": 1, "project_id": 1, "state": "merged"}, {"id": 2, "iid": 2, "project_id": 1, "state": "closed"}]"#
        let page = try items(json)
        XCTAssertTrue(GitLabAPI.remoteIssue(from: page[0], kind: .mergeRequest, base: base, reviewRequested: false).isDoneRemotely)
        XCTAssertTrue(GitLabAPI.remoteIssue(from: page[1], kind: .issue, base: base, reviewRequested: false).isDoneRemotely)
    }

    func testAnswersThatAreNotAList() {
        XCTAssertNil(GitLabAPI.decodeItems(Data(#"{"message":"401 Unauthorized"}"#.utf8)))
        XCTAssertNil(GitLabAPI.decodeItems(Data("<html>".utf8)))
        XCTAssertNil(GitLabAPI.decodeItems(Data(#"[{"iid": 1, "project_id": 1}]"#.utf8)), "no id: not GitLab")
        XCTAssertEqual(GitLabAPI.decodeItems(Data("[]".utf8)), [])
    }

    func testTheUser() throws {
        let json = #"{"id": 1, "username": "dana", "name": "Dana Smith", "state": "active", "avatar_url": "x"}"#
        XCTAssertEqual(GitLabAPI.decodeUser(Data(json.utf8)), GitLabUser(id: 1, username: "dana", name: "Dana Smith"))
        XCTAssertNil(GitLabAPI.decodeUser(Data(#"{"id": 1}"#.utf8)))
    }

    // MARK: - Scopes

    func testTheTokensScopes() throws {
        let json = #"{"id": 4, "name": "Kannu", "revoked": false, "active": true, "scopes": ["read_api", "read_user"], "expires_at": "2026-12-31"}"#
        let info = try XCTUnwrap(GitLabAPI.decodeTokenInfo(Data(json.utf8)))
        XCTAssertEqual(info.scopes, ["read_api", "read_user"])
    }

    func testScopeDetection() {
        XCTAssertEqual(GitLabAPI.access(scopes: ["api"]), .canLogTime)
        XCTAssertEqual(GitLabAPI.access(scopes: ["read_api", "api", "read_user"]), .canLogTime)
        XCTAssertEqual(GitLabAPI.access(scopes: ["read_api"]), .readOnly, "read_api: listed, shown as read-only")
        XCTAssertEqual(GitLabAPI.access(scopes: ["read_api", "read_repository"]), .readOnly)
        XCTAssertEqual(GitLabAPI.access(scopes: nil), .readOnly, "the server did not say: never assume api")
        XCTAssertEqual(GitLabAPI.access(scopes: ["read_user"]), .cannotList)
        XCTAssertEqual(GitLabAPI.access(scopes: []), .cannotList)
        XCTAssertEqual(GitLabAPI.access(scopes: ["API", "apis", "write_api"]), .cannotList, "exact scope names only")
    }
}
