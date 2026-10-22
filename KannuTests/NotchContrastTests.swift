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

/// Which notch fills and skins get dark text. Every case here is one a user can pick from the
/// fill presets or reach with the scrim slider.
final class NotchContrastTests: XCTestCase {
    typealias RGB = NotchContrast.RGB

    private func gray(_ byte: Double) -> RGB { RGB(red: byte / 255, green: byte / 255, blue: byte / 255) }

    func testContrastRatioMatchesWCAG() {
        XCTAssertEqual(NotchContrast.contrastRatio(.black, .white), 21, accuracy: 0.0001)
        XCTAssertEqual(NotchContrast.contrastRatio(.white, .white), 1, accuracy: 0.0001)
        // Order does not matter.
        XCTAssertEqual(NotchContrast.contrastRatio(.white, gray(0x77)),
                       NotchContrast.contrastRatio(gray(0x77), .white), accuracy: 0.0001)
        // #777777 on white is the textbook 4.48:1.
        XCTAssertEqual(NotchContrast.contrastRatio(.white, gray(0x77)), 4.48, accuracy: 0.01)
    }

    func testTheDefaultBlackNotchKeepsWhiteText() {
        XCTAssertFalse(NotchContrast.prefersDarkForeground(on: .black))
    }

    func testLightFillsGetDarkText() {
        XCTAssertTrue(NotchContrast.prefersDarkForeground(on: .white))
        // systemYellow, systemOrange and systemMint as they resolve in sRGB.
        XCTAssertTrue(NotchContrast.prefersDarkForeground(on: RGB(red: 1, green: 0.839, blue: 0)))
        XCTAssertTrue(NotchContrast.prefersDarkForeground(on: RGB(red: 1, green: 0.573, blue: 0.188)))
        XCTAssertTrue(NotchContrast.prefersDarkForeground(on: RGB(red: 0, green: 0.855, blue: 0.765)))
    }

    func testSaturatedMidTonesKeepWhiteText() {
        // Strict WCAG 2 max-contrast would turn all of these black; white is what users expect.
        XCTAssertFalse(NotchContrast.prefersDarkForeground(on: RGB(red: 0, green: 0.569, blue: 1)))        // systemBlue
        XCTAssertFalse(NotchContrast.prefersDarkForeground(on: RGB(red: 1, green: 0.259, blue: 0.271)))    // systemRed
        XCTAssertFalse(NotchContrast.prefersDarkForeground(on: RGB(red: 0.859, green: 0.204, blue: 0.949))) // systemPurple
        XCTAssertFalse(NotchContrast.prefersDarkForeground(on: RGB(red: 0, green: 0, blue: 0.5)))          // navy
        XCTAssertFalse(NotchContrast.prefersDarkForeground(on: gray(0x77)))
    }

    func testTheSwitchHappensWhereWhiteDropsBelowThreeToOne() {
        // #949494 is the lightest gray white text still clears 3:1 on; #959595 is the first that fails.
        XCTAssertGreaterThanOrEqual(NotchContrast.contrastRatio(.white, gray(0x94)), 3)
        XCTAssertFalse(NotchContrast.prefersDarkForeground(on: gray(0x94)))
        XCTAssertLessThan(NotchContrast.contrastRatio(.white, gray(0x95)), 3)
        XCTAssertTrue(NotchContrast.prefersDarkForeground(on: gray(0x95)))
    }

    func testTheScrimDarkensALightSkinBackToWhiteText() {
        XCTAssertTrue(NotchContrast.prefersDarkForeground(on: NotchContrast.underBlackScrim(.white, opacity: 0)))
        let scrimmed = NotchContrast.underBlackScrim(.white, opacity: 0.6)
        XCTAssertEqual(scrimmed, RGB(red: 0.4, green: 0.4, blue: 0.4))
        XCTAssertFalse(NotchContrast.prefersDarkForeground(on: scrimmed))
    }

    func testStateColoursAreShadedToStayReadableOnEveryLightNotch() {
        let darkestLight = gray(0x95)
        // The panel's neon green, yellow and red.
        for neon in [RGB(red: 0.12, green: 1, blue: 0.35), RGB(red: 1, green: 0.86, blue: 0), RGB(red: 1, green: 0.06, blue: 0.16)] {
            let shaded = NotchContrast.shadedForLightBackgrounds(neon)
            XCTAssertGreaterThanOrEqual(NotchContrast.contrastRatio(shaded, darkestLight), 3, "\(neon)")
            XCTAssertGreaterThanOrEqual(NotchContrast.contrastRatio(shaded, .white), 7, "\(neon)")
            // Shaded, not replaced: the channels keep their proportions, so the hue survives.
            let scale = shaded.red / neon.red
            XCTAssertEqual(shaded.green, neon.green * scale, accuracy: 0.0001)
            XCTAssertEqual(shaded.blue, neon.blue * scale, accuracy: 0.0001)
            XCTAssertLessThan(scale, 1)
        }
        // Already dark enough: unchanged.
        let navy = RGB(red: 0, green: 0, blue: 0.5)
        XCTAssertEqual(NotchContrast.shadedForLightBackgrounds(navy), navy)
    }

    func testScrimOpacityIsClamped() {
        XCTAssertEqual(NotchContrast.underBlackScrim(.white, opacity: 2), .black)
        XCTAssertEqual(NotchContrast.underBlackScrim(.white, opacity: -1), .white)
    }
}
