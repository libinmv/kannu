//
//  FullscreenFallbackVerdictTests.swift
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

/// The AX-denied fullscreen verdict. The one regression it must never reintroduce: a *maximized*
/// window (which keeps the menu bar) hiding the notch. The one gap it must close: a re-signed
/// install losing the Accessibility grant and fullscreen hiding going silently dead.
final class FullscreenFallbackVerdictTests: XCTestCase {
    /// A notched built-in display in AppKit coordinates: full frame, with the menu-bar band as
    /// the top 38 pt (the safe area ends below it) and the menu bar window hugging the top edge.
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private var safeArea: CGRect { CGRect(x: 0, y: 0, width: 1512, height: 982 - 38) }
    private let menuBarLayer = 24

    private func menuBar(width: CGFloat = 1512, atTopOf screen: CGRect, layer: Int = 24) -> FullscreenFallbackVerdict.WindowRecord {
        FullscreenFallbackVerdict.WindowRecord(
            layer: layer,
            frame: CGRect(x: screen.minX, y: screen.maxY - 38, width: width, height: 38)
        )
    }

    // MARK: - Menu-bar probe

    func testAWideTopHuggingWindowOnTheMenuBarLayerCounts() {
        XCTAssertTrue(FullscreenFallbackVerdict.menuBarIsVisible(
            onScreenWithFrame: screen, windows: [menuBar(atTopOf: screen)], menuBarLayer: menuBarLayer))
    }

    func testAStatusItemSpillWindowDoesNotCount() {
        // Shares the layer, never the width.
        XCTAssertFalse(FullscreenFallbackVerdict.menuBarIsVisible(
            onScreenWithFrame: screen, windows: [menuBar(width: 300, atTopOf: screen)], menuBarLayer: menuBarLayer))
    }

    func testAnOrdinaryWindowOnAnotherLayerDoesNotCount() {
        XCTAssertFalse(FullscreenFallbackVerdict.menuBarIsVisible(
            onScreenWithFrame: screen, windows: [menuBar(atTopOf: screen, layer: 0)], menuBarLayer: menuBarLayer))
    }

    func testAnotherScreensMenuBarDoesNotCount() {
        let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        XCTAssertFalse(FullscreenFallbackVerdict.menuBarIsVisible(
            onScreenWithFrame: screen, windows: [menuBar(width: 2560, atTopOf: external)], menuBarLayer: menuBarLayer),
            "the external display's menu bar must not vouch for the built-in screen")
        XCTAssertTrue(FullscreenFallbackVerdict.menuBarIsVisible(
            onScreenWithFrame: external, windows: [menuBar(width: 2560, atTopOf: external)], menuBarLayer: menuBarLayer))
    }

    // MARK: - The verdict

    func testAMaximizedWindowWithTheMenuBarUpNeverReadsAsFullscreen() {
        // The documented regression: maximized matches the safe area on a notched Mac. The menu
        // bar is still up, so the verdict must stay false.
        XCTAssertFalse(FullscreenFallbackVerdict.isLikelyFullscreen(
            windowFrame: safeArea, screenFrame: screen, menuBarVisible: true))
    }

    func testASafeAreaWindowWithTheMenuBarGoneReadsAsFullscreen() {
        // Native fullscreen video letterboxed below the notch: the frame matches the safe area
        // and the menu bar is hidden — the Prime case a dead AX grant used to miss.
        XCTAssertTrue(FullscreenFallbackVerdict.isLikelyFullscreen(
            windowFrame: safeArea, screenFrame: screen, menuBarVisible: false))
    }

    func testAWindowCoveringTheWholeScreenReadsAsFullscreenEitherWay() {
        // Nothing maximized can cover the menu-bar band.
        XCTAssertTrue(FullscreenFallbackVerdict.isLikelyFullscreen(
            windowFrame: screen, screenFrame: screen, menuBarVisible: true))
        XCTAssertTrue(FullscreenFallbackVerdict.isLikelyFullscreen(
            windowFrame: screen.insetBy(dx: 1, dy: 1), screenFrame: screen, menuBarVisible: true))
    }
}
