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

    // MARK: - A notch stranded off the current space

    /// The state measured on 2026-09-30: ordered in, opaque, but no longer on the space the user is
    /// in, because macOS reset every all-spaces window across a sleep or lock. That — and only
    /// that — is repaired. Since 2026-10-22 this decision serves the clipboard panel, which belongs
    /// on the managed spaces; the notch uses `notchSpaceRepair` below.
    func testOnlyAStrandedNotchIsPutBack() {
        XCTAssertTrue(ClosedNotchVisibility.shouldRejoinSpaces(
            isOnActiveSpace: false, isOrderedIn: true, hiddenForLock: false, screenLocked: false),
            "ordered in but off the active space is exactly the stranded notch")
        XCTAssertFalse(ClosedNotchVisibility.shouldRejoinSpaces(
            isOnActiveSpace: true, isOrderedIn: true, hiddenForLock: false, screenLocked: false),
            "a notch already where it belongs costs nothing")
        XCTAssertFalse(ClosedNotchVisibility.shouldRejoinSpaces(
            isOnActiveSpace: false, isOrderedIn: false, hiddenForLock: false, screenLocked: false),
            "a window that is not ordered in has nothing to rejoin")
        XCTAssertFalse(ClosedNotchVisibility.shouldRejoinSpaces(
            isOnActiveSpace: false, isOrderedIn: true, hiddenForLock: true, screenLocked: false),
            "hidden for the lock screen is off every space on purpose")
        XCTAssertFalse(ClosedNotchVisibility.shouldRejoinSpaces(
            isOnActiveSpace: false, isOrderedIn: true, hiddenForLock: false, screenLocked: true),
            "never put the notch back over the lock screen")
    }

    // MARK: - The notch lives only in the notch space

    private static let notch: UInt64 = 745

    private func repair(_ memberships: Set<UInt64>, ordered: Bool = true, onScreen: Bool = true,
                        unseen: Bool = false, hidden: Bool = false,
                        locked: Bool = false) -> ClosedNotchVisibility.NotchSpaceRepair {
        ClosedNotchVisibility.notchSpaceRepair(memberships: memberships, notchSpaceID: Self.notch,
                                               isOrderedIn: ordered, isOnScreen: onScreen,
                                               notchSpaceUnseen: unseen,
                                               hiddenForLock: hidden, screenLocked: locked)
    }

    /// The live state on 2026-10-22: the notch in all nine desktop and fullscreen spaces next to
    /// the notch space, one of them (754) a fullscreen space macOS created and added it to on its
    /// own. Every space but the notch space is left.
    func testTheMeasuredStateLeavesEveryOtherSpace() {
        let live: Set<UInt64> = [3, 39, 42, 46, 67, 218, 402, 519, 754, Self.notch]
        XCTAssertEqual(repair(live), .leaveOtherSpaces(live.subtracting([Self.notch])))
    }

    func testATileSubSpaceIsLeftToo() {
        XCTAssertEqual(repair([Self.notch, 520]), .leaveOtherSpaces([520]),
                       "520 is a tile sub-space of a fullscreen space, missing from the managed list but still a copy of the notch")
    }

    func testOnlyInTheNotchSpaceIsHealthy() {
        XCTAssertEqual(repair([Self.notch]), .none,
                       "AppKit calls this window off the active space; the old repair moved it back onto every space at the first switch")
    }

    func testOutsideTheNotchSpaceJoinsItFirst() {
        XCTAssertEqual(repair([3, 519]), .joinNotchSpace, "reset onto desktop spaces: join first, strip only once joined")
        XCTAssertEqual(repair([]), .joinNotchSpace, "in no space at all")
        XCTAssertEqual(repair([3], onScreen: false), .joinNotchSpace, "joining comes before any fallback")
    }

    func testANotchTheNotchSpaceDoesNotShowGoesBackOnTheManagedSpaces() {
        XCTAssertEqual(repair([Self.notch], onScreen: false), .fallBackToManagedSpaces,
                       "seen beats still: a hidden notch space must not leave the notch invisible everywhere")
    }

    /// Right after a fallback the window is in the notch space and every managed space, and on
    /// screen only through the managed copies. Stripping them again would hide it, then fall back,
    /// at every check. While the window is marked, the copies stay.
    func testAFallbackIsNotUndoneByTheNextCheck() {
        let afterFallback: Set<UInt64> = [Self.notch, 3, 39, 42, 46, 67, 218, 402, 519, 754]
        XCTAssertEqual(repair(afterFallback, unseen: true), .none)
        XCTAssertEqual(repair(afterFallback, unseen: false), .leaveOtherSpaces(afterFallback.subtracting([Self.notch])),
                       "once a wake, unlock or reposition clears the mark, the strip is tried again")
        XCTAssertEqual(repair([3, 519], unseen: true), .joinNotchSpace, "the mark never stops a join")
    }

    func testAWindowThatShouldNotBeOnScreenIsLeftAlone() {
        XCTAssertEqual(repair([3, 519], ordered: false), .none)
        XCTAssertEqual(repair([3, 519], hidden: true), .none, "hidden for the lock screen on purpose")
        XCTAssertEqual(repair([Self.notch], onScreen: false, locked: true), .none, "never over the lock screen")
    }
}
