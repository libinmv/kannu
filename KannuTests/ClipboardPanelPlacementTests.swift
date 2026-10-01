//
//  ClipboardPanelPlacementTests.swift
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

/// Where the clipboard panel opens. The 2026-09-30 report: summoned over a fullscreen app the
/// panel was "running, but not visible" — a stale saved origin restored against the wrong
/// screen's frame, with a one-pixel overlap counting as on-screen.
final class ClipboardPanelPlacementTests: XCTestCase {
    private let size = CGSize(width: 320, height: 400)
    private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 944)          // notched laptop
    private let external = CGRect(x: 1512, y: 0, width: 2560, height: 1415)     // to its right

    func testASavedOriginFullyOnTheTargetScreenIsKept() {
        let saved = CGPoint(x: 596, y: 304)
        XCTAssertEqual(ClipboardPanelPlacement.origin(saved: saved, panelSize: size, visibleFrame: builtIn), saved)
    }

    func testASavedOriginFromAnotherDisplayRecentersOnTheTargetScreen() {
        // The reported case: position saved while on the built-in display, panel summoned over a
        // fullscreen app on the external one. The old code restored the built-in coordinates and
        // the panel opened on a screen the user was not looking at.
        let savedOnBuiltIn = CGPoint(x: 596, y: 304)
        let origin = ClipboardPanelPlacement.origin(saved: savedOnBuiltIn, panelSize: size, visibleFrame: external)
        XCTAssertEqual(origin, CGPoint(x: (external.midX - size.width / 2).rounded(),
                                       y: (external.midY - size.height / 2).rounded()))
        XCTAssertTrue(external.contains(CGRect(origin: origin, size: size)), "the recentred panel is entirely visible")
    }

    func testAOnePixelOverlapIsNotOnScreen() {
        // Old rule: `intersects` — a panel hanging 319 of its 320 points off the right edge
        // still "restored". New rule: at least 60 points visible per axis.
        let barely = CGPoint(x: builtIn.maxX - 1, y: 300)
        let origin = ClipboardPanelPlacement.origin(saved: barely, panelSize: size, visibleFrame: builtIn)
        XCTAssertNotEqual(origin, barely)
        XCTAssertEqual(origin.x, (builtIn.midX - size.width / 2).rounded())
    }

    func testExactlyTheMinimumVisibleStripStillCounts() {
        let edge = CGPoint(x: builtIn.maxX - ClipboardPanelPlacement.minimumVisible, y: 300)
        XCTAssertEqual(ClipboardPanelPlacement.origin(saved: edge, panelSize: size, visibleFrame: builtIn), edge)
    }

    func testNothingSavedCentersIncludingAtOriginZero() {
        // (0, 0) is a legitimate bottom-left origin, not a sentinel: with nothing saved the
        // panel centres, and with (0, 0) genuinely saved on a screen whose visible frame
        // contains it, it is kept.
        let centered = ClipboardPanelPlacement.origin(saved: nil, panelSize: size, visibleFrame: builtIn)
        XCTAssertEqual(centered, CGPoint(x: (builtIn.midX - size.width / 2).rounded(),
                                         y: (builtIn.midY - size.height / 2).rounded()))
        XCTAssertEqual(ClipboardPanelPlacement.origin(saved: .zero, panelSize: size, visibleFrame: builtIn), .zero)
    }

    func testTheTargetScreenIsTheOneUnderThePointer() {
        let frames = [builtIn, external]
        XCTAssertEqual(ClipboardPanelPlacement.screenIndex(under: CGPoint(x: 700, y: 500), screenFrames: frames), 0)
        XCTAssertEqual(ClipboardPanelPlacement.screenIndex(under: CGPoint(x: 2000, y: 500), screenFrames: frames), 1)
        XCTAssertNil(ClipboardPanelPlacement.screenIndex(under: CGPoint(x: -50, y: -50), screenFrames: frames),
                     "mid-reconfiguration the pointer can be on no screen; the caller falls back")
    }
}
