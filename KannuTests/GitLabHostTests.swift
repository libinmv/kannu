//
//  GitLabHostTests.swift
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

/// The one server a GitLab token may be sent to. Any HTTPS server is allowed — gitlab.com, a
/// self-managed one on a LAN address, its own port, a path prefix — but only in one shape: no plain
/// HTTP, no user name or password, no query or fragment, no page on the server.
final class GitLabHostTests: XCTestCase {
    private func normalized(_ input: String) -> String? {
        if case .success(let base) = GitLabHost.normalize(input) { return base }
        return nil
    }

    private func error(_ input: String) -> GitLabHostError? {
        if case .failure(let error) = GitLabHost.normalize(input) { return error }
        return nil
    }

    func testGitLabDotCom() {
        XCTAssertEqual(normalized("https://gitlab.com"), "https://gitlab.com")
        XCTAssertEqual(normalized("gitlab.com"), "https://gitlab.com")
        XCTAssertEqual(normalized("  HTTPS://GitLab.com/  "), "https://gitlab.com")
        XCTAssertEqual(normalized("https://gitlab.com:443"), "https://gitlab.com", "the default port is dropped")
        XCTAssertEqual(normalized("https://gitlab.com/dana/app"), "https://gitlab.com", "gitlab.com has no path prefix: a pasted page means the server")
        XCTAssertEqual(normalized("https://gitlab.com/-/user_settings/personal_access_tokens"), "https://gitlab.com")
    }

    func testSelfManagedServers() {
        XCTAssertEqual(normalized("https://gitlab.example.com"), "https://gitlab.example.com")
        XCTAssertEqual(normalized("gitlab.example.com:8443"), "https://gitlab.example.com:8443")
        XCTAssertEqual(normalized("https://example.com/gitlab"), "https://example.com/gitlab", "a path prefix is kept")
        XCTAssertEqual(normalized("https://example.com/gitlab/"), "https://example.com/gitlab")
        XCTAssertEqual(normalized("https://example.com/tools/GitLab"), "https://example.com/tools/GitLab", "a path keeps its case")
        XCTAssertEqual(normalized("https://example.com/gitlab/api/v4"), "https://example.com/gitlab", "a pasted API address is the server")
        XCTAssertEqual(normalized("https://gitlab.example.com/api/v4/"), "https://gitlab.example.com")
    }

    func testPrivateAndLANServersAreAllowed() {
        XCTAssertEqual(normalized("https://192.168.1.20"), "https://192.168.1.20")
        XCTAssertEqual(normalized("https://10.0.0.5:8443/gitlab"), "https://10.0.0.5:8443/gitlab")
        XCTAssertEqual(normalized("gitlab.local"), "https://gitlab.local")
        XCTAssertEqual(normalized("https://gitlab"), "https://gitlab", "a single-label LAN name")
        XCTAssertEqual(normalized("https://git.corp.internal"), "https://git.corp.internal")
    }

    func testPlainHTTPIsRefused() {
        XCTAssertEqual(error("http://gitlab.com"), .notHTTPS)
        XCTAssertEqual(error("http://192.168.1.20"), .notHTTPS)
        XCTAssertEqual(error("ftp://gitlab.com"), .notHTTPS)
        XCTAssertEqual(error("http:/gitlab.com"), .malformed, "a scheme without its slashes is not a host")
        XCTAssertEqual(error("javascript:alert(1)"), .malformed)
    }

    func testUserInfoIsRefused() {
        XCTAssertEqual(error("https://user@gitlab.com"), .userInfo)
        XCTAssertEqual(error("https://user:pass@gitlab.example.com"), .userInfo)
        XCTAssertEqual(error("https://gitlab.com@evil.example"), .userInfo, "reads as gitlab.com, connects to evil.example")
        XCTAssertEqual(error("gitlab.com@evil.example"), .userInfo)
        XCTAssertEqual(error("https://@gitlab.com"), .userInfo)
    }

    func testQueriesFragmentsAndPagesAreRefused() {
        XCTAssertEqual(error("https://gitlab.example.com/?next=https://evil.example"), .queryOrFragment)
        XCTAssertEqual(error("https://gitlab.example.com#x"), .queryOrFragment)
        XCTAssertEqual(error("https://gitlab.example.com/group/app/-/issues/4"), .badPath, "a page on the server, not its address")
        XCTAssertEqual(error("https://example.com/gitlab/../admin"), .badPath)
        XCTAssertEqual(error("https://example.com/git%2Flab"), .badPath)
        XCTAssertEqual(error("https://example.com/git lab"), .malformed)
    }

    func testMalformedServersAreRefused() {
        XCTAssertEqual(error(""), .empty)
        XCTAssertEqual(error("   "), .empty)
        XCTAssertEqual(error("https://"), .malformed)
        XCTAssertEqual(error("https://[::1]"), .malformed, "IPv6 literals are not supported")
        XCTAssertEqual(error("https://gitlab.exam_ple.com"), .malformed)
        XCTAssertEqual(error("https://-gitlab.example.com"), .malformed)
        XCTAssertEqual(error("https://gitlab..example.com"), .malformed)
        XCTAssertEqual(error("https://gitláb.example.com"), .malformed, "non-ASCII")
        XCTAssertEqual(error("https://gitlab.example.com\\@evil.example"), .malformed)
        XCTAssertEqual(error("https://gitlab.example.com:0"), .port)
    }

    func testOnlyANormalizedBaseIsValid() {
        XCTAssertTrue(GitLabHost.isValidBase("https://gitlab.com"))
        XCTAssertTrue(GitLabHost.isValidBase("https://example.com:8443/gitlab"))
        XCTAssertFalse(GitLabHost.isValidBase("gitlab.com"), "the stored form carries its scheme")
        XCTAssertFalse(GitLabHost.isValidBase("https://GitLab.com"))
        XCTAssertFalse(GitLabHost.isValidBase("https://gitlab.com/"))
        XCTAssertFalse(GitLabHost.isValidBase("http://gitlab.com"))
        XCTAssertFalse(GitLabHost.isValidBase(""))
    }

    func testAPIURLs() {
        XCTAssertEqual(GitLabHost.apiURL(base: "https://gitlab.com", path: "/user")?.absoluteString, "https://gitlab.com/api/v4/user")
        XCTAssertEqual(GitLabHost.apiURL(base: "https://example.com:8443/gitlab", path: "/user")?.absoluteString,
                       "https://example.com:8443/gitlab/api/v4/user")
        XCTAssertNil(GitLabHost.apiURL(base: "http://gitlab.com", path: "/user"))
        XCTAssertNil(GitLabHost.apiURL(base: "https://gitlab.com", path: "user"))
        XCTAssertNil(GitLabHost.apiURL(base: "https://gitlab.com", path: "/../user"))
        XCTAssertNil(GitLabHost.apiURL(base: "https://gitlab.com", path: "/user?private_token=x"))
        XCTAssertNil(GitLabHost.apiURL(base: "https://gitlab.com", path: "//evil.example/user"))
    }

    func testDisplayAndTokenPage() {
        XCTAssertEqual(GitLabHost.displayName("https://gitlab.com"), "gitlab.com")
        XCTAssertEqual(GitLabHost.displayName("https://example.com:8443/gitlab"), "example.com:8443/gitlab")
        XCTAssertEqual(GitLabHost.createTokenURL(base: "https://gitlab.com")?.absoluteString,
                       "https://gitlab.com/-/user_settings/personal_access_tokens")
        XCTAssertEqual(GitLabHost.createTokenURL(base: "https://example.com/gitlab")?.absoluteString,
                       "https://example.com/gitlab/-/user_settings/personal_access_tokens")
        XCTAssertNil(GitLabHost.createTokenURL(base: "http://gitlab.com"))
    }

    func testAWebURLIsOpenedOnlyOnItsOwnServer() {
        let base = "https://example.com:8443/gitlab"
        XCTAssertTrue(GitLabHost.isWebURL("https://example.com:8443/gitlab/group/app/-/issues/45", onServer: base))
        XCTAssertTrue(GitLabHost.isWebURL("https://EXAMPLE.com:8443/gitlab/group/app/-/merge_requests/12", onServer: base))
        XCTAssertFalse(GitLabHost.isWebURL("https://evil.example:8443/gitlab/group/app/-/issues/45", onServer: base), "another host")
        XCTAssertFalse(GitLabHost.isWebURL("https://example.com/gitlab/group/app/-/issues/45", onServer: base), "another port")
        XCTAssertFalse(GitLabHost.isWebURL("http://example.com:8443/gitlab/group/app/-/issues/45", onServer: base), "plain http")
        XCTAssertFalse(GitLabHost.isWebURL("https://example.com:8443/other/group/app/-/issues/45", onServer: base), "outside the prefix")
        XCTAssertFalse(GitLabHost.isWebURL("https://example.com:8443/gitlabx/app", onServer: base), "a prefix of the prefix")
        XCTAssertFalse(GitLabHost.isWebURL("https://u@example.com:8443/gitlab/app/-/issues/1", onServer: base), "user info")
        XCTAssertFalse(GitLabHost.isWebURL("https://example.com:8443/gitlab/../admin", onServer: base))
        XCTAssertFalse(GitLabHost.isWebURL("javascript:alert(1)", onServer: base))
        XCTAssertTrue(GitLabHost.isWebURL("https://gitlab.com/group/app/-/issues/45", onServer: "https://gitlab.com"))
        XCTAssertTrue(GitLabHost.isWebURL("https://gitlab.com:443/group/app/-/issues/45", onServer: "https://gitlab.com"))
        XCTAssertFalse(GitLabHost.isWebURL("https://gitlab.com.evil.example/group/app/-/issues/45", onServer: "https://gitlab.com"))
    }
}
