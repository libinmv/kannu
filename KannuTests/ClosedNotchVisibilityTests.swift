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

/// The notch went completely blank on a healthy app: unpainted *and* zero height, for a whole
/// session, on a notched MacBook. Both halves came from the same mistake — treating "Kannu has not
/// resolved its screen yet" as a fact about the display. These tests pin the distinction.
final class ClosedNotchVisibilityTests: XCTestCase {
    private let notchHeight: CGFloat = 32

    // MARK: - shouldHideClosedNotch

    /// The regression. `vm.screen` is nil until `adjustWindowPosition` assigns it, and that
    /// assignment sits below a lock guard and a no-screens return — so a launch while locked, or in
    /// clamshell, left it nil permanently. An unknown screen must never mean "hide".
    func testAnUnresolvedScreenDoesNotHideTheNotch() {
        XCTAssertFalse(
            ClosedNotchVisibility.shouldHideClosedNotch(
                detectionEnabled: true,
                screen: nil,
                fullscreenStatus: ["Built-in Retina Display": true]
            ),
            "A nil screen must not hide the notch — that is a bookkeeping gap, not a fullscreen app."
        )
    }

    func testAScreenTheDetectorHasNotReportedOnDoesNotHide() {
        XCTAssertFalse(
            ClosedNotchVisibility.shouldHideClosedNotch(
                detectionEnabled: true,
                screen: "Sidecar Display",
                fullscreenStatus: ["Built-in Retina Display": true]
            )
        )
    }

    func testAFullscreenAppOnThisScreenHides() {
        XCTAssertTrue(
            ClosedNotchVisibility.shouldHideClosedNotch(
                detectionEnabled: true,
                screen: "Built-in Retina Display",
                fullscreenStatus: ["Built-in Retina Display": true]
            )
        )
    }

    func testDetectionDisabledNeverHides() {
        XCTAssertFalse(
            ClosedNotchVisibility.shouldHideClosedNotch(
                detectionEnabled: false,
                screen: "Built-in Retina Display",
                fullscreenStatus: ["Built-in Retina Display": true]
            )
        )
    }

    func testAScreenReportedNotFullscreenDoesNotHide() {
        XCTAssertFalse(
            ClosedNotchVisibility.shouldHideClosedNotch(
                detectionEnabled: true,
                screen: "Built-in Retina Display",
                fullscreenStatus: ["Built-in Retina Display": false]
            )
        )
    }

    // MARK: - effectiveClosedNotchHeight

    /// The other half of the blank notch: a nil inset used to collapse the height to zero, which
    /// also removed the hover target, so the user could not point at the notch to bring it back.
    func testAnUnresolvedScreenKeepsItsHeight() {
        XCTAssertEqual(
            ClosedNotchVisibility.effectiveClosedNotchHeight(
                hideOnClosed: true,
                topSafeAreaInset: nil,
                closedHeight: notchHeight
            ),
            notchHeight,
            "An unresolvable screen must keep the notch's height, or there is nothing left to hover."
        )
    }

    /// The case the collapse exists for, and the one it must keep serving.
    func testANotchlessScreenWithAFullscreenAppCollapses() {
        XCTAssertEqual(
            ClosedNotchVisibility.effectiveClosedNotchHeight(
                hideOnClosed: true,
                topSafeAreaInset: 0,
                closedHeight: notchHeight
            ),
            0
        )
    }

    /// A notched Mac keeps the hardware cutout's height whatever the detector says — the physical
    /// notch does not go away because something is fullscreen.
    func testANotchedScreenKeepsItsHeightEvenWhenHiding() {
        XCTAssertEqual(
            ClosedNotchVisibility.effectiveClosedNotchHeight(
                hideOnClosed: true,
                topSafeAreaInset: 38,
                closedHeight: notchHeight
            ),
            notchHeight
        )
    }

    func testNotHidingAlwaysKeepsTheHeight() {
        for inset in [CGFloat(0), 38] {
            XCTAssertEqual(
                ClosedNotchVisibility.effectiveClosedNotchHeight(
                    hideOnClosed: false,
                    topSafeAreaInset: inset,
                    closedHeight: notchHeight
                ),
                notchHeight,
                "inset \(inset) must not collapse while nothing is fullscreen"
            )
        }
    }

    /// The exact composition that produced the bug, run end to end: no screen resolved, a fullscreen
    /// app reported on some other display, detection on. The notch must both show and be hoverable.
    func testTheBlankNotchCompositionIsFixed() {
        let hide = ClosedNotchVisibility.shouldHideClosedNotch(
            detectionEnabled: true,
            screen: nil,
            fullscreenStatus: ["Built-in Retina XDR Display": true]
        )
        XCTAssertFalse(hide)
        XCTAssertEqual(
            ClosedNotchVisibility.effectiveClosedNotchHeight(
                hideOnClosed: hide,
                topSafeAreaInset: nil,
                closedHeight: notchHeight
            ),
            notchHeight
        )
    }
}
