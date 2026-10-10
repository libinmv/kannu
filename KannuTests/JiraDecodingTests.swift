//
//  JiraDecodingTests.swift
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

/// Jira's answers, from handwritten fixtures in the shape the Jira Cloud REST API v3 documents, and
/// the paging decisions: when to fetch another page, when to stop, and when a stop is incomplete.
final class JiraDecodingTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testMyself() throws {
        let myself = try XCTUnwrap(JiraAPI.decodeMyself(data("""
            {"self":"https://acme.atlassian.net/rest/api/3/user?accountId=5b10ac8d82e05b22cc7d4ef5",
             "accountId":"5b10ac8d82e05b22cc7d4ef5","accountType":"atlassian",
             "emailAddress":"dana@example.invalid","displayName":"Dana Example","active":true,
             "timeZone":"Europe/London","locale":"en_GB"}
            """)))
        XCTAssertEqual(myself, JiraMyself(accountId: "5b10ac8d82e05b22cc7d4ef5", displayName: "Dana Example"))
        XCTAssertNil(JiraAPI.decodeMyself(data(#"{"displayName":"No id"}"#)))
        XCTAssertNil(JiraAPI.decodeMyself(data("<html>Not Jira</html>")))
    }

    func testAPageWithMoreToCome() throws {
        let page = try XCTUnwrap(JiraAPI.decodeSearchPage(data("""
            {"issues":[
              {"expand":"","id":"10001","self":"https://acme.atlassian.net/rest/api/3/issue/10001","key":"PROJ-1",
               "fields":{"summary":"Fix the login redirect",
                         "status":{"name":"In Progress","id":"3","statusCategory":{"id":4,"key":"indeterminate","name":"In Progress"}},
                         "timetracking":{"originalEstimate":"2h","remainingEstimate":"1h","timeSpent":"3h",
                                         "originalEstimateSeconds":7200,"remainingEstimateSeconds":3600,"timeSpentSeconds":10800}}},
              {"id":"10002","key":"PROJ-2",
               "fields":{"summary":"Write the docs","status":{"name":"To Do","statusCategory":{"key":"new"}},"timetracking":{}}}
             ],
             "nextPageToken":"CAEaAggD","isLast":false}
            """)))
        XCTAssertEqual(page.issues.count, 2)
        XCTAssertEqual(page.nextPageToken, "CAEaAggD")
        XCTAssertEqual(page.isLast, false)

        let first = JiraAPI.remoteIssue(from: page.issues[0])
        XCTAssertEqual(first, RemoteIssue(remoteID: "10001", key: "PROJ-1", title: "Fix the login redirect", status: "In Progress",
                                          isDoneRemotely: false, estimateSeconds: 7200, spentSeconds: 10800))
        let second = JiraAPI.remoteIssue(from: page.issues[1])
        XCTAssertNil(second.estimateSeconds, "an empty timetracking object has no estimate")
        XCTAssertNil(second.spentSeconds)
        XCTAssertEqual(second.status, "To Do")

        XCTAssertEqual(JiraAPI.nextStep(after: page, pagesFetched: 1), .next("CAEaAggD"))
        XCTAssertEqual(JiraAPI.nextStep(after: page, pagesFetched: 2), .capped, "two pages is all Kannu reads")
    }

    func testTheLastPage() throws {
        let page = try XCTUnwrap(JiraAPI.decodeSearchPage(data("""
            {"issues":[{"id":"10003","key":"OPS-9","fields":{"summary":"Rotate the keys","status":{"name":"Done","statusCategory":{"key":"done"}}}}],
             "isLast":true}
            """)))
        XCTAssertEqual(JiraAPI.nextStep(after: page, pagesFetched: 1), .done(complete: true))
        let issue = JiraAPI.remoteIssue(from: page.issues[0])
        XCTAssertTrue(issue.isDoneRemotely)
        XCTAssertNil(issue.estimateSeconds, "no timetracking field at all: time tracking is off")
    }

    func testAnEmptyResult() throws {
        let page = try XCTUnwrap(JiraAPI.decodeSearchPage(data(#"{"issues":[],"isLast":true}"#)))
        XCTAssertTrue(page.issues.isEmpty)
        XCTAssertEqual(JiraAPI.nextStep(after: page, pagesFetched: 1), .done(complete: true))
    }

    func testMissingPiecesFallBack() throws {
        let page = try XCTUnwrap(JiraAPI.decodeSearchPage(data("""
            {"issues":[
              {"id":"1","key":"A-1","fields":{"summary":"","status":{"name":"Open"}}},
              {"id":"2","key":"A-2","fields":{"summary":"  \\n  "}},
              {"id":"3","key":"A-3","fields":{"summary":"Two\\nlines\\tand  spaces","unknownField":{"x":1}}},
              {"id":"4","key":"A-4","fields":{}}
             ]}
            """)))
        let issues = page.issues.map(JiraAPI.remoteIssue(from:))
        XCTAssertEqual(issues[0].title, "A-1", "an empty summary is titled by its key")
        XCTAssertFalse(issues[0].isDoneRemotely, "a status without a category is not done")
        XCTAssertEqual(issues[0].status, "Open")
        XCTAssertEqual(issues[1].title, "A-2")
        XCTAssertEqual(issues[1].status, "", "no status")
        XCTAssertEqual(issues[2].title, "Two lines and spaces", "a title is one clean line")
        XCTAssertEqual(issues[3].title, "A-4")
        XCTAssertEqual(JiraAPI.nextStep(after: page, pagesFetched: 1), .done(complete: true),
                       "no token and no isLast: nothing more to read")
    }

    func testALongSummaryIsCut() throws {
        let long = String(repeating: "x", count: 500)
        let page = try XCTUnwrap(JiraAPI.decodeSearchPage(data(#"{"issues":[{"id":"1","key":"A-1","fields":{"summary":"\#(long)"}}]}"#)))
        XCTAssertEqual(JiraAPI.remoteIssue(from: page.issues[0]).title.count, TaskItem.maxTitleLength)
    }

    func testPagingDecisions() {
        func page(token: String?, isLast: Bool?) -> JiraSearchPage {
            JiraSearchPage(issues: [], nextPageToken: token, isLast: isLast)
        }
        XCTAssertEqual(JiraAPI.nextStep(after: page(token: "t", isLast: false), pagesFetched: 1), .next("t"))
        XCTAssertEqual(JiraAPI.nextStep(after: page(token: "t", isLast: nil), pagesFetched: 1), .next("t"))
        XCTAssertEqual(JiraAPI.nextStep(after: page(token: "t", isLast: false), pagesFetched: 2), .capped)
        XCTAssertEqual(JiraAPI.nextStep(after: page(token: "t", isLast: true), pagesFetched: 1), .done(complete: true),
                       "isLast wins over a stray token")
        XCTAssertEqual(JiraAPI.nextStep(after: page(token: nil, isLast: true), pagesFetched: 2), .done(complete: true))
        XCTAssertEqual(JiraAPI.nextStep(after: page(token: nil, isLast: false), pagesFetched: 1), .done(complete: false),
                       "more to come but no way to ask for it: incomplete, so nothing is marked gone")
        XCTAssertEqual(JiraAPI.nextStep(after: page(token: "", isLast: false), pagesFetched: 1), .done(complete: false))
        XCTAssertEqual(JiraAPI.maxPages, 2)
        XCTAssertEqual(JiraAPI.pageSize, 100)
    }

    func testNotJiraDoesNotDecode() {
        XCTAssertNil(JiraAPI.decodeSearchPage(data("")))
        XCTAssertNil(JiraAPI.decodeSearchPage(data("<html><body>Sign in</body></html>")))
        XCTAssertNil(JiraAPI.decodeSearchPage(data(#"{"errorMessages":["The value 'X' does not exist for the field 'project'."]}"#)))
        XCTAssertNil(JiraAPI.decodeSearchPage(data(#"{"issues":[{"key":"A-1","fields":{}}]}"#)), "an issue without an id")
    }
}
