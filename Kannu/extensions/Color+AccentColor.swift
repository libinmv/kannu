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

    var perceivedBrightness: CGFloat {
        let nsColor = NSColor(self)
        guard let rgbColor = nsColor.usingColorSpace(.sRGB) else {
            return 0
        }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        rgbColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    }

    var isPerceivedLight: Bool {
        perceivedBrightness >= 0.64
    }

    var contrastingForeground: Color {
        isPerceivedLight ? .black : .white
    }

    var contrastingForegroundSecondary: Color {
        contrastingForeground.opacity(0.7)
    }
}
#endif
