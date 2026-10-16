//
//  RedirectGuardTests.swift
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

/// The real `IntegrationHTTP` session against a `URLProtocol` stub that records every request it
/// is asked for. Nothing leaves this Mac. The Jira host answers 302 to another host; that host must
/// never be asked for anything, and no `Authorization` header may reach any host but the first.
final class RedirectGuardTests: XCTestCase {
    private static let jiraHost = "acme.atlassian.net"
    private static let otherHost = "evil.example"

    /// Answers by host: the Jira host redirects, `big.` sends 5 MB and a byte, `busy.` is rate
    /// limited, anything else answers 200 with `{}`.
    final class StubProtocol: URLProtocol {
        private static let lock = NSLock()
        private static var recorded: [URLRequest] = []

        static func reset() {
            lock.lock()
            recorded = []
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
            Self.lock.unlock()
            guard let client, let url = request.url else { return }
            switch url.host {
            case RedirectGuardTests.jiraHost:
                let location = "https://\(RedirectGuardTests.otherHost)/collect"
                let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                               headerFields: ["Location": location])!
                // What a client that follows redirects would send next: the same headers.
                var next = URLRequest(url: URL(string: location)!)
                next.allHTTPHeaderFields = request.allHTTPHeaderFields
                client.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
                client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(self, didLoad: Data())
                client.urlProtocolDidFinishLoading(self)
            case "busy.atlassian.net":
                let response = HTTPURLResponse(url: url, statusCode: 429, httpVersion: "HTTP/1.1",
                                               headerFields: ["Retry-After": "30"])!
                client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(self, didLoad: Data())
                client.urlProtocolDidFinishLoading(self)
            default:
                let body = url.host == "big.atlassian.net"
                    ? Data(count: IntegrationHTTP.maxBodyBytes + 1)
                    : Data("{}".utf8)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                               headerFields: ["Content-Type": "application/json"])!
                client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(self, didLoad: body)
                client.urlProtocolDidFinishLoading(self)
            }
        }

        override func stopLoading() {}
    }

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
        let configuration = IntegrationHTTP.makeConfiguration(base: .ephemeral)
        configuration.protocolClasses = [StubProtocol.self]
        session = IntegrationHTTP.makeSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    private func credential(site: String = RedirectGuardTests.jiraHost) -> JiraCredential {
        JiraCredential(site: site, email: "user@example.invalid", token: "dummy-token-not-real")
    }

    func testARedirectIsNeverFollowed() async throws {
        let request = try XCTUnwrap(JiraAPI.myselfRequest(credential()))
        let exchange = await IntegrationHTTP.send(request, session: session)

        XCTAssertEqual(exchange.outcome, .redirected(302))
        let requests = StubProtocol.requests()
        XCTAssertEqual(requests.compactMap(\.url?.host), [Self.jiraHost], "the redirect target was asked for something")
        let leaked = requests.filter { $0.url?.host != Self.jiraHost && $0.value(forHTTPHeaderField: "Authorization") != nil }
        XCTAssertTrue(leaked.isEmpty, "the Authorization header reached \(leaked.compactMap(\.url?.host))")
        XCTAssertNotNil(requests.first?.value(forHTTPHeaderField: "Authorization"), "the stub saw the real request")
    }

    /// The stub really redirects: a session without the guard follows it to the other host, with the
    /// header. Without this, the test above could pass against a stub that never redirected at all.
    func testWithoutTheGuardTheRedirectWouldLeakTheHeader() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let unguarded = URLSession(configuration: configuration)
        defer { unguarded.invalidateAndCancel() }
        let request = try XCTUnwrap(JiraAPI.myselfRequest(credential()))
        _ = try? await unguarded.data(for: request)
        let requests = StubProtocol.requests()
        XCTAssertEqual(requests.compactMap(\.url?.host), [Self.jiraHost, Self.otherHost])
        XCTAssertNotNil(requests.last?.value(forHTTPHeaderField: "Authorization"))
    }

    func testTheJiraClientStopsAtARedirect() async throws {
        let request = try XCTUnwrap(JiraAPI.searchRequest(credential(), jql: "", nextPageToken: nil))
        let exchange = await IntegrationHTTP.send(request, session: session)
        XCTAssertEqual(exchange.outcome, .redirected(302))
        XCTAssertEqual(StubProtocol.requests().compactMap(\.url?.host), [Self.jiraHost])
    }

    func testTheDelegateRefusesEveryRedirect() throws {
        let url = try XCTUnwrap(URL(string: "https://\(Self.jiraHost)/rest/api/3/myself"))
        let task = session.dataTask(with: url)
        defer { task.cancel() }
        for status in [301, 302, 303, 307, 308] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                         headerFields: ["Location": "https://\(Self.jiraHost)/elsewhere"]))
            var answered = false
            var next: URLRequest? = URLRequest(url: url)
            RedirectRefusal().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                         newRequest: URLRequest(url: URL(string: "https://\(Self.jiraHost)/elsewhere")!)) { request in
                answered = true
                next = request
            }
            XCTAssertTrue(answered, "\(status)")
            XCTAssertNil(next, "\(status): even a redirect to the same host is refused")
        }
        XCTAssertTrue(session.delegate is RedirectRefusal, "the session refuses too, not only each task")
    }

    func testAnOrdinaryAnswerArrives() async throws {
        let request = try XCTUnwrap(JiraAPI.myselfRequest(credential(site: "other.atlassian.net")))
        let exchange = await IntegrationHTTP.send(request, session: session)
        XCTAssertEqual(exchange.outcome, .ok(200))
        XCTAssertEqual(exchange.data, Data("{}".utf8))
    }

    func testARateLimitCarriesItsWait() async throws {
        let request = try XCTUnwrap(JiraAPI.myselfRequest(credential(site: "busy.atlassian.net")))
        let exchange = await IntegrationHTTP.send(request, session: session)
        XCTAssertEqual(exchange.outcome, .rateLimited(retryAfter: 30))
    }

    func testAnOversizedBodyIsDropped() async throws {
        let request = try XCTUnwrap(JiraAPI.myselfRequest(credential(site: "big.atlassian.net")))
        let exchange = await IntegrationHTTP.send(request, session: session)
        XCTAssertEqual(exchange.outcome, .ok(200))
        XCTAssertNil(exchange.data)
    }

    func testTheConfigurationKeepsNothing() {
        let configuration = IntegrationHTTP.makeConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 20)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 20)
        XCTAssertFalse(configuration.waitsForConnectivity)
    }
}
