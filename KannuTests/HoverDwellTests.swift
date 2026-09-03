//
//  HoverDwellTests.swift
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

/// The hidden-edge poll's dwell gate. The poll itself needs a display Kannu hides on, which the
/// logic target cannot provide, so the one piece of logic in it is pinned here.
final class HoverDwellTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testUnsatisfiedBeforeEntry() {
        XCTAssertFalse(HoverDwell().isSatisfied(at: t0, minimum: 1))
    }

    func testEntryTimeIsKeptAcrossTicks() {
        var dwell = HoverDwell()
        dwell.noteInside(at: t0)
        dwell.noteInside(at: t0.addingTimeInterval(0.5))
        XCTAssertFalse(dwell.isSatisfied(at: t0.addingTimeInterval(0.95), minimum: 1))
        XCTAssertTrue(dwell.isSatisfied(at: t0.addingTimeInterval(1.0), minimum: 1))
    }

    func testLeavingResetsTheClock() {
        var dwell = HoverDwell()
        dwell.noteInside(at: t0)
        dwell.noteOutside()
        dwell.noteInside(at: t0.addingTimeInterval(0.9))
        XCTAssertFalse(dwell.isSatisfied(at: t0.addingTimeInterval(1.0), minimum: 1))
    }

    func testZeroMinimumIsSatisfiedOnFirstTick() {
        var dwell = HoverDwell()
        dwell.noteInside(at: t0)
        XCTAssertTrue(dwell.isSatisfied(at: t0, minimum: 0), "dwell 0 must reproduce the old immediate slide-in")
    }
}
