//
//  TermsOfUseTests.swift
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

/// Who may use Kannu without seeing the Terms of Use gate, and that the text and the constant agree.
final class TermsOfUseTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testOnlyTheCurrentVersionLetsTheLaunchContinue() {
        XCTAssertFalse(TermsOfUse.isAccepted(acceptedVersion: nil),
                       "every install from before the gate has nil, and must accept once")
        XCTAssertFalse(TermsOfUse.isAccepted(acceptedVersion: 0))
        XCTAssertFalse(TermsOfUse.isAccepted(acceptedVersion: TermsOfUse.currentVersion - 1),
                       "a user who accepted an older version sees the new one")
        XCTAssertTrue(TermsOfUse.isAccepted(acceptedVersion: TermsOfUse.currentVersion))
        XCTAssertTrue(TermsOfUse.isAccepted(acceptedVersion: TermsOfUse.currentVersion + 1),
                      "a downgrade after accepting a newer version does not ask again")
    }

    /// The text and the constant move together. A bumped `TERMS.md` with a stale constant would ship
    /// changed terms nobody is asked to accept; the reverse would ask everyone to re-accept the same
    /// text.
    func testTheConstantMatchesTheTermsDocument() throws {
        let url = Self.repoRoot.appendingPathComponent("TERMS.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(TermsOfUse.declaredVersion(in: text), TermsOfUse.currentVersion,
                       "TERMS.md's Version line and TermsOfUse.currentVersion disagree — bump both together")
    }

    /// The terms must still say the two things this gate exists for, so an edit cannot quietly drop them.
    func testTheTermsStillDisclaimWarrantyAndLiabilityIncludingUnknownVulnerabilities() throws {
        let text = try String(contentsOf: Self.repoRoot.appendingPathComponent("TERMS.md"), encoding: .utf8)
        for phrase in ["**3. No warranty**", "\"as is\"", "**5. Limitation of liability**",
                       "known or unknown", "**4. Security, specifically**", "GPL-3.0"] {
            XCTAssertTrue(text.contains(phrase), "TERMS.md no longer contains \(phrase)")
        }
    }

    func testDeclaredVersionReadsOnlyTheHeader() {
        XCTAssertEqual(TermsOfUse.declaredVersion(in: "# T\n\nVersion 3 · Effective today\n"), 3)
        XCTAssertEqual(TermsOfUse.declaredVersion(in: "# T\n\nVersion 12\n"), 12)
        XCTAssertNil(TermsOfUse.declaredVersion(in: "# T\n\nno version here\n"))
        // Deep in the body, "Version 9" is prose, not the header.
        let body = (0..<20).map { "line \($0)" }.joined(separator: "\n") + "\nVersion 9\n"
        XCTAssertNil(TermsOfUse.declaredVersion(in: body))
    }
}
