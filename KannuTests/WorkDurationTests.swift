//
//  WorkDurationTests.swift
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

/// Lengths as people type them into Set Estimate and Add Time.
final class WorkDurationTests: XCTestCase {
    func testTheUsualSpellings() {
        let cases: [(String, Int)] = [
            ("1h 12m", 72 * 60),
            ("1h12m", 72 * 60),
            ("72m", 72 * 60),
            ("72 min", 72 * 60),
            ("1.5h", 90 * 60),
            ("1,5h", 90 * 60),
            ("2h", 7200),
            ("2 hours", 7200),
            ("1 hour 30 minutes", 90 * 60),
            ("  45m ", 45 * 60),
            ("1H 5M", 65 * 60),
        ]
        for (text, seconds) in cases {
            XCTAssertEqual(WorkDuration.parse(text), seconds, text)
        }
    }

    func testABareNumberIsMinutes() {
        XCTAssertEqual(WorkDuration.parse("90"), 90 * 60)
        XCTAssertEqual(WorkDuration.parse("0.5"), 30)
        XCTAssertEqual(WorkDuration.parse("0"), 0)
    }

    func testAnythingElseIsNotALength() {
        for text in ["", "   ", "abc", "1x", "h", "m5", "-5m", "-5", "1..5h", "1h -5m", "five minutes", "inf", "nan"] {
            XCTAssertNil(WorkDuration.parse(text), text)
        }
    }

    func testATypoCannotRecordAYear() {
        XCTAssertNil(WorkDuration.parse("9000h"))
        XCTAssertEqual(WorkDuration.parse("1000h"), 1000 * 3600)
    }

    func testWhatIsFormattedParsesBack() {
        for seconds in [0, 60, 15 * 60, 42 * 60, 3600, 72 * 60, 8 * 3600, 26 * 3600 + 60] {
            XCTAssertEqual(WorkDuration.parse(WorkDuration.format(seconds)), seconds, WorkDuration.format(seconds))
        }
    }
}
