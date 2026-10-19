//
//  LinkedMergeRequestTests.swift
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

/// The task card's linked merge requests (David: the "linked MRs" fact opens their list, each one
/// clickable through): the `closed_by` request — the set GitLab's `merge_requests_count` counts —
/// and how each answer becomes a row. The values are dummies; no request leaves this Mac.
final class LinkedMergeRequestTests: XCTestCase {
    private let token = "glpat-dummy-token-not-real"
    private lazy var credential = GitLabCredential(baseURL: "https://gitlab.example.com", token: token)

    func testTheRequestReadsClosedByWithTheTokenInItsHeaderOnly() throws {
        let request = try XCTUnwrap(GitLabAPI.closingMergeRequestsRequest(credential, projectID: 8, iid: 45))
        XCTAssertEqual(request.url?.absoluteString, "https://gitlab.example.com/api/v4/projects/8/issues/45/closed_by?per_page=100&page=1")
        XCTAssertEqual(request.httpMethod, "GET", "read-only")
        XCTAssertEqual(request.value(forHTTPHeaderField: "PRIVATE-TOKEN"), token)
        XCTAssertEqual(request.allHTTPHeaderFields?.count, 2, "Accept and PRIVATE-TOKEN only")
        XCTAssertFalse(request.url?.absoluteString.contains(token) ?? true)
        XCTAssertEqual(request.timeoutInterval, 20)
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testNoRequestForANumberThatIsNotOneOrAServerKannuWouldNotUse() {
        XCTAssertNil(GitLabAPI.closingMergeRequestsRequest(credential, projectID: 0, iid: 45))
        XCTAssertNil(GitLabAPI.closingMergeRequestsRequest(credential, projectID: 8, iid: -1))
        let plain = GitLabCredential(baseURL: "http://gitlab.example.com", token: token)
        XCTAssertNil(GitLabAPI.closingMergeRequestsRequest(plain, projectID: 8, iid: 45))
    }

    private static let answer = """
    [
      {"id": 901, "iid": 12, "project_id": 8, "title": "  Add   the uploads  ", "state": "merged",
       "web_url": "https://gitlab.example.com/group/app/-/merge_requests/12",
       "references": {"full": "group/app!12"}, "draft": false, "author": {"name": "Kim Lee"}},
      {"id": 902, "iid": 3, "project_id": 9, "title": "Fix the vendor client", "state": "opened",
       "web_url": "https://evil.example/collect", "references": {"full": "group/vendors!3"},
       "draft": true, "author": {"name": "Ana"}},
      {"id": 903, "iid": 7, "project_id": 8, "title": null, "state": "superseded",
       "references": {"full": "group/app!7"}}
    ]
    """

    func testEachAnswerBecomesARow() throws {
        let items = try XCTUnwrap(GitLabAPI.decodeItems(Data(Self.answer.utf8)))
        let rows = items.map { GitLabAPI.linkedMergeRequest(from: $0, base: "https://gitlab.example.com", issueProjectID: 8) }

        XCTAssertEqual(rows[0].reference, "!12", "in the issue's own project: the short reference")
        XCTAssertEqual(rows[0].title, "Add the uploads", "cleaned")
        XCTAssertEqual(rows[0].state, .merged)
        XCTAssertEqual(rows[0].author, "Kim Lee")
        XCTAssertEqual(rows[0].webURL?.absoluteString, "https://gitlab.example.com/group/app/-/merge_requests/12")
        XCTAssertFalse(rows[0].isDraft)

        XCTAssertEqual(rows[1].reference, "group/vendors!3", "from another project: the full reference")
        XCTAssertTrue(rows[1].isDraft)
        XCTAssertNil(rows[1].webURL, "a page on another server is never opened")

        XCTAssertEqual(rows[2].title, "!7", "no title: the reference")
        XCTAssertNil(rows[2].state, "a state this version does not know")
        XCTAssertNil(rows[2].webURL)
        XCTAssertEqual(rows.map(\.id), [901, 902, 903])
    }
}
