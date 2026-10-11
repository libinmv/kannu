//
//  JiraRequestTests.swift
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

/// Every Jira request, byte for byte: the token only in the `Authorization` header, never in a URL,
/// and only for a Jira Cloud host. The values are dummies; no request is sent.
final class JiraRequestTests: XCTestCase {
    private let credential = JiraCredential(site: "acme.atlassian.net", email: "user@example.invalid", token: "dummy-token-not-real")
    /// base64("user@example.invalid:dummy-token-not-real"), worked out independently.
    private let expectedAuthorization = "Basic dXNlckBleGFtcGxlLmludmFsaWQ6ZHVtbXktdG9rZW4tbm90LXJlYWw="

    func testTheBasicHeaderIsExact() {
        XCTAssertEqual(JiraAPI.basicAuthorization(email: "user@example.invalid", token: "dummy-token-not-real"), expectedAuthorization)
    }

    func testMyselfRequest() throws {
        let request = try XCTUnwrap(JiraAPI.myselfRequest(credential))
        XCTAssertEqual(request.url?.absoluteString, "https://acme.atlassian.net/rest/api/3/myself")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expectedAuthorization)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.timeoutInterval, 20)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testTheFirstSearchPage() throws {
        let request = try XCTUnwrap(JiraAPI.searchRequest(credential, jql: "", nextPageToken: nil))
        XCTAssertEqual(request.url?.absoluteString, "https://acme.atlassian.net/rest/api/3/search/jql")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expectedAuthorization)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 20)
        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(body, #"{"fields":["summary","status","timetracking"],"jql":"assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC","maxResults":100}"#)
    }

    func testALaterSearchPageCarriesItsToken() throws {
        let request = try XCTUnwrap(JiraAPI.searchRequest(credential, jql: #"project = "ABC" ORDER BY rank"#, nextPageToken: "CAEaAggD"))
        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(body, #"{"fields":["summary","status","timetracking"],"jql":"project = \"ABC\" ORDER BY rank","maxResults":100,"nextPageToken":"CAEaAggD"}"#)
        XCTAssertEqual(request.url?.absoluteString, "https://acme.atlassian.net/rest/api/3/search/jql", "the page token is in the body, not the URL")
    }

    func testTheTokenAndEmailNeverAppearInAURL() throws {
        let requests = [
            try XCTUnwrap(JiraAPI.myselfRequest(credential)),
            try XCTUnwrap(JiraAPI.searchRequest(credential, jql: "", nextPageToken: nil)),
            try XCTUnwrap(JiraAPI.searchRequest(credential, jql: "", nextPageToken: "next")),
        ]
        for request in requests {
            let url = try XCTUnwrap(request.url?.absoluteString)
            XCTAssertFalse(url.contains("dummy-token-not-real"), url)
            XCTAssertFalse(url.contains("example.invalid"), url)
            XCTAssertFalse(url.contains("@"), url)
            XCTAssertNil(request.url?.user)
            XCTAssertNil(request.url?.password)
            XCTAssertNil(request.url?.query)
        }
    }

    func testNoRequestIsBuiltForAnotherHost() {
        for site in ["evil.com", "acme.atlassian.net.evil.com", "ACME.atlassian.net", "", "127.0.0.1"] {
            let other = JiraCredential(site: site, email: credential.email, token: credential.token)
            XCTAssertNil(JiraAPI.myselfRequest(other), site)
            XCTAssertNil(JiraAPI.searchRequest(other, jql: "", nextPageToken: nil), site)
        }
    }

    func testTheFilter() {
        XCTAssertEqual(JiraAPI.effectiveJQL(""), JiraAPI.defaultJQL)
        XCTAssertEqual(JiraAPI.effectiveJQL("  \n"), JiraAPI.defaultJQL)
        XCTAssertEqual(JiraAPI.effectiveJQL(" project = ABC "), "project = ABC")
        XCTAssertEqual(JiraAPI.filterSummary(jql: ""), "my open issues")
        XCTAssertEqual(JiraAPI.filterSummary(jql: JiraAPI.defaultJQL), "my open issues")
        XCTAssertEqual(JiraAPI.filterSummary(jql: "project = ABC"), "a custom filter")
    }

    func testTheCredentialNeverPrintsItsSecrets() {
        var dumped = ""
        dump(credential, to: &dumped)
        for text in ["\(credential)", String(reflecting: credential), String(describing: credential), dumped] {
            XCTAssertFalse(text.contains("dummy-token-not-real"), text)
            XCTAssertFalse(text.contains("user@example.invalid"), text)
        }
        XCTAssertTrue("\(credential)".contains("acme.atlassian.net"), "the site is not a secret")
    }

    func testTheKeychainFormRoundTrips() throws {
        let encoded = try XCTUnwrap(credential.encoded())
        XCTAssertEqual(encoded, #"{"email":"user@example.invalid","site":"acme.atlassian.net","token":"dummy-token-not-real"}"#)
        XCTAssertEqual(JiraCredential.decoded(encoded), credential)
        XCTAssertNil(JiraCredential.decoded("not json"))
        XCTAssertNil(JiraCredential.decoded(#"{"site":"acme.atlassian.net"}"#))
    }
}
