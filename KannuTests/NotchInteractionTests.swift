/*
 * Kannu (കണ്ണ്)
 * Copyright (C) 2024-2026 Kannu Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import XCTest

/// On a notched MacBook, hover may open the notch only from the hardware notch, and a click
/// meant for another app may never open it (docs/REGRESSIONS.md entry 18).
final class NotchInteractionTests: XCTestCase {
    /// A 14" MacBook Pro at default scaling: 1512 wide, menu-bar areas either side of a ~185 pt
    /// notch, 38 pt top inset.
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let left: CGFloat = 663.5, right: CGFloat = 663.5, top: CGFloat = 38

    private var notch: CGRect {
        NotchInteractionGeometry.physicalNotchRect(screenFrame: screen, leftAreaWidth: left, rightAreaWidth: right, topInset: top)!
    }

    func testTheRectIsTheNotchKannuDraws() {
        // getClosedNotchSize's width: screen minus the areas either side, plus 4.
        XCTAssertEqual(notch.width, 1512 - 663.5 - 663.5 + 4)
        XCTAssertEqual(notch.height, 38)
        XCTAssertEqual(notch.maxY, screen.maxY, "flush with the top edge")
        XCTAssertEqual(notch.midX, screen.midX, "centred, as the window is")
    }

    func testOnlyTheNotchItselfCounts() {
        let onNotch = CGPoint(x: screen.midX, y: screen.maxY - 10)
        XCTAssertTrue(NotchInteractionGeometry.isOnPhysicalNotch(onNotch, notch: notch))
        XCTAssertTrue(NotchInteractionGeometry.isOnPhysicalNotch(CGPoint(x: screen.midX, y: screen.maxY), notch: notch),
                      "the pointer pinned against the top edge is on the notch")
        // The +8 pt hover growth either side, and below.
        XCTAssertFalse(NotchInteractionGeometry.isOnPhysicalNotch(CGPoint(x: notch.maxX + 4, y: screen.maxY - 10), notch: notch))
        XCTAssertFalse(NotchInteractionGeometry.isOnPhysicalNotch(CGPoint(x: screen.midX, y: notch.minY - 4), notch: notch))
        // A music or agent wing, over the menu-bar items beside the notch.
        XCTAssertFalse(NotchInteractionGeometry.isOnPhysicalNotch(CGPoint(x: notch.minX - 60, y: screen.maxY - 10), notch: notch))
        // The agent band below the notch, over a window's tabs and toolbar.
        XCTAssertFalse(NotchInteractionGeometry.isOnPhysicalNotch(CGPoint(x: screen.midX, y: screen.maxY - 50), notch: notch))
    }

    func testAScreenWithoutANotchHasNone() {
        XCTAssertNil(NotchInteractionGeometry.physicalNotchRect(screenFrame: screen, leftAreaWidth: 0, rightAreaWidth: 0, topInset: 0))
    }

    func testASecondScreenIsMeasuredInItsOwnCoordinates() {
        let external = CGRect(x: 1512, y: 200, width: 1512, height: 982)
        let rect = NotchInteractionGeometry.physicalNotchRect(screenFrame: external, leftAreaWidth: left, rightAreaWidth: right, topInset: top)!
        XCTAssertEqual(rect.midX, external.midX)
        XCTAssertEqual(rect.maxY, external.maxY)
    }

    /// A global monitor cannot consume a click: one on leftMouseDown in the notch view let a click
    /// meant for a menu item or tab beside the notch land there *and* open the panel over it.
    func testNoGlobalMouseDownMonitorInTheNotchView() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Kannu/ContentView.swift"), encoding: .utf8)
        let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        XCTAssertFalse(code.contains("addGlobalMonitorForEvents(matching: [.leftMouseDown]"),
                       "a click in another app must never open the notch (docs/REGRESSIONS.md entry 18)")
        XCTAssertTrue(code.contains("addGlobalMonitorForEvents(matching: [.leftMouseUp]"),
                      "the open panel's click-elsewhere close should still be here")
    }
}
