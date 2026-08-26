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

    /// Standard rendering: the closed-notch dots, legend rows, and swatches.
    var color: Color {
        switch self {
        case .green: return .green
        case .mint: return .mint
        case .teal: return .teal
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        }
    }

    /// Expanded-panel glow variant. The three defaults keep the hand-tuned neon values the
    /// panel has always used, so the default look is byte-identical; the rest are saturated
    /// enough to carry the glow shadows on the dark panel background.
    var neonColor: Color {
        switch self {
        case .green: return Color(red: 0.12, green: 1.0, blue: 0.35)
        case .yellow: return Color(red: 1.0, green: 0.86, blue: 0.0)
        case .red: return Color(red: 1.0, green: 0.06, blue: 0.16)
        case .mint: return Color(red: 0.2, green: 1.0, blue: 0.8)
        case .teal: return Color(red: 0.0, green: 0.9, blue: 1.0)
        case .blue: return Color(red: 0.2, green: 0.55, blue: 1.0)
        case .indigo: return Color(red: 0.45, green: 0.45, blue: 1.0)
        case .purple: return Color(red: 0.75, green: 0.35, blue: 1.0)
        case .pink: return Color(red: 1.0, green: 0.3, blue: 0.7)
        case .orange: return Color(red: 1.0, green: 0.58, blue: 0.1)
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
