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

import Defaults
import SwiftUI

/// The curated palette the three traffic-light state colors are chosen from. Deliberately a
/// small closed set rather than a free color picker: the Settings UI blocks a swatch that is
/// already assigned to another state, so two states can never share a color — which also makes
/// the lights distinguishable for red-green colorblind users who move away from the defaults.
/// No white or gray: the expanded panel derives glow shadows from the color, and the dim state
/// is a 20% wash of the same hue, both of which need saturation to read.
enum AgentTrafficLightPaletteColor: String, CaseIterable, Defaults.Serializable, Identifiable {
    case green
    case mint
    case teal
    case blue
    case indigo
    case purple
    case pink
    case red
    case orange
    case yellow

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .green: return String(localized: "Green")
        case .mint: return String(localized: "Mint")
        case .teal: return String(localized: "Teal")
        case .blue: return String(localized: "Blue")
        case .indigo: return String(localized: "Indigo")
        case .purple: return String(localized: "Purple")
        case .pink: return String(localized: "Pink")
        case .red: return String(localized: "Red")
        case .orange: return String(localized: "Orange")
        case .yellow: return String(localized: "Yellow")
        }
    }

    /// Standard rendering: the closed-notch dots, legend rows, and swatches. Hand-picked
    /// Tailwind-derived values (mostly the 400/500 shades), chosen per hue for pop on the
    /// dark notch and for mutual distinctness at 10pt dot size.
    var color: Color {
        switch self {
        case .green: return Color(red: 0.133, green: 0.773, blue: 0.369)   // #22C55E
        case .mint: return Color(red: 0.369, green: 0.918, blue: 0.831)    // #5EEAD4
        case .teal: return Color(red: 0.024, green: 0.714, blue: 0.831)    // #06B6D4
        case .blue: return Color(red: 0.231, green: 0.510, blue: 0.965)    // #3B82F6
        case .indigo: return Color(red: 0.506, green: 0.549, blue: 0.973)  // #818CF8
        case .purple: return Color(red: 0.659, green: 0.333, blue: 0.969)  // #A855F7
        case .pink: return Color(red: 0.925, green: 0.282, blue: 0.600)    // #EC4899
        case .red: return Color(red: 0.937, green: 0.267, blue: 0.267)     // #EF4444
        case .orange: return Color(red: 0.976, green: 0.451, blue: 0.086)  // #F97316
        case .yellow: return Color(red: 0.980, green: 0.800, blue: 0.082)  // #FACC15
        }
    }

    /// Expanded-panel glow variant. The three defaults keep the hand-tuned neon values the
    /// panel has always used, so the default look is byte-identical; the rest are saturated
    /// enough to carry the glow shadows on the dark panel background.
    var neonColor: Color {
        switch self {
        // The three defaults keep the panel's original hand-tuned values.
        case .green: return Color(red: 0.12, green: 1.0, blue: 0.35)
        case .yellow: return Color(red: 1.0, green: 0.86, blue: 0.0)
        case .red: return Color(red: 1.0, green: 0.06, blue: 0.16)
        case .mint: return Color(red: 0.486, green: 1.0, blue: 0.898)      // #7CFFE5
        case .teal: return Color(red: 0.0, green: 0.851, blue: 1.0)        // #00D9FF
        case .blue: return Color(red: 0.278, green: 0.584, blue: 1.0)      // #4795FF
        case .indigo: return Color(red: 0.545, green: 0.545, blue: 1.0)    // #8B8BFF
        case .purple: return Color(red: 0.761, green: 0.373, blue: 1.0)    // #C25FFF
        case .pink: return Color(red: 1.0, green: 0.341, blue: 0.682)      // #FF57AE
        case .orange: return Color(red: 1.0, green: 0.549, blue: 0.102)    // #FF8C1A
        }
    }
}

extension AgentTrafficLightState {
    /// The palette slot this state's light draws from, or nil when no light is lit.
    /// Pure function of the caller's observed choices so SwiftUI invalidation flows from the
    /// caller's `@Default` wrappers — no hidden `Defaults[...]` reads inside a `body`.
    func litPalette(
        active: AgentTrafficLightPaletteColor,
        awaiting: AgentTrafficLightPaletteColor,
        stopped: AgentTrafficLightPaletteColor
    ) -> AgentTrafficLightPaletteColor? {
        if showsRedTrafficLight { return stopped }
        if showsYellowTrafficLight { return awaiting }
        if showsGreenTrafficLight { return active }
        return nil
    }
}
