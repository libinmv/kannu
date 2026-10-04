//
//  GitLabReaderTests.swift
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

/// A whole GitLab sync and Connect, through the real `IntegrationHTTP` session, against a
/// `URLProtocol` stub that answers from handwritten fixtures and records every request. Nothing
/// leaves this Mac and no real token exists: paging by `X-Next-Page`, the two-page cap, merge
/// requests counted once, one failed page failing the sync, rate limits, scopes, and redirects.
final class GitLabReaderTests: XCTestCase {
    private static let server = "gitlab.example.com"
    private static let token = "glpat-dummy-token-not-real"
    private let credential = GitLabCredential(baseURL: "https://gitlab.example.com", token: GitLabReaderTests.token)

    struct Answer {
        var status = 200
        var headers: [String: String] = [:]
        var body = "[]"
        /// The request fails with this instead of answering: offline, a timeout.
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
            if (300..<400).contains(answer.status), let location = answer.headers["Location"], let target = URL(string: location) {
                var next = URLRequest(url: target)
                next.allHTTPHeaderFields = request.allHTTPHeaderFields
                client.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            }
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data(answer.body.utf8))
            client.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private var session: URLSession!
    private var reader: GitLabReader!

    override func setUp() {
        super.setUp()
        let configuration = IntegrationHTTP.makeConfiguration(base: .ephemeral)
        configuration.protocolClasses = [StubProtocol.self]
        session = IntegrationHTTP.makeSession(configuration: configuration)
        reader = GitLabReader(session: session)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        reader = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private static func item(_ id: Int, iid: Int, kind: GitLabKind, title: String = "Item") -> String {
        let mark = kind == .issue ? "#" : "!"
        let path = kind == .issue ? "issues" : "merge_requests"
        return """
        {"id": \(id), "iid": \(iid), "project_id": 8, "title": "\(title)", "state": "opened",
         "web_url": "https://gitlab.example.com/group/app/-/\(path)/\(iid)",
         "references": {"full": "group/app\(mark)\(iid)"},
         "time_stats": {"time_estimate": 0, "total_time_spent": 0}}
        """
    }

    private static func page(_ items: [String]) -> String { "[" + items.joined(separator: ",") + "]" }

    private static func query(_ request: URLRequest) -> [String: String] {
        guard let url = request.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private static func isReviewList(_ request: URLRequest) -> Bool { query(request)["reviewer_username"] != nil }

    // MARK: - Sync

    func testIssuesAndMergeRequestsInOneSync() async throws {
        StubProtocol.reset { request in
            switch request.url?.path ?? "" {
            case "/api/v4/issues":
                return Answer(headers: ["X-Next-Page": ""], body: Self.page([Self.item(76, iid: 45, kind: .issue)]))
            case "/api/v4/merge_requests" where Self.isReviewList(request):
                return Answer(headers: ["X-Next-Page": ""], body: Self.page([
                    Self.item(31, iid: 12, kind: .mergeRequest, title: "Both lists"),
                    Self.item(32, iid: 13, kind: .mergeRequest, title: "Review only"),
                ]))
            case "/api/v4/merge_requests":
                return Answer(headers: ["X-Next-Page": ""], body: Self.page([Self.item(31, iid: 12, kind: .mergeRequest, title: "Both lists")]))
            default:
                return Answer(status: 404, body: "{}")
            }
        }

        let fetch = await reader.fetchItems(credential, username: "dana", includeMergeRequests: true)

        XCTAssertNil(fetch.failure)
        guard case .fetched(let result) = fetch.outcome else { return XCTFail("\(fetch.outcome)") }
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.issues.map(\.remoteID), ["issue:76", "mr:31", "mr:32"], "the merge request in both lists counts once")
        XCTAssertEqual(result.issues.map(\.status), ["opened", "assigned to you", "review requested"])
        XCTAssertEqual(fetch.issueCount, 1)
        XCTAssertEqual(fetch.mergeRequestCount, 2)

        let requests = StubProtocol.requests()
        XCTAssertEqual(requests.count, 3, "one page of each list")
        XCTAssertEqual(Self.query(requests[0]), ["scope": "assigned_to_me", "state": "opened", "per_page": "100", "page": "1"])
        XCTAssertEqual(Self.query(requests[1]), ["scope": "assigned_to_me", "state": "opened", "per_page": "100", "page": "1"])
        XCTAssertEqual(Self.query(requests[2]), ["reviewer_username": "dana", "state": "opened", "scope": "all", "per_page": "100", "page": "1"])
        for request in requests {
            XCTAssertEqual(request.url?.host, Self.server)
            XCTAssertEqual(request.value(forHTTPHeaderField: "PRIVATE-TOKEN"), Self.token)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertFalse(request.url?.absoluteString.contains(Self.token) ?? true)
        }
    }

    func testWithoutMergeRequestsOnlyIssuesAreRead() async throws {
        StubProtocol.reset { _ in Answer(headers: ["X-Next-Page": ""], body: Self.page([Self.item(76, iid: 45, kind: .issue)])) }
        let fetch = await reader.fetchItems(credential, username: "dana", includeMergeRequests: false)
        guard case .fetched(let result) = fetch.outcome else { return XCTFail("\(fetch.outcome)") }
        XCTAssertEqual(result.issues.map(\.remoteID), ["issue:76"])
        XCTAssertEqual(StubProtocol.requests().map { $0.url?.path }, ["/api/v4/issues"])
    }

    func testThePageNumberComesFromXNextPageAndStopsAtTwo() async throws {
        StubProtocol.reset { request in
            let page = Int(Self.query(request)["page"] ?? "") ?? 0
            let items = (0..<GitLabAPI.pageSize).map { Self.item(page * 1000 + $0, iid: page * 1000 + $0, kind: .issue) }
            return Answer(headers: ["X-Next-Page": String(page + 1)], body: Self.page(items))
        }
        let fetch = await reader.fetchItems(credential, username: "dana", includeMergeRequests: false)
        guard case .fetched(let result) = fetch.outcome else { return XCTFail("\(fetch.outcome)") }
        XCTAssertEqual(StubProtocol.requests().map { Self.query($0)["page"] }, ["1", "2"], "never a third page")
        XCTAssertFalse(result.complete, "there were more: nothing may be marked gone")
        XCTAssertEqual(result.issues.count, 2 * GitLabAPI.pageSize)
    }

    func testAFailedPageFailsTheWholeSync() async throws {
        StubProtocol.reset { request in
            request.url?.path == "/api/v4/issues"
                ? Answer(headers: ["X-Next-Page": ""], body: Self.page([Self.item(76, iid: 45, kind: .issue)]))
                : Answer(status: 500, body: "{}")
        }
        let fetch = await reader.fetchItems(credential, username: "dana", includeMergeRequests: true)
        XCTAssertEqual(fetch.outcome, .failed, "the issues already read are not used")
        XCTAssertEqual(fetch.failure, .http(.ambiguous(500)))
        XCTAssertEqual(StubProtocol.requests().count, 2, "nothing more is asked after a failure")
    }

    func testAnAnswerThatIsNotAListFailsTheSync() async throws {
        StubProtocol.reset { _ in Answer(body: #"{"message":"weird"}"#) }
        let fetch = await reader.fetchItems(credential, username: "dana", includeMergeRequests: false)
        XCTAssertEqual(fetch.outcome, .failed)
        XCTAssertEqual(fetch.failure, .decode)
    }

    func testABadUserNameStopsBeforeAnyMergeRequestQuery() async throws {
        StubProtocol.reset { _ in Answer(headers: ["X-Next-Page": ""]) }
        let fetch = await reader.fetchItems(credential, username: "dana&scope=all", includeMergeRequests: true)
        XCTAssertEqual(fetch.failure, .badUsername)
        XCTAssertEqual(StubProtocol.requests().map { $0.url?.path }, ["/api/v4/issues"])
    }

    func testARateLimitHonoursRateLimitReset() async throws {
        let reset = Int(Date().timeIntervalSince1970) + 120
        StubProtocol.reset { _ in Answer(status: 429, headers: ["RateLimit-Reset": String(reset)], body: "{}") }
        let fetch = await reader.fetchItems(credential, username: "dana", includeMergeRequests: false)
        guard case .http(.rateLimited(let wait))? = fetch.failure else { return XCTFail("\(String(describing: fetch.failure))") }
        XCTAssertTrue((100...121).contains(wait), "the Unix time GitLab gave, as a wait: \(wait)")
    }

    func testRetryAfterWinsOverRateLimitReset() async throws {
        let reset = Int(Date().timeIntervalSince1970) + 900
        StubProtocol.reset { _ in Answer(status: 429, headers: ["Retry-After": "30", "RateLimit-Reset": String(reset)], body: "{}") }
        let fetch = await reader.fetchItems(credential, username: "dana", includeMergeRequests: false)
        XCTAssertEqual(fetch.failure, .http(.rateLimited(retryAfter: 30)))
    }

    // MARK: - Connect

    private static let userJSON = #"{"id": 1, "username": "dana", "name": "Dana Smith"}"#

    func testVerifyReadsTheScopes() async throws {
        StubProtocol.reset { request in
            request.url?.path == "/api/v4/user"
                ? Answer(body: Self.userJSON)
                : Answer(body: #"{"id": 4, "scopes": ["read_api"], "active": true}"#)
        }
        let result = await reader.verify(credential)
        XCTAssertEqual(result, .verified(GitLabUser(id: 1, username: "dana", name: "Dana Smith"), scopes: ["read_api"]))
        XCTAssertEqual(StubProtocol.requests().map { $0.url?.path }, ["/api/v4/user", "/api/v4/personal_access_tokens/self"])
    }

    func testAServerThatCannotSayItsScopesIsReadOnly() async throws {
        StubProtocol.reset { request in
            request.url?.path == "/api/v4/user" ? Answer(body: Self.userJSON) : Answer(status: 404, body: #"{"message":"404 Not Found"}"#)
        }
        let result = await reader.verify(credential)
        guard case .verified(_, let scopes) = result else { return XCTFail("\(result)") }
        XCTAssertNil(scopes)
        XCTAssertEqual(GitLabAPI.access(scopes: scopes), .readOnly)
    }

    /// Nothing asks for the scopes again after Connect, so a scopes request that failed for a reason
    /// that may pass must fail Connect (a try-again message), never save an `api` token as read-only
    /// or let a `read_user` one through as if the server could not say.
    func testAScopesRequestThatMayPassNextTimeFailsTheCheck() async throws {
        let cases: [(Answer, GitLabReader.Failure)] = [
            (Answer(status: 429, headers: ["Retry-After": "30"], body: "{}"), .http(.rateLimited(retryAfter: 30))),
            (Answer(status: 500, body: "{}"), .http(.ambiguous(500))),
            (Answer(status: 503, body: "{}"), .http(.ambiguous(503))),
            (Answer(error: .timedOut), .http(.ambiguous(nil))),
            (Answer(error: .notConnectedToInternet), .http(.offline)),
            (Answer(error: .serverCertificateUntrusted), .http(.failedBeforeSend)),
        ]
        for (scopesAnswer, failure) in cases {
            StubProtocol.reset { request in
                request.url?.path == "/api/v4/user" ? Answer(body: Self.userJSON) : scopesAnswer
            }
            let result = await reader.verify(credential)
            XCTAssertEqual(result, .failed(failure))
            XCTAssertEqual(StubProtocol.requests().map { $0.url?.path }, ["/api/v4/user", "/api/v4/personal_access_tokens/self"])
        }
    }

    /// A refusal is the server's answer, and asking again gets the same one: it cannot say.
    func testAScopesRequestTheServerRefusesIsReadOnly() async throws {
        for status in [401, 403, 404] {
            StubProtocol.reset { request in
                request.url?.path == "/api/v4/user" ? Answer(body: Self.userJSON) : Answer(status: status, body: "{}")
            }
            let result = await reader.verify(credential)
            XCTAssertEqual(result, .verified(GitLabUser(id: 1, username: "dana", name: "Dana Smith"), scopes: nil), "\(status)")
        }
    }

    func testARefusedTokenIsNotAskedAboutItsScopes() async throws {
        StubProtocol.reset { _ in Answer(status: 401, body: #"{"message":"401 Unauthorized"}"#) }
        let result = await reader.verify(credential)
        XCTAssertEqual(result, .failed(.http(.auth(401))))
        XCTAssertEqual(StubProtocol.requests().count, 1)
    }

    func testARedirectNeverCarriesTheToken() async throws {
        StubProtocol.reset { request in
            request.url?.host == Self.server
                ? Answer(status: 302, headers: ["Location": "https://evil.example/collect"], body: "")
                : Answer(body: Self.userJSON)
        }
        let result = await reader.verify(credential)
        XCTAssertEqual(result, .failed(.http(.redirected(302))))
        let requests = StubProtocol.requests()
        XCTAssertEqual(requests.compactMap(\.url?.host), [Self.server], "the redirect target was asked for something")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "PRIVATE-TOKEN"), Self.token, "the stub saw the real request")
    }

    func testNoRequestLeavesForAServerKannuWouldNotUse() async throws {
        StubProtocol.reset { _ in Answer(body: Self.userJSON) }
        let other = GitLabCredential(baseURL: "http://gitlab.example.com", token: Self.token)
        let verified = await reader.verify(other)
        let fetched = await reader.fetchItems(other, username: "dana", includeMergeRequests: true)
        XCTAssertEqual(verified, .failed(.badServer))
        XCTAssertEqual(fetched.failure, .badServer)
        XCTAssertTrue(StubProtocol.requests().isEmpty)
    }
}
