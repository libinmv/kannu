//
//  TimerDurationDigitsTests.swift
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

/// The composer's Hours, Minutes and Seconds boxes: two digits at rest; while typing, digits only,
/// a clock's shift for a digit too many, and never past the range.
final class TimerDurationDigitsTests: XCTestCase {
    private let minutes = 0...59
    private let hours = 0...23

    func testTheBoxShowsTwoDigitsAtRest() {
        XCTAssertEqual(TimerDurationDigits.text(0), "00")
        XCTAssertEqual(TimerDurationDigits.text(5), "05")
        XCTAssertEqual(TimerDurationDigits.text(59), "59")
    }

    func testTheValueIsTheDigitsKeptInRange() {
        XCTAssertEqual(TimerDurationDigits.value(of: "10", in: minutes), 10)
        XCTAssertEqual(TimerDurationDigits.value(of: "", in: minutes), 0, "nothing typed is the start")
        XCTAssertEqual(TimerDurationDigits.value(of: "7a", in: minutes), 7)
        XCTAssertEqual(TimerDurationDigits.value(of: "99", in: minutes), 59)
        XCTAssertEqual(TimerDurationDigits.value(of: "30", in: hours), 23)
        XCTAssertEqual(TimerDurationDigits.value(of: "٣", in: minutes), 0, "another script's digits are not a number here")
    }

    func testTypingKeepsTheUsersTextWhenItIsAlreadyFine() {
        XCTAssertNil(TimerDurationDigits.rewriteWhileEditing("1", in: minutes), "one digit, mid-typing")
        XCTAssertNil(TimerDurationDigits.rewriteWhileEditing("45", in: minutes))
        XCTAssertNil(TimerDurationDigits.rewriteWhileEditing("", in: minutes), "an emptied box stays empty while typing")
    }

    func testTypingShiftsLikeAClockAndNeverPassesTheRange() {
        XCTAssertEqual(TimerDurationDigits.rewriteWhileEditing("005", in: minutes), "05", "typing 5 into 00 reads 05")
        XCTAssertEqual(TimerDurationDigits.rewriteWhileEditing("103", in: minutes), "03")
        XCTAssertEqual(TimerDurationDigits.rewriteWhileEditing("4x", in: minutes), "4", "letters never stay")
        XCTAssertEqual(TimerDurationDigits.rewriteWhileEditing("75", in: minutes), "59")
        XCTAssertEqual(TimerDurationDigits.rewriteWhileEditing("024", in: hours), "23", "the shift, then the range")
    }
}
