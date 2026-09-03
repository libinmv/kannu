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

/// Geometry and hex conversions behind the shared colour picker.
///
/// Deliberately free of SwiftUI/AppKit types so `ColorSpectrumMathTests` can pin it: the drag
/// maths and hex parsing are exactly where a picker breaks silently (a knob that drifts at the
/// edges, a pasted `#FFF` that does nothing). Colour-space conversion itself is left to
/// `NSColor`, which already does it correctly — this file adds no second implementation.
enum ColorSpectrumMath {

    // MARK: - Saturation / brightness plane
    // Saturation runs left→right, brightness runs bottom→top (the standard arrangement).

    static func saturationBrightness(
        atX x: Double, y: Double, width: Double, height: Double
    ) -> (saturation: Double, brightness: Double) {
        guard width > 0, height > 0 else { return (0, 0) }
        return (clamp01(x / width), clamp01(1 - y / height))
    }

    static func point(
        saturation: Double, brightness: Double, width: Double, height: Double
    ) -> (x: Double, y: Double) {
        (clamp01(saturation) * width, (1 - clamp01(brightness)) * height)
    }

    // MARK: - Hue slider

    static func hue(atX x: Double, width: Double) -> Double {
        guard width > 0 else { return 0 }
        return clamp01(x / width)
    }

    static func x(forHue hue: Double, width: Double) -> Double {
        clamp01(hue) * width
    }

    // MARK: - Hex

    static func hexString(red: Double, green: Double, blue: Double) -> String {
        let r = Int((clamp01(red) * 255).rounded())
        let g = Int((clamp01(green) * 255).rounded())
        let b = Int((clamp01(blue) * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Accepts `#RRGGBB`, `RRGGBB`, `#RGB` and `RGB`, any case, with surrounding whitespace.
    /// Returns nil for anything else so the caller can revert rather than apply garbage.
    static func rgb(fromHex hex: String) -> (red: Double, green: Double, blue: Double)? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.allSatisfy({ $0.isHexDigit }) else { return nil }

        let digits: [String]
        switch value.count {
        case 6:
            digits = stride(from: 0, to: 6, by: 2).map { index -> String in
                let start = value.index(value.startIndex, offsetBy: index)
                let end = value.index(start, offsetBy: 2)
                return String(value[start..<end])
            }
        case 3:
            // #RGB shorthand: each digit doubles, so F becomes FF.
            digits = value.map { String(repeating: $0, count: 2) }
        default:
            return nil
        }

        let components = digits.compactMap { UInt8($0, radix: 16) }
        guard components.count == 3 else { return nil }
        return (Double(components[0]) / 255, Double(components[1]) / 255, Double(components[2]) / 255)
    }

    private static func clamp01(_ value: Double) -> Double { min(max(value, 0), 1) }
}
