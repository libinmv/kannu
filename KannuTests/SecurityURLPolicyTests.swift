//
//  SecurityURLPolicyTests.swift
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

/// The cloud relay's server is checked on both ends: by Kannu before it streams from it, and by
/// the relay script before a cloud session posts to it. Kannu's check is the stricter one, and
/// everything it accepts the script must accept too, or Kannu would listen where no session can post.
final class SecurityURLPolicyTests: XCTestCase {
    private let accepted = [
        "https://ntfy.sh",
        "https://ntfy.sh/",
        " https://ntfy.example.com/relay \n",
        "https://relay.example.com:8443/ntfy",
        "https://203.0.113.7"
    ]

    private let refused = [
        "", "ntfy.sh", "http://ntfy.sh", "https://ntfy",
        "https://localhost", "https://127.0.0.1", "https://10.0.0.5", "https://172.16.0.1",
        "https://192.168.1.10", "https://169.254.1.1", "https://0.0.0.0", "https://[::1]",
        "https://printer.local", "https://relay.localhost", "https://.ntfy.sh", "https://ntfy..sh",
        "https://user:pw@ntfy.sh", "https://ntfy.sh/?x=1", "https://ntfy.sh/#top", "https://ntfy.sh/a b"
    ]

    func testTheRelayServerIsAPublicHTTPSServerWrittenPlainly() {
        for url in accepted {
            XCTAssertTrue(SecurityURLPolicy.isAllowedCloudRelayServerURL(url), url)
        }
        for url in refused {
            XCTAssertFalse(SecurityURLPolicy.isAllowedCloudRelayServerURL(url), url)
        }
    }

    /// The script's own pattern (`URL_RE`), applied as the script applies it: after trimming and
    /// stripping trailing slashes, and with no `@` anywhere.
    func testTheScriptAcceptsEveryServerKannuAccepts() throws {
        let prefix = "URL_RE = re.compile(r\""
        let line = try XCTUnwrap(ClaudeCloudRelaySetup.scriptSource.split(separator: "\n").first { $0.hasPrefix(prefix) },
                                 "the script's URL_RE moved; this pin would be vacuous")
        let pattern = String(line.dropFirst(prefix.count).dropLast(2))
        let regex = try NSRegularExpression(pattern: pattern)
        for url in accepted {
            var server = url.trimmingCharacters(in: .whitespacesAndNewlines)
            while server.hasSuffix("/") { server.removeLast() }
            XCTAssertNotNil(regex.firstMatch(in: server, range: NSRange(server.startIndex..., in: server)), url)
            XCTAssertFalse(server.contains("@"), url)
        }
    }

    func testTheOtherPoliciesAreUnchanged() {
        XCTAssertTrue(SecurityURLPolicy.isAllowedNtfyServerURL("https://ntfy.sh"))
        XCTAssertFalse(SecurityURLPolicy.isAllowedNtfyServerURL("https://192.168.1.10"))
        XCTAssertTrue(SecurityURLPolicy.isAllowedWebhookURL("https://hooks.example.com/x"))
        XCTAssertFalse(SecurityURLPolicy.isAllowedWebhookURL("https://localhost/x"))
        XCTAssertTrue(SecurityURLPolicy.isAllowedModelEndpoint("http://127.0.0.1:11434"))
        XCTAssertFalse(SecurityURLPolicy.isAllowedModelEndpoint("https://api.example.com"))
    }
}
