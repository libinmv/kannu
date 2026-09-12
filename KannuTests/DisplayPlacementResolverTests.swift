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

/// Where Kannu goes, decided without an `NSScreen` — which is the point, because the Mac this was
/// written on has one display and the reported bug needs two.
final class DisplayPlacementResolverTests: XCTestCase {

    private let builtIn = ScreenFacts(id: 1, name: "Built-in Retina Display", isBuiltIn: true, hasNotch: true)
    private let studio = ScreenFacts(id: 2, name: "Studio Display", isBuiltIn: false)
    private let dell = ScreenFacts(id: 3, name: "DELL U2720Q", isBuiltIn: false)

    private func resolve(
        _ screens: [ScreenFacts],
        _ mode: DisplayPlacement,
        chosen: String? = nil,
        pointer: CGDirectDisplayID? = nil,
        main: CGDirectDisplayID? = nil
    ) -> [CGDirectDisplayID] {
        DisplayPlacementResolver.screensToShowOn(screens, mode: mode, chosenName: chosen, pointerOn: pointer, mainScreen: main)
    }

    // MARK: - The new default

    func testWithNothingPluggedInKannuIsOnTheBuiltInDisplay() {
        XCTAssertEqual(resolve([builtIn], .externalTakesOver), [1])
    }

    func testOneExternalTakesOverFromTheBuiltIn() {
        XCTAssertEqual(resolve([builtIn, studio], .externalTakesOver), [2])
        XCTAssertEqual(resolve([studio, builtIn], .externalTakesOver), [2], "Order of connection must not matter.")
    }

    /// The reported bug: a MacBook plus a monitor showed Kannu in the notch and nothing on the
    /// monitor. The monitor is now the only place it appears.
    func testTheBuiltInIsNotUsedWhileAnExternalIsConnected() {
        XCTAssertFalse(resolve([builtIn, studio], .externalTakesOver).contains(1))
    }

    func testUnpluggingTheExternalBringsKannuBack() {
        XCTAssertEqual(resolve([builtIn, studio], .externalTakesOver), [2])
        XCTAssertEqual(resolve([builtIn], .externalTakesOver), [1])
    }

    // MARK: - Two externals follow the pointer, and only then

    func testTwoExternalsFollowThePointer() {
        XCTAssertEqual(resolve([builtIn, studio, dell], .externalTakesOver, pointer: 3), [3])
        XCTAssertEqual(resolve([builtIn, studio, dell], .externalTakesOver, pointer: 2), [2])
    }

    /// The pointer being on the laptop screen is still where the user is looking.
    func testThePointerOnTheBuiltInCounts() {
        XCTAssertEqual(resolve([builtIn, studio, dell], .externalTakesOver, pointer: 1), [1])
    }

    func testAnUnknownPointerFallsBackToTheMainDisplay() {
        XCTAssertEqual(resolve([builtIn, studio, dell], .externalTakesOver, pointer: nil, main: 2), [2])
        XCTAssertEqual(resolve([builtIn, studio, dell], .externalTakesOver, pointer: 99, main: 3), [3])
    }

    /// The pointer monitor is the only part of this with a running cost, so it must be installed in
    /// exactly one case and torn down in every other.
    func testOnlyTwoOrMoreExternalsTrackThePointer() {
        XCTAssertFalse(DisplayPlacementResolver.needsPointerTracking([builtIn], mode: .externalTakesOver))
        XCTAssertFalse(DisplayPlacementResolver.needsPointerTracking([builtIn, studio], mode: .externalTakesOver))
        XCTAssertTrue(DisplayPlacementResolver.needsPointerTracking([builtIn, studio, dell], mode: .externalTakesOver))
        XCTAssertFalse(DisplayPlacementResolver.needsPointerTracking([builtIn, studio, dell], mode: .allDisplays))
        XCTAssertFalse(DisplayPlacementResolver.needsPointerTracking([builtIn, studio, dell], mode: .builtInOnly))
        XCTAssertFalse(DisplayPlacementResolver.needsPointerTracking([studio, dell], mode: .chooseDisplay))
    }

    // MARK: - The other modes

    func testAllDisplaysKeepsEveryScreenInOrder() {
        XCTAssertEqual(resolve([builtIn, studio, dell], .allDisplays), [1, 2, 3])
    }

    func testBuiltInOnlyIgnoresWhateverIsPluggedIn() {
        XCTAssertEqual(resolve([builtIn, studio, dell], .builtInOnly), [1])
    }

    /// Clamshell, or a Mac with no built-in display at all. Showing nothing would make Kannu vanish
    /// with no way to bring it back.
    func testBuiltInOnlyWithNoBuiltInFallsBackRatherThanDisappearing() {
        XCTAssertEqual(resolve([studio, dell], .builtInOnly, main: 3), [3])
        XCTAssertEqual(resolve([studio, dell], .builtInOnly), [2], "With no main given, the first screen.")
    }

    func testChooseDisplayUsesTheNamedScreen() {
        XCTAssertEqual(resolve([builtIn, studio, dell], .chooseDisplay, chosen: "DELL U2720Q"), [3])
    }

    func testAChosenDisplayThatIsGoneFallsBackToMain() {
        XCTAssertEqual(resolve([builtIn, studio], .chooseDisplay, chosen: "DELL U2720Q", main: 1), [1])
        XCTAssertEqual(resolve([builtIn, studio], .chooseDisplay, chosen: nil, main: 2), [2])
    }

    // MARK: - Identity

    /// Two identical monitors share a `localizedName`, which is why every override in the app used
    /// to collapse them into one. The resolver answers in ids.
    func testTwoIdenticallyNamedMonitorsStayTwoDisplays() {
        let first = ScreenFacts(id: 7, name: "DELL U2720Q", isBuiltIn: false)
        let second = ScreenFacts(id: 8, name: "DELL U2720Q", isBuiltIn: false)
        XCTAssertEqual(resolve([builtIn, first, second], .allDisplays), [1, 7, 8])
        XCTAssertEqual(resolve([builtIn, first, second], .externalTakesOver, pointer: 8), [8])
        // A name can only ever pick one of them; it must pick deterministically rather than both.
        XCTAssertEqual(resolve([builtIn, first, second], .chooseDisplay, chosen: "DELL U2720Q"), [7])
    }

    // MARK: - Nothing at all

    /// `NSScreen.screens` is empty in clamshell and while every display sleeps. Three crashes came
    /// from assuming otherwise.
    func testNoScreensResolvesToNothingRatherThanTrapping() {
        for mode in DisplayPlacement.allCases {
            XCTAssertEqual(resolve([], mode, chosen: "anything", pointer: 1, main: 1), [], "\(mode)")
        }
    }

    // MARK: - The setting itself

    func testEveryModeIsDescribedForSettings() {
        for mode in DisplayPlacement.allCases {
            XCTAssertFalse(mode.localizedName.isEmpty, "\(mode)")
            XCTAssertFalse(mode.description.isEmpty, "\(mode)")
        }
        XCTAssertEqual(DisplayPlacement.allCases.first, .externalTakesOver, "The default leads the picker.")
        XCTAssertEqual(DisplayPlacement(rawValue: "externalTakesOver"), .externalTakesOver)
    }
}
