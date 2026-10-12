//
//  TimerSessionNameTests.swift
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

/// The name a user types for a timer session: one clean line, never empty, never longer than the
/// notch can show.
final class TimerSessionNameTests: XCTestCase {
    typealias Name = TimerSessionName

    func testATypedNameIsOneCleanLine() {
        XCTAssertEqual(Name.cleaned("  Write   docs \n"), "Write docs")
        XCTAssertEqual(Name.cleaned("Plan\nthe\tweek"), "Plan the week")
    }

    func testNothingTypedIsNoName() {
        XCTAssertNil(Name.cleaned(""))
        XCTAssertNil(Name.cleaned("   \n\t "))
    }

    func testANameIsCappedByCharactersAsTheUserSeesThem() throws {
        let long = String(repeating: "a", count: 60)
        XCTAssertEqual(Name.cleaned(long)?.count, Name.maxLength)
        let emoji = String(repeating: "🍅", count: 50)
        let capped = try XCTUnwrap(Name.cleaned(emoji))
        XCTAssertEqual(capped.count, Name.maxLength, "an emoji counts once")
        XCTAssertTrue(capped.allSatisfy { $0 == "🍅" }, "never cut through the middle of a character")
        XCTAssertFalse(Name.cleaned(String(repeating: "word ", count: 20))?.hasSuffix(" ") ?? true,
                       "a cut never leaves a trailing space")
    }

    func testTheDefaultStandsInForNoName() {
        XCTAssertEqual(Name.resolved(typed: "", fallback: "Focus"), "Focus")
        XCTAssertEqual(Name.resolved(typed: "  ", fallback: "Custom Timer"), "Custom Timer")
        XCTAssertEqual(Name.resolved(typed: " Deep dive ", fallback: "Focus"), "Deep dive")
    }

    func testARenameAppliesOnlyToTheSessionItBeganIn() {
        let session = UUID()
        XCTAssertEqual(Name.renamed(" Review ", begunIn: session, current: session, currentName: "Focus", fallback: "Focus"),
                       "Review")
        XCTAssertNil(Name.renamed("Review", begunIn: session, current: UUID(), currentName: "Break", fallback: "Break"),
                     "saved after a new session started: the new session keeps its name")
    }

    func testAClearedRenameGoesBackToTheDefaultAndAnUnchangedOneIsNoChange() {
        let session = UUID()
        XCTAssertEqual(Name.renamed("  ", begunIn: session, current: session, currentName: "Review", fallback: "Focus"),
                       "Focus")
        XCTAssertNil(Name.renamed("Review ", begunIn: session, current: session, currentName: "Review", fallback: "Focus"))
    }
}
