//
//  ClosedMusicWingLayoutTests.swift
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

/// The closed notch's music wing: the paired activity's badge sits beside the album art, never
/// over it, and the art never moves for it.
final class ClosedMusicWingLayoutTests: XCTestCase {
    typealias L = ClosedMusicWingLayout

    private func wing(slot: CGFloat = 20, height: CGFloat = 20, paired: Bool = true, inlinePeek: Bool = false) -> L {
        L(artSlotWidth: slot, contentHeight: height, hasPairedActivity: paired, inlineSneakPeekActive: inlinePeek)
    }

    func testWithoutAPairedActivityTheWingIsTheArtAlone() {
        let alone = wing(paired: false)
        XCTAssertFalse(alone.showsBadge)
        XCTAssertEqual(alone.width, 20)
        XCTAssertNil(alone.badgeRect)
    }

    func testAPairedActivityAddsTheBadgeAndItsGap() {
        XCTAssertEqual(wing().width, 20 + L.badgeSpacing + 13)
    }

    func testTheBadgeGrowsWithTheNotchFromAFloor() {
        XCTAssertEqual(wing(height: 20).badgeSize, 13)
        XCTAssertEqual(wing(height: 32).badgeSize, 13)
        XCTAssertEqual(wing(height: 38).badgeSize, 13.68, accuracy: 1e-9)
        XCTAssertEqual(wing(height: 50).badgeSize, 18, accuracy: 1e-9)
    }

    func testAnInlineSneakPeekHidesTheBadgeAndItsWidth() {
        let peek = wing(inlinePeek: true)
        XCTAssertFalse(peek.showsBadge, "the 460 pt sneak-peek window has no room for it")
        XCTAssertEqual(peek.width, 20)
        XCTAssertNil(peek.badgeRect)
    }

    func testTheArtNeverMovesAndTheBadgeNeverCoversIt() throws {
        for height: CGFloat in [0, 8, 13, 20, 26, 32, 38, 50] {
            for pull: CGFloat in [0, 2.5, 5, 10] {
                let slot = height + pull   // the pull-down gesture widens the slot
                let alone = wing(slot: slot, height: height, paired: false)
                let paired = wing(slot: slot, height: height)
                let label = "height \(height), pull \(pull)"
                XCTAssertEqual(paired.artRect, alone.artRect, "the art keeps its rect: \(label)")
                let badge = try XCTUnwrap(paired.badgeRect)
                // Edges, not CGRect.intersects: that is also true for rects that only touch.
                XCTAssertGreaterThanOrEqual(badge.minX - paired.artRect.maxX, L.badgeSpacing - 1e-9, label)
                XCTAssertEqual(badge.maxX, paired.width, accuracy: 1e-9, "the wing holds the badge: \(label)")
                XCTAssertEqual(badge.midY, height / 2, accuracy: 1e-9, "centred beside the art: \(label)")
            }
        }
    }

    func testTheDefaultNotch() throws {
        // A 32 pt closed notch at rest: content 20 pt, the art 20 pt square.
        let rest = wing(slot: 20, height: 20)
        XCTAssertEqual(rest.artRect, CGRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertEqual(try XCTUnwrap(rest.badgeRect), CGRect(x: 24, y: 3.5, width: 13, height: 13))
        XCTAssertEqual(rest.width, 37)
        XCTAssertEqual(wing(slot: 32, height: 32).width, 49, "hovering")
    }

    func testHostileInputsAreClamped() {
        let negative = wing(slot: -5, height: -5)
        XCTAssertEqual(negative.artSlotWidth, 0)
        XCTAssertEqual(negative.contentHeight, 0)
        XCTAssertEqual(negative.width, L.badgeSpacing + L.minimumBadgeSize)
    }
}
