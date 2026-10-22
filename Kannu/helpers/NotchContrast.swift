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

import Foundation

/// Decides whether the notch's text should be light or dark for the background behind it — the
/// fill colour, or a skin's average colour under its scrim.
///
/// Luminance and contrast are the WCAG 2.x definitions (sRGB linearised, then
/// `0.2126 R + 0.7152 G + 0.0722 B`; ratio `(L1 + 0.05) / (L2 + 0.05)`). The choice is *not*
/// "whichever contrasts more": that WCAG 2 rule puts black text on system blue, red and purple,
/// where Apple and every reader expect white — the known flaw APCA exists to fix. Instead the
/// notch keeps its native white for as long as white clears WCAG's 3:1 minimum (the large-text
/// and UI-component threshold, SC 1.4.3 / 1.4.11) and only then switches to black — the same
/// prefer-light-until-it-fails approach Android's Palette uses for its title text.
///
/// Free of SwiftUI/AppKit types so `NotchContrastTests` can pin the threshold.
enum NotchContrast {

    /// A colour in gamma-encoded sRGB, each channel 0...1.
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        static let black = RGB(red: 0, green: 0, blue: 0)
        static let white = RGB(red: 1, green: 1, blue: 1)
    }

    /// White text stays until its contrast against the background drops below this.
    static let minimumLightForegroundContrast = 3.0

    /// WCAG 2.x relative luminance, 0 (black) ... 1 (white).
    static func relativeLuminance(_ color: RGB) -> Double {
        0.2126 * linearized(color.red) + 0.7152 * linearized(color.green) + 0.0722 * linearized(color.blue)
    }

    /// WCAG 2.x contrast ratio, 1 ... 21, independent of argument order.
    static func contrastRatio(_ first: RGB, _ second: RGB) -> Double {
        let a = relativeLuminance(first)
        let b = relativeLuminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// True when the background is too light for white text, so the notch should draw dark.
    static func prefersDarkForeground(on background: RGB) -> Bool {
        contrastRatio(.white, background) < minimumLightForegroundContrast
    }

    /// The darkest background that still gets dark text: white's contrast against it is exactly
    /// `minimumLightForegroundContrast`. Luminance 0.3, about #959595.
    static var darkestLightBackgroundLuminance: Double { 1.05 / minimumLightForegroundContrast - 0.05 }

    /// `color` scaled toward black just enough to reach `ratio` against every background that gets
    /// dark text — for coloured text, such as an agent's state, on a light notch. The hue stays; a
    /// colour already dark enough is returned unchanged.
    static func shadedForLightBackgrounds(_ color: RGB, ratio: Double = minimumLightForegroundContrast) -> RGB {
        let maximumLuminance = (darkestLightBackgroundLuminance + 0.05) / ratio - 0.05
        guard relativeLuminance(color) > maximumLuminance else { return color }
        var keep = 0.0, tooLight = 1.0
        for _ in 0..<32 {
            let mid = (keep + tooLight) / 2
            if relativeLuminance(underBlackScrim(color, opacity: 1 - mid)) > maximumLuminance {
                tooLight = mid
            } else {
                keep = mid
            }
        }
        return underBlackScrim(color, opacity: 1 - keep)
    }

    /// The colour a black overlay at `opacity` leaves behind — the skin scrim, composited
    /// source-over the way SwiftUI draws it.
    static func underBlackScrim(_ color: RGB, opacity: Double) -> RGB {
        let keep = 1 - min(max(opacity, 0), 1)
        return RGB(red: color.red * keep, green: color.green * keep, blue: color.blue * keep)
    }

    private static func linearized(_ channel: Double) -> Double {
        let c = min(max(channel, 0), 1)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}
