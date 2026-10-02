//
//  ClaudeCloudRelayManagerRulesTests.swift
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

/// `ClaudeCloudRelayManager` keeps the one connection Kannu holds open to a server the user picked,
/// and it is not compiled into the logic target, so its rules are read from the source (the
/// `LaunchGateRulesTests` idiom): the stream has its own ephemeral session and refuses redirects
/// (its URL carries the topic), Defaults subscriptions fire no initial event (AGENTS.md), and no log
/// line names the user's relay, key, topic, sessions or repositories.
final class ClaudeCloudRelayManagerRulesTests: XCTestCase {
    private static let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Kannu/managers/AgentStatus/ClaudeCloudRelayManager.swift")

    private static let logOpeners = ["log.debug(", "log.info(", "log.notice(", "log.error(", "log.warning(", "log.fault("]
    private static let identifying = ["secret", "credentials", "topic", "url", "server", "endpoint", "session", "repo",
                                      "event", "key"]

    private func code() throws -> String {
        Self.code(try String(contentsOf: Self.sourceURL, encoding: .utf8))
    }

    func testTheStreamHasItsOwnSessionAndRefusesRedirects() throws {
        let code = try code()
        XCTAssertFalse(code.contains("URLSession.shared"), "the shared session's 60 s timeout would cut the stream")
        XCTAssertTrue(code.contains("URLSessionConfiguration.ephemeral"))
        XCTAssertTrue(code.contains("timeoutIntervalForRequest = 150"), "longer than ntfy's 45 s keepalive")
        XCTAssertTrue(code.contains("session.bytes(from: url, delegate: RefuseRedirects())"))
        XCTAssertTrue(code.contains("willPerformHTTPRedirection"))
    }

    func testEveryDefaultsSubscriptionSkipsTheInitialEvent() throws {
        let subscriptions = Self.calls(of: "Defaults.publisher(", in: try code())
        XCTAssertFalse(subscriptions.isEmpty, "no subscription found; this pin would be vacuous")
        XCTAssertTrue(Self.subscriptionOffenders(subscriptions).isEmpty)
    }

    func testNoLogLineNamesTheUsersRelay() throws {
        let code = try code()
        let logs = Self.logOpeners.flatMap { Self.calls(of: $0, in: code) }
        XCTAssertGreaterThanOrEqual(logs.count, 5, "the scan found too few log lines; check the openers, not the rule")
        XCTAssertEqual(Self.logOffenders(logs), [])
    }

    // MARK: - The scanners are not vacuous

    func testTheScannersCatchPlantedOffenders() {
        let planted = """
            // Defaults.publisher(.inAComment) is not code
            Defaults.publisher(.claudeCloudRelayEnabled).sink { _ in }
            Defaults.publisher(keys: .a, .b,
                               options: []).sink { _ in }
            Self.log.notice("listening on \\(server, privacy: .public)")
            log.debug("ignored: \\(String(describing: rejection), privacy: .public)")
            log.notice("topic \\(credentials.topic)")
            """
        let code = Self.code(planted)
        let subscriptions = Self.calls(of: "Defaults.publisher(", in: code)
        XCTAssertEqual(subscriptions.count, 2, "the comment is skipped; the multi-line call is read whole")
        XCTAssertEqual(Self.subscriptionOffenders(subscriptions), ["Defaults.publisher(.claudeCloudRelayEnabled)"])
        let logs = Self.logOpeners.flatMap { Self.calls(of: $0, in: code) }
        XCTAssertEqual(Self.logOffenders(logs).count, 2, "the server and the topic, not the rejection")
    }

    // MARK: - Scanning

    /// The source without comment lines.
    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Each call that starts with `opener` (which ends in "("), through its balanced closing parenthesis.
    private static func calls(of opener: String, in text: String) -> [String] {
        var found: [String] = []
        var searchStart = text.startIndex
        while let range = text.range(of: opener, range: searchStart..<text.endIndex) {
            var depth = 1
            var index = range.upperBound
            while index < text.endIndex, depth > 0 {
                if text[index] == "(" { depth += 1 } else if text[index] == ")" { depth -= 1 }
                index = text.index(after: index)
            }
            found.append(String(text[range.lowerBound..<index]))
            searchStart = range.upperBound
        }
        return found
    }

    private static func subscriptionOffenders(_ subscriptions: [String]) -> [String] {
        subscriptions.filter { !$0.contains("options: []") }
    }

    /// Log calls whose interpolations mention anything that identifies the user's relay.
    private static func logOffenders(_ logs: [String]) -> [String] {
        logs.filter { call in
            calls(of: "\\(", in: call).contains { interpolation in
                identifying.contains { interpolation.lowercased().contains($0) }
            }
        }
    }
}
