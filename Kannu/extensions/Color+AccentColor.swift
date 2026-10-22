/*
 * Kannu (കണ്ണ്)
 * Copyright (C) 2024-2026 Kannu Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Kannu (കണ്ണ്)
 * See NOTICE for details.
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

#if os(macOS)
import SwiftUI
import Defaults

extension Color {
    /// Returns the accent color configured in settings, falling back to the system accent color.
    static var effectiveAccent: Color {
        Defaults[.accentColor]
    }
    
    /// Returns a subtle background variant of the accent color.
    static var effectiveAccentBackground: Color {
        Defaults[.accentColor].opacity(0.25)
    }

    /// This colour in gamma-encoded sRGB, or nil when it has no RGB form (a pattern colour).
    var srgbComponents: NotchContrast.RGB? {
        guard let rgbColor = NSColor(self).usingColorSpace(.sRGB) else {
            return nil
        }
        return NotchContrast.RGB(red: Double(rgbColor.redComponent),
                                 green: Double(rgbColor.greenComponent),
                                 blue: Double(rgbColor.blueComponent))
    }

    /// Too light for white text on top — the rule in `NotchContrast`.
    var isPerceivedLight: Bool {
        srgbComponents.map(NotchContrast.prefersDarkForeground(on:)) ?? false
    }

    /// This colour shaded just enough to read as text on any light notch
    /// (`NotchContrast.shadedForLightBackgrounds`); unchanged when it has no RGB form.
    var shadedForLightNotch: Color {
        guard let components = srgbComponents else { return self }
        let shaded = NotchContrast.shadedForLightBackgrounds(components)
        return Color(.sRGB, red: shaded.red, green: shaded.green, blue: shaded.blue)
    }

    var contrastingForeground: Color {
        isPerceivedLight ? .black : .white
    }

    var contrastingForegroundSecondary: Color {
        contrastingForeground.opacity(0.7)
    }
}
#endif
