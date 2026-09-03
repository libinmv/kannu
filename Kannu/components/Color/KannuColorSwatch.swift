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

import SwiftUI

/// The one colour swatch in the app. Every grid, preview and picker trigger renders through this
/// so circle size, border and the selection checkmark can never drift between features again —
/// they previously did, across two hand-copied popover implementations.
struct KannuColorSwatch: View {
    let color: Color
    var size: CGFloat = 20
    var isSelected: Bool = false
    var isDisabled: Bool = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.5, weight: .bold))
                        // One luminance source of truth (Color+AccentColor), not a second formula.
                        .foregroundStyle(color.contrastingForeground)
                }
            }
            .opacity(isDisabled ? 0.3 : 1)
    }
}
