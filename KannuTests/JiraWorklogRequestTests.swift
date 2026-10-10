//
//  JiraWorklogRequestTests.swift
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

/// The one write to Jira, byte for byte: `POST /rest/api/3/issue/{id}/worklog` with
/// `adjustEstimate=auto` and `notifyUsers=false`, `started` in the Mac's own offset, the `kannu`
/// property marker, an ADF comment only when one was typed — and the read-only check that finds the
/// entry again. Dummy values; nothing is sent.
final class JiraWorklogRequestTests: XCTestCase {
    private let credential = JiraCredential(site: "acme.atlassian.net", email: "user@example.invalid", token: "dummy-token-not-real")
    /// base64("user@example.invalid:dummy-token-not-real"), as in JiraRequestTests.
    private let expectedAuthorization = "Basic dXNlckBleGFtcGxlLmludmFsaWQ6ZHVtbXktdG9rZW4tbm90LXJlYWw="
    private let entry = UUID(uuidString: "6F1C2B9A-3D4E-4F50-8A61-72B3C4D5E6F7")!
    /// 2026-10-04 08:32:00 UTC: 14:02 in India.
    private let started = Date(timeIntervalSince1970: 1_791_102_720)
    private let marker = #""properties":[{"key":"kannu","value":{"entry":"6F1C2B9A-3D4E-4F50-8A61-72B3C4D5E6F7"}}]"#

    private func zone(_ identifier: String) -> TimeZone { TimeZone(identifier: identifier)! }

    private func body(_ request: URLRequest) throws -> String {
        try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
    }

    // MARK: - started

    func testStartedInUTC() {
        XCTAssertEqual(JiraAPI.worklogStarted(started, timeZone: zone("UTC")), "2026-10-04T08:32:00.000+0000")
        XCTAssertEqual(JiraAPI.worklogStarted(started.addingTimeInterval(0.25), timeZone: zone("UTC")), "2026-10-04T08:32:00.250+0000",
                       "milliseconds, three digits")
    }

    func testStartedInIndia() {
        XCTAssertEqual(JiraAPI.worklogStarted(started, timeZone: zone("Asia/Kolkata")), "2026-10-04T14:02:00.000+0530")
    }

    func testStartedFollowsDaylightSavingTime() {
        let berlin = zone("Europe/Berlin")
        XCTAssertEqual(JiraAPI.worklogStarted(Date(timeIntervalSince1970: 1_784_116_800), timeZone: berlin), "2026-07-15T14:00:00.000+0200", "summer")
        XCTAssertEqual(JiraAPI.worklogStarted(Date(timeIntervalSince1970: 1_768_478_400), timeZone: berlin), "2026-01-15T13:00:00.000+0100", "winter")
        // The night the clocks go back: the same wall-clock hour twice, told apart by the offset.
        XCTAssertEqual(JiraAPI.worklogStarted(Date(timeIntervalSince1970: 1_792_889_999), timeZone: berlin), "2026-10-25T02:59:59.000+0200")
        XCTAssertEqual(JiraAPI.worklogStarted(Date(timeIntervalSince1970: 1_792_890_000), timeZone: berlin), "2026-10-25T02:00:00.000+0100")
        let newYork = zone("America/New_York")
        XCTAssertEqual(JiraAPI.worklogStarted(Date(timeIntervalSince1970: 1_784_116_800), timeZone: newYork), "2026-07-15T08:00:00.000-0400")
        XCTAssertEqual(JiraAPI.worklogStarted(Date(timeIntervalSince1970: 1_768_478_400), timeZone: newYork), "2026-01-15T07:00:00.000-0500")
    }

    func testStartedNeverTakesTheUsersCalendarOrDigits() {
        // en_US_POSIX: a Buddhist calendar or Arabic-Indic digits in the user's locale change nothing.
        let text = JiraAPI.worklogStarted(started, timeZone: zone("Asia/Bangkok"))
        XCTAssertEqual(text, "2026-10-04T15:32:00.000+0700")
        XCTAssertTrue(text.unicodeScalars.allSatisfy(\.isASCII))
    }

    func testStartedReadsBack() throws {
        for text in ["2026-10-04T14:02:00.000+0530", "2026-10-04T08:32:00.000+0000"] {
            XCTAssertEqual(try XCTUnwrap(JiraAPI.parseWorklogStarted(text)), started, text)
        }
        XCTAssertNil(JiraAPI.parseWorklogStarted("yesterday"))
    }

    // MARK: - The worklog request

    func testTheWorklogRequest() throws {
        let request = try XCTUnwrap(JiraAPI.addWorklogRequest(
            credential, issueID: "10042", entry: entry, seconds: 4_500, started: started, comment: nil, timeZone: zone("Asia/Kolkata")
        ))
        XCTAssertEqual(request.url?.absoluteString, "https://acme.atlassian.net/rest/api/3/issue/10042/worklog?adjustEstimate=auto&notifyUsers=false")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expectedAuthorization)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 20)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(try body(request), "{\(marker),\"started\":\"2026-10-04T14:02:00.000+0530\",\"timeSpentSeconds\":4500}",
                       "no comment key without a comment")
    }

    func testNotifyUsersIsFalseAndTheEstimateAdjustsItself() throws {
        let request = try XCTUnwrap(JiraAPI.addWorklogRequest(credential, issueID: "10042", entry: entry, seconds: 900, started: started, comment: nil))
        let items = try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems })
        XCTAssertEqual(items, [URLQueryItem(name: "adjustEstimate", value: "auto"), URLQueryItem(name: "notifyUsers", value: "false")],
                       "watchers get no email per entry, and the remaining estimate goes down by the time logged")
    }

    func testThePropertyMarkerIsTheDraftsID() throws {
        let request = try XCTUnwrap(JiraAPI.addWorklogRequest(credential, issueID: "10042", entry: entry, seconds: 900, started: started, comment: nil))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        let properties = try XCTUnwrap(json["properties"] as? [[String: Any]])
        XCTAssertEqual(properties.count, 1)
        XCTAssertEqual(properties[0]["key"] as? String, "kannu")
        XCTAssertEqual((properties[0]["value"] as? [String: String])?["entry"], entry.uuidString)
        XCTAssertEqual(json["timeSpentSeconds"] as? Int, 900)
    }

    func testTheCommentIsAnADFDocument() throws {
        let request = try XCTUnwrap(JiraAPI.addWorklogRequest(
            credential, issueID: "10042", entry: entry, seconds: 4_500, started: started,
            comment: "  Fixed the redirect\r\n\n\tAdded a test  \n", timeZone: zone("UTC")
        ))
        let adf = #"{"content":[{"content":[{"text":"Fixed the redirect","type":"text"}],"type":"paragraph"},{"content":[{"text":"Added a test","type":"text"}],"type":"paragraph"}],"type":"doc","version":1}"#
        XCTAssertEqual(try body(request), "{\"comment\":\(adf),\(marker),\"started\":\"2026-10-04T08:32:00.000+0000\",\"timeSpentSeconds\":4500}",
                       "one plain-text paragraph per line; blank lines and outer spaces dropped")
    }

    func testABlankCommentIsNoComment() throws {
        for blank in ["", "   ", "\n\n", "\t"] {
            let request = try XCTUnwrap(JiraAPI.addWorklogRequest(credential, issueID: "10042", entry: entry, seconds: 900, started: started, comment: blank))
            XCTAssertFalse(try body(request).contains("comment"), "\(blank.debugDescription)")
            XCTAssertNil(JiraAPI.commentDocument(blank))
        }
    }

    func testACommentIsTextNeverMarkup() throws {
        let typed = #"<b>bold</b> *star* [link](https://evil.example) "quoted" \ back"#
        let document = try XCTUnwrap(JiraAPI.commentDocument(typed))
        XCTAssertEqual(document.content.count, 1)
        XCTAssertEqual(document.content[0].content, [JiraADFDocument.TextNode(text: typed)])
        let long = String(repeating: "a", count: JiraAPI.maxCommentLength + 50)
        XCTAssertEqual(JiraAPI.cleanedComment(long)?.count, JiraAPI.maxCommentLength)
    }

    func testNoWorklogIsBuiltForWhatKannuWouldNotSend() {
        XCTAssertNil(JiraAPI.addWorklogRequest(credential, issueID: "PROJ-123", entry: entry, seconds: 900, started: started, comment: nil),
                     "paths use the issue id, never the key")
        XCTAssertNil(JiraAPI.addWorklogRequest(credential, issueID: "", entry: entry, seconds: 900, started: started, comment: nil))
        XCTAssertNil(JiraAPI.addWorklogRequest(credential, issueID: "10042/../../myself", entry: entry, seconds: 900, started: started, comment: nil))
        XCTAssertNil(JiraAPI.addWorklogRequest(credential, issueID: "10042", entry: entry, seconds: 59, started: started, comment: nil),
                     "Jira takes a minute at least")
        XCTAssertNil(JiraAPI.addWorklogRequest(credential, issueID: "10042", entry: entry, seconds: WorkDuration.maxSeconds + 1, started: started, comment: nil))
        for site in ["evil.com", "acme.atlassian.net.evil.com", "127.0.0.1", ""] {
            let other = JiraCredential(site: site, email: credential.email, token: credential.token)
            XCTAssertNil(JiraAPI.addWorklogRequest(other, issueID: "10042", entry: entry, seconds: 900, started: started, comment: nil), site)
            XCTAssertNil(JiraAPI.worklogsRequest(other, issueID: "10042", around: started), site)
        }
    }

    func testTheTokenNeverAppearsInAURLOrTheBody() throws {
        let requests = [
            try XCTUnwrap(JiraAPI.addWorklogRequest(credential, issueID: "10042", entry: entry, seconds: 900, started: started, comment: "note")),
            try XCTUnwrap(JiraAPI.worklogsRequest(credential, issueID: "10042", around: started)),
        ]
        for request in requests {
            let url = try XCTUnwrap(request.url?.absoluteString)
            XCTAssertFalse(url.contains("dummy-token-not-real"), url)
            XCTAssertFalse(url.contains("example.invalid"), url)
            XCTAssertNil(request.url?.user)
            let sent = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            XCTAssertFalse(sent.contains("dummy-token-not-real"))
            XCTAssertFalse(sent.contains("example.invalid"))
        }
    }

    // MARK: - The read-only check

    func testTheCheckIsOneReadOnlyGETAroundTheStart() throws {
        let request = try XCTUnwrap(JiraAPI.worklogsRequest(credential, issueID: "10042", around: started))
        let milliseconds = Int64(1_791_102_720) * 1000
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://acme.atlassian.net/rest/api/3/issue/10042/worklog?startedAfter=\(milliseconds - 60_000)&startedBefore=\(milliseconds + 60_000)&expand=properties"
        )
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expectedAuthorization)
        XCTAssertNil(JiraAPI.worklogsRequest(credential, issueID: "PROJ-1", around: started))
    }

    private let page = """
    {"startAt":0,"maxResults":5000,"total":4,"worklogs":[
      {"id":"100027","author":{"accountId":"5b10ac8d82e05b22cc7d4ef5"},"started":"2026-10-04T14:02:00.000+0530",
       "timeSpentSeconds":4500,"properties":[{"key":"other-app","value":"not an object"}]},
      {"id":"100028","author":{"accountId":"someone-else"},"started":"2026-10-04T08:32:00.000+0000","timeSpentSeconds":4500,
       "properties":[{"key":"kannu","value":{"entry":"6f1c2b9a-3d4e-4f50-8a61-72b3c4d5e6f7"}}]},
      {"id":100029,"author":{"accountId":"5b10ac8d82e05b22cc7d4ef5"},"started":"2026-10-04T08:32:00.000+0000","timeSpentSeconds":900,
       "properties":[{"key":"kannu","value":{"entry":"00000000-0000-0000-0000-000000000000"}}]},
      {"id":"100030"}
    ]}
    """

    func testAWorklogPageReadsLeniently() throws {
        let decoded = try XCTUnwrap(JiraAPI.decodeWorklogPage(Data(page.utf8)), "another app's property must not cost the page")
        XCTAssertEqual(decoded.worklogs.map(\.id), ["100027", "100028", "100029", "100030"])
        XCTAssertNil(decoded.worklogs[0].kannuEntry)
        XCTAssertEqual(decoded.worklogs[1].kannuEntry, "6f1c2b9a-3d4e-4f50-8a61-72b3c4d5e6f7")
        XCTAssertNil(decoded.worklogs[3].accountID)
        XCTAssertEqual(JiraAPI.decodeWorklog(Data(#"{"id":"100031","timeSpentSeconds":900}"#.utf8))?.id, "100031")
    }

    func testTheMarkerFindsTheEntryWhoeverAndWheneverJiraSays() throws {
        let worklogs = try XCTUnwrap(JiraAPI.decodeWorklogPage(Data(page.utf8))).worklogs
        let found = JiraAPI.matchingWorklog(in: worklogs, entry: entry, accountID: "5b10ac8d82e05b22cc7d4ef5", started: started, seconds: 4_500)
        XCTAssertEqual(found?.id, "100028", "the marker wins, compared without case, over an unmarked look-alike")
    }

    func testWithoutTheMarkerTheSameAuthorStartAndLengthMatch() throws {
        let worklogs = try XCTUnwrap(JiraAPI.decodeWorklogPage(Data(page.utf8))).worklogs.filter { $0.id != "100028" }
        let other = UUID()
        XCTAssertEqual(JiraAPI.matchingWorklog(in: worklogs, entry: other, accountID: "5b10ac8d82e05b22cc7d4ef5", started: started, seconds: 4_500)?.id,
                       "100027", "same author, same length, started in the same minute")
        XCTAssertNil(JiraAPI.matchingWorklog(in: worklogs, entry: other, accountID: "5b10ac8d82e05b22cc7d4ef5", started: started, seconds: 4_560),
                     "another length is another entry")
        XCTAssertNil(JiraAPI.matchingWorklog(in: worklogs, entry: other, accountID: "someone-else", started: started, seconds: 4_500))
        XCTAssertNil(JiraAPI.matchingWorklog(in: worklogs, entry: other, accountID: "", started: started, seconds: 4_500),
                     "no account, no fallback")
        XCTAssertNil(JiraAPI.matchingWorklog(in: worklogs, entry: other, accountID: "5b10ac8d82e05b22cc7d4ef5", started: started, seconds: 900),
                     "a worklog marked for another Kannu entry is never this one")
        XCTAssertNil(JiraAPI.matchingWorklog(in: worklogs, entry: other, accountID: "5b10ac8d82e05b22cc7d4ef5",
                                             started: started.addingTimeInterval(120), seconds: 4_500), "two minutes apart")
    }

    // MARK: - Refusals

    func testJirasReasonIsReadAndCleaned() {
        XCTAssertEqual(JiraAPI.refusalReason(Data(#"{"errorMessages":["Time Tracking is not enabled."],"errors":{}}"#.utf8)),
                       "Time Tracking is not enabled.")
        XCTAssertEqual(JiraAPI.refusalReason(Data(#"{"errorMessages":[],"errors":{"timeLogged":"Worklog must not be\nnull."}}"#.utf8)),
                       "Worklog must not be null.", "one line")
        XCTAssertNil(JiraAPI.refusalReason(Data("<html>Bad gateway</html>".utf8)))
        XCTAssertNil(JiraAPI.refusalReason(Data(#"{"errorMessages":[],"errors":{}}"#.utf8)))
        XCTAssertNil(JiraAPI.refusalReason(nil))
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(JiraAPI.refusalReason(Data("{\"errorMessages\":[\"\(long)\"]}".utf8))?.count, 200)
    }
}
