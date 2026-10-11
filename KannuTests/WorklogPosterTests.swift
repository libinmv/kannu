//
//  WorklogPosterTests.swift
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

/// Sending a confirmed entry, through the real `IntegrationHTTP` session, against a `URLProtocol`
/// stub that answers from handwritten fixtures and records every request. Nothing leaves this Mac
/// and no real token exists. What each answer means (§6 of the design): 2xx logged with the worklog
/// id, 400/403/404 refused with the server's reason, 401 the token, 429 and offline never sent, and
/// a lost answer checked with exactly one read-only GET on Jira — never on GitLab, which cannot find
/// an entry again.
final class WorklogPosterTests: XCTestCase {
    private let jira = JiraCredential(site: "acme.atlassian.net", email: "user@example.invalid", token: "dummy-token-not-real")
    private let gitlab = GitLabCredential(baseURL: "https://gitlab.example.com", token: "glpat-dummy-token-not-real")
    private let entry = UUID(uuidString: "6F1C2B9A-3D4E-4F50-8A61-72B3C4D5E6F7")!
    private let started = Date(timeIntervalSince1970: 1_791_102_720)
    private let accountID = "5b10ac8d82e05b22cc7d4ef5"

    struct Answer {
        var status = 200
        var headers: [String: String] = [:]
        var body = "{}"
        var error: URLError.Code?
    }

    final class StubProtocol: URLProtocol {
        private static let lock = NSLock()
        private static var recorded: [URLRequest] = []
        private static var answer: (URLRequest) -> Answer = { _ in Answer() }

        static func reset(_ answer: @escaping (URLRequest) -> Answer) {
            lock.lock()
            recorded = []
            self.answer = answer
            lock.unlock()
        }

        static func requests() -> [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            Self.recorded.append(request)
            let answer = Self.answer(request)
            Self.lock.unlock()
            guard let client, let url = request.url else { return }
            if let code = answer.error {
                client.urlProtocol(self, didFailWithError: URLError(code))
                return
            }
            var headers = answer.headers
            headers["Content-Type"] = "application/json"
            let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data(answer.body.utf8))
            client.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private var session: URLSession!
    private var poster: WorklogPoster!

    override func setUp() {
        super.setUp()
        let configuration = IntegrationHTTP.makeConfiguration(base: .ephemeral)
        configuration.protocolClasses = [StubProtocol.self]
        session = IntegrationHTTP.makeSession(configuration: configuration)
        poster = WorklogPoster(session: session)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        poster = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private var lookup: JiraWorklogLookup {
        JiraWorklogLookup(credential: jira, issueID: "10042", entry: entry, accountID: accountID, started: started, seconds: 4_500)
    }

    private func jiraRequest() throws -> URLRequest {
        try XCTUnwrap(JiraAPI.addWorklogRequest(jira, issueID: "10042", entry: entry, seconds: 4_500, started: started, comment: nil))
    }

    private func gitlabRequest() throws -> URLRequest {
        try XCTUnwrap(GitLabAPI.addSpentTimeRequest(gitlab, kind: .mergeRequest, projectID: 8, iid: 12, seconds: 4_500))
    }

    private static let marked = """
    {"worklogs":[{"id":"100028","author":{"accountId":"5b10ac8d82e05b22cc7d4ef5"},"started":"2026-10-04T08:32:00.000+0000",
     "timeSpentSeconds":4500,"properties":[{"key":"kannu","value":{"entry":"6F1C2B9A-3D4E-4F50-8A61-72B3C4D5E6F7"}}]}]}
    """

    private static func isPOST(_ request: URLRequest) -> Bool { request.httpMethod == "POST" }

    // MARK: - Jira

    func testA201IsLoggedWithTheWorklogID() async throws {
        StubProtocol.reset { _ in Answer(status: 201, body: #"{"id":"100028","timeSpentSeconds":4500}"#) }
        let verdict = await poster.postJiraWorklog(try jiraRequest(), lookup: lookup)
        XCTAssertEqual(verdict, .logged(remoteID: "100028"))
        let requests = StubProtocol.requests()
        XCTAssertEqual(requests.count, 1, "no check after an answer")
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.query, "adjustEstimate=auto&notifyUsers=false")
    }

    func testRefusalsCarryJirasReason() async throws {
        for status in [400, 403, 404] {
            StubProtocol.reset { _ in Answer(status: status, body: #"{"errorMessages":["Time Tracking is not enabled."],"errors":{}}"#) }
            let verdict = await poster.postJiraWorklog(try jiraRequest(), lookup: lookup)
            XCTAssertEqual(verdict, .refused(status: status, reason: "Time Tracking is not enabled."), "\(status)")
            XCTAssertEqual(StubProtocol.requests().count, 1, "a refusal is an answer: no check")
            let resolution = WorklogDrafts.resolution(of: verdict, source: .jira)
            XCTAssertEqual(resolution.event, .rejected)
            XCTAssertTrue(resolution.message?.contains("Time Tracking is not enabled.") == true, resolution.message ?? "")
            XCTAssertEqual(WorklogDrafts.transition(.sending, on: resolution.event), .failed)
        }
    }

    func testA401AsksForANewToken() async throws {
        StubProtocol.reset { _ in Answer(status: 401) }
        let verdict = await poster.postJiraWorklog(try jiraRequest(), lookup: lookup)
        XCTAssertEqual(verdict, .authRejected(status: 401))
        let resolution = WorklogDrafts.resolution(of: verdict, source: .jira)
        XCTAssertEqual(resolution.event, .rejected)
        XCTAssertTrue(resolution.message?.contains("Reconnect Jira") == true, resolution.message ?? "")
    }

    func testRateLimitsAndOfflineWereNeverSent() async throws {
        StubProtocol.reset { _ in Answer(status: 429, headers: ["Retry-After": "30"]) }
        let limited = await poster.postJiraWorklog(try jiraRequest(), lookup: lookup)
        XCTAssertEqual(limited, .notSent(.rateLimited(retryAfter: 30)))
        XCTAssertEqual(StubProtocol.requests().count, 1)

        StubProtocol.reset { _ in Answer(error: .notConnectedToInternet) }
        let offline = await poster.postJiraWorklog(try jiraRequest(), lookup: lookup)
        XCTAssertEqual(offline, .notSent(.offline))
        XCTAssertEqual(StubProtocol.requests().count, 1, "a send that never left is never checked")
        XCTAssertEqual(WorklogDrafts.resolution(of: offline, source: .jira).event, .rejected, "failed, and Retry sends it")
    }

    func testALostAnswerIsCheckedOnceAndFoundIsLogged() async throws {
        for lost in [Answer(error: .timedOut), Answer(error: .networkConnectionLost), Answer(status: 502), Answer(status: 504)] {
            StubProtocol.reset { request in Self.isPOST(request) ? lost : Answer(status: 200, body: Self.marked) }
            let verdict = await poster.postJiraWorklog(try jiraRequest(), lookup: lookup)
            XCTAssertEqual(verdict, .logged(remoteID: "100028"), "\(lost)")
            let requests = StubProtocol.requests()
            XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET"], "exactly one read-only check")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false)?.queryItems?.last,
                           URLQueryItem(name: "expand", value: "properties"))
            XCTAssertNil(requests[1].httpBody)
        }
    }

    func testALostAnswerWithNoEntryThereFailsAndCanBeRetried() async throws {
        StubProtocol.reset { request in Self.isPOST(request) ? Answer(error: .timedOut) : Answer(status: 200, body: #"{"worklogs":[]}"#) }
        let verdict = await poster.postJiraWorklog(try jiraRequest(), lookup: lookup)
        XCTAssertEqual(verdict, .checkedNotFound)
        XCTAssertEqual(StubProtocol.requests().count, 2)
        let resolution = WorklogDrafts.resolution(of: verdict, source: .jira)
        XCTAssertEqual(WorklogDrafts.transition(.sending, on: resolution.event), .failed)
        XCTAssertEqual(WorklogDrafts.transition(.failed, on: .retry), .sending, "retryable")
    }

    func testALostAnswerWhoseCheckFailsTooIsUncertain() async throws {
        StubProtocol.reset { _ in Answer(error: .timedOut) }
        let verdict = await poster.postJiraWorklog(try jiraRequest(), lookup: lookup)
        XCTAssertEqual(verdict, .uncertain)
        XCTAssertEqual(StubProtocol.requests().map(\.httpMethod), ["POST", "GET"], "one check, never a loop")
        let resolution = WorklogDrafts.resolution(of: verdict, source: .jira)
        XCTAssertEqual(WorklogDrafts.transition(.sending, on: resolution.event), .uncertain)
    }

    func testTheCheckAloneFindsOrMisses() async {
        StubProtocol.reset { _ in Answer(status: 200, body: Self.marked) }
        let found = await poster.findJiraWorklog(lookup)
        XCTAssertEqual(found, .found(remoteID: "100028"))
        XCTAssertEqual(StubProtocol.requests().map(\.httpMethod), ["GET"], "the check never writes")

        StubProtocol.reset { _ in Answer(status: 200, body: #"{"worklogs":[]}"#) }
        let missing = await poster.findJiraWorklog(lookup)
        XCTAssertEqual(missing, .notFound)

        StubProtocol.reset { _ in Answer(error: .notConnectedToInternet) }
        let offline = await poster.findJiraWorklog(lookup)
        XCTAssertEqual(offline, .failed(.offline))
    }

    // MARK: - GitLab

    func testGitLabLogsOnA201() async throws {
        StubProtocol.reset { _ in Answer(status: 201, body: #"{"time_estimate":0,"total_time_spent":4500}"#) }
        let verdict = await poster.postGitLabSpend(try gitlabRequest())
        XCTAssertEqual(verdict, .logged(remoteID: nil), "GitLab returns no entry id")
        let requests = StubProtocol.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.path, "/api/v4/projects/8/merge_requests/12/add_spent_time")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "PRIVATE-TOKEN"), "glpat-dummy-token-not-real")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
    }

    func testGitLabsLostAnswerIsUncertainAndNeverChecked() async throws {
        for lost in [Answer(error: .timedOut), Answer(error: .networkConnectionLost), Answer(status: 502), Answer(status: 504)] {
            StubProtocol.reset { _ in lost }
            let verdict = await poster.postGitLabSpend(try gitlabRequest())
            XCTAssertEqual(verdict, .uncertain, "\(lost)")
            XCTAssertEqual(StubProtocol.requests().count, 1, "GitLab cannot find one entry again, so nothing is asked")
            let resolution = WorklogDrafts.resolution(of: verdict, source: .gitlab)
            XCTAssertEqual(resolution.message, "May already be logged — check GitLab")
            XCTAssertEqual(WorklogDrafts.transition(.sending, on: resolution.event), .uncertain)
        }
    }

    func testGitLabRefusals() async throws {
        StubProtocol.reset { _ in Answer(status: 403, body: #"{"message":"403 Forbidden"}"#) }
        let forbidden = await poster.postGitLabSpend(try gitlabRequest())
        XCTAssertEqual(forbidden, .refused(status: 403, reason: "403 Forbidden"))
        XCTAssertTrue(WorklogDrafts.resolution(of: forbidden, source: .gitlab).message?.contains("api scope") == true)

        StubProtocol.reset { _ in Answer(status: 401, body: #"{"message":"401 Unauthorized"}"#) }
        let unauthorized = await poster.postGitLabSpend(try gitlabRequest())
        XCTAssertEqual(unauthorized, .authRejected(status: 401))

        StubProtocol.reset { _ in Answer(status: 429, headers: ["RateLimit-Reset": "30"]) }
        let limited = await poster.postGitLabSpend(try gitlabRequest())
        XCTAssertEqual(limited, .notSent(.rateLimited(retryAfter: 30)))
    }

    func testARedirectIsRefusedNotFollowed() async throws {
        StubProtocol.reset { _ in Answer(status: 302, headers: ["Location": "https://evil.example/collect"]) }
        let verdict = await poster.postGitLabSpend(try gitlabRequest())
        XCTAssertEqual(verdict, .refused(status: 302, reason: nil))
        XCTAssertEqual(StubProtocol.requests().count, 1)
        XCTAssertEqual(StubProtocol.requests().first?.url?.host, "gitlab.example.com")
    }
}
