//
//  ClaudeCloudDocsTests.swift
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

/// What the user is told leaves a cloud session is a promise: the consent text, the script's own
/// header and docs/CLOUD-SESSIONS.md must name exactly the fields a report carries. A field added
/// to the protocol fails here until every one of them says so (REGRESSIONS entry 16: a rule stated
/// in more than one place is pinned to the thing that enforces it).
final class ClaudeCloudDocsTests: XCTestCase {

    /// Each field that describes the user's session, in the words the consent text and the script
    /// header use. `v` and `kind` are constants of the protocol, not anything about the user.
    private let described: [String: String] = [
        "session": "session id",
        "state": "light's state",
        "event": "hook event",
        "note": "notification kind",
        "repo": "repository folder's name",
        "ts": "timestamp"
    ]
    private let constants: Set<String> = ["v", "kind"]

    private static let docURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KannuTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("docs/CLOUD-SESSIONS.md")
    }()

    private func doc() throws -> String {
        try String(contentsOf: Self.docURL, encoding: .utf8)
    }

    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"\n#\s*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    func testEveryFieldIsEitherDescribedOrAConstant() {
        XCTAssertEqual(Set(described.keys).union(constants), ClaudeCloudRelay.payloadKeys)
        XCTAssertTrue(Set(described.keys).isDisjoint(with: constants))
    }

    func testTheConsentTextNamesEveryField() {
        let consent = normalized(ClaudeCloudRelaySetup.consentText)
        for (field, words) in described {
            XCTAssertTrue(consent.contains(words), "the consent text does not mention \(field) (\"\(words)\")")
        }
        XCTAssertTrue(consent.contains("Never a prompt, a command, a file or any output"))
    }

    func testTheScriptHeaderNamesEveryField() {
        // The comment block above the script's first statement.
        let header = normalized(ClaudeCloudRelaySetup.scriptSource.components(separatedBy: "\nif ").first ?? "")
        for (field, words) in described {
            XCTAssertTrue(header.contains(words), "the script's header does not mention \(field) (\"\(words)\")")
        }
    }

    func testTheDocsFieldTableIsExactlyThePayload() throws {
        let text = try doc()
        let section = try XCTUnwrap(text.components(separatedBy: "\n## What a report carries\n").dropFirst().first)
            .components(separatedBy: "\n## ").first ?? ""
        let fields = section.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("| `"), let end = line.dropFirst(3).firstIndex(of: "`") else { return nil }
            return String(line[line.index(line.startIndex, offsetBy: 3)..<end])
        }
        XCTAssertEqual(fields.count, Set(fields).count, "a field listed twice")
        XCTAssertEqual(Set(fields), ClaudeCloudRelay.payloadKeys)
        for (field, words) in described {
            let row = try XCTUnwrap(section.split(separator: "\n").first { $0.hasPrefix("| `\(field)`") })
            XCTAssertTrue(row.contains(words), "the docs row for \(field) does not say \"\(words)\"")
        }
    }

    func testTheDocsTestVectorIsTheRealOne() throws {
        let text = try doc()
        let credentials = try XCTUnwrap(ClaudeCloudRelay.credentials(secret: String(repeating: "0123456789abcdef", count: 4)))
        XCTAssertTrue(text.contains("`\(credentials.topic)`"))
        XCTAssertTrue(text.contains("`\(ClaudeCloudRelay.hex(credentials.macKey))`"))
        XCTAssertTrue(text.contains("\"kannu-relay-topic|\""))
        XCTAssertTrue(text.contains("\"kannu-relay-mac|\""))
    }
}
