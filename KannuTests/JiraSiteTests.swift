//
//  JiraSiteTests.swift
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

/// The API token goes to whatever host `JiraSite.normalize` returns, so it returns exactly one
/// shape — `<site>.atlassian.net` over HTTPS — and refuses everything a pasted or crafted URL
/// could use to point it somewhere else.
final class JiraSiteTests: XCTestCase {
    private func host(_ input: String) -> String? {
        try? JiraSite.normalize(input).get()
    }

    private func error(_ input: String) -> JiraSiteError? {
        if case .failure(let error) = JiraSite.normalize(input) { return error }
        return nil
    }

    func testASiteNameBecomesItsCloudHost() {
        XCTAssertEqual(host("acme"), "acme.atlassian.net")
        XCTAssertEqual(host("acme.atlassian.net"), "acme.atlassian.net")
        XCTAssertEqual(host("ACME.Atlassian.NET"), "acme.atlassian.net")
        XCTAssertEqual(host("  acme.atlassian.net\n"), "acme.atlassian.net", "outer whitespace from a paste is trimmed")
        XCTAssertEqual(host("my-team-2"), "my-team-2.atlassian.net")
    }

    func testAPastedURLBecomesItsHost() {
        XCTAssertEqual(host("https://acme.atlassian.net/jira/software/projects/PROJ/boards/1?selectedIssue=PROJ-1#top"), "acme.atlassian.net")
        XCTAssertEqual(host("HTTPS://acme.atlassian.net"), "acme.atlassian.net")
        XCTAssertEqual(host("https://acme.atlassian.net:443/browse/PROJ-1"), "acme.atlassian.net")
        XCTAssertEqual(host("acme.atlassian.net/browse/PROJ-1"), "acme.atlassian.net")
        XCTAssertEqual(host("acme.atlassian.net:443"), "acme.atlassian.net")
    }

    func testOnlyHTTPS() {
        XCTAssertEqual(error("http://acme.atlassian.net"), .notHTTPS)
        XCTAssertEqual(error("ftp://acme.atlassian.net"), .notHTTPS)
        XCTAssertEqual(error("file:///etc/passwd"), .notHTTPS)
        XCTAssertEqual(error("javascript://acme.atlassian.net"), .notHTTPS)
        // A scheme typed without its slashes must not read as a host called "https".
        XCTAssertEqual(error("https:/acme.atlassian.net"), .malformed)
        XCTAssertEqual(error("http:acme.atlassian.net"), .malformed)
        XCTAssertEqual(error("javascript:alert(1)"), .malformed)
    }

    func testUserInfoIsRefused() {
        XCTAssertEqual(error("a@evil.com"), .userInfo)
        XCTAssertEqual(error("acme.atlassian.net@evil.com"), .userInfo)
        XCTAssertEqual(error("https://acme.atlassian.net@evil.com/"), .userInfo)
        XCTAssertEqual(error("https://user:pass@acme.atlassian.net"), .userInfo)
        XCTAssertEqual(error("https://@acme.atlassian.net"), .userInfo)
    }

    func testOtherPortsAreRefused() {
        XCTAssertEqual(error("https://acme.atlassian.net:8443"), .port)
        XCTAssertEqual(error("acme.atlassian.net:80"), .port)
    }

    func testIPAddressesAreRefused() {
        for input in ["1.2.3.4", "https://127.0.0.1", "https://10.0.0.1/jira", "https://[::1]/", "https://[2001:db8::1]"] {
            XCTAssertNil(host(input), input)
        }
    }

    func testLookAlikesAreRefused() {
        for input in [
            "acme.atlassian.net.evil.com",
            "https://acme.atlassian.net.evil.com/",
            "acme-atlassian.net",
            "a.b.atlassian.net",
            "atlassian.net",
            "acme.atlassian.net.",
            "https://evil.com/acme.atlassian.net",
            "acme.atlassian.com",
            "acme.jira.com",
            "-acme",
            "acme-",
            "evilatlassian.net",
        ] {
            XCTAssertNil(host(input), input)
        }
        XCTAssertEqual(error("acme.atlassian.net.evil.com"), .notAtlassianCloud)
    }

    func testMalformedInputIsRefused() {
        XCTAssertEqual(error(""), .empty)
        XCTAssertEqual(error("   \n"), .empty)
        XCTAssertEqual(error("acme atlassian.net"), .malformed)
        XCTAssertEqual(error("acme\t.atlassian.net"), .malformed)
        XCTAssertEqual(error("acme\\.atlassian.net"), .malformed)
        XCTAssertEqual(error("https://evil.com\\@acme.atlassian.net"), .malformed)
        XCTAssertEqual(error("ácme.atlassian.net"), .malformed, "a homoglyph is not a site name")
        XCTAssertEqual(error("acme\u{0}.atlassian.net"), .malformed)
        XCTAssertEqual(error("acme.atlassian.net\u{202E}"), .malformed)
        XCTAssertEqual(error("acme.atlassian.net\u{7F}"), .malformed)
    }

    func testIsValidHostIsExact() {
        XCTAssertTrue(JiraSite.isValidHost("acme.atlassian.net"))
        XCTAssertTrue(JiraSite.isValidHost("a1-b2.atlassian.net"))
        XCTAssertFalse(JiraSite.isValidHost("ACME.atlassian.net"), "stored hosts are lowercase")
        XCTAssertFalse(JiraSite.isValidHost(".atlassian.net"))
        XCTAssertFalse(JiraSite.isValidHost("a.b.atlassian.net"))
        XCTAssertFalse(JiraSite.isValidHost("acme.atlassian.net.evil.com"))
        XCTAssertFalse(JiraSite.isValidHost(String(repeating: "a", count: 64) + ".atlassian.net"))
        XCTAssertTrue(JiraSite.isValidHost(String(repeating: "a", count: 63) + ".atlassian.net"))
        XCTAssertFalse(JiraSite.isValidHost(""))
    }

    func testAPIURLIsBuiltOnlyForAValidHostAndAPlainPath() {
        XCTAssertEqual(JiraSite.apiURL(host: "acme.atlassian.net", path: "/rest/api/3/myself")?.absoluteString,
                       "https://acme.atlassian.net/rest/api/3/myself")
        XCTAssertNil(JiraSite.apiURL(host: "evil.com", path: "/rest/api/3/myself"))
        XCTAssertNil(JiraSite.apiURL(host: "acme.atlassian.net", path: "rest/api/3/myself"))
        XCTAssertNil(JiraSite.apiURL(host: "acme.atlassian.net", path: "/rest/api/3/myself?x=1"))
        XCTAssertNil(JiraSite.apiURL(host: "acme.atlassian.net", path: "/rest/../../x"))
        XCTAssertNil(JiraSite.apiURL(host: "acme.atlassian.net", path: "//evil.com/x"))
    }

    func testBrowseURLChecksTheKey() {
        XCTAssertEqual(JiraSite.browseURL(host: "acme.atlassian.net", key: "PROJ-123")?.absoluteString,
                       "https://acme.atlassian.net/browse/PROJ-123")
        XCTAssertEqual(JiraSite.browseURL(host: "acme.atlassian.net", key: "A_B2-7")?.absoluteString,
                       "https://acme.atlassian.net/browse/A_B2-7")
        for key in ["proj-1", "1PROJ-1", "PROJ", "PROJ-", "PROJ-1a", "PROJ-1-2", "PROJ-1/../x", "PROJ-1?x", ""] {
            XCTAssertNil(JiraSite.browseURL(host: "acme.atlassian.net", key: key), key)
        }
        XCTAssertNil(JiraSite.browseURL(host: "evil.com", key: "PROJ-1"))
    }
}
