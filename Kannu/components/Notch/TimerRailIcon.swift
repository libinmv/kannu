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

/// One icon in the timer tab's task rail (search, filter, Refresh, Time to log): the session name
/// field's look, smaller — a 21 pt square with a dim fill and a 10 pt glyph, brighter while what
/// it opens is open. Only the look: each caller wraps it in its own button or menu.
struct TimerRailIcon: View {
    private typealias M = TimerComposerMetrics

    let systemName: String
    var isActive = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: M.railGlyphSize, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.85))
            .frame(width: M.railButtonSize, height: M.railButtonSize)
            .background(RailIconBackground(isActive: isActive))
            .contentShape(Rectangle())
    }
}

/// The rail icon's square, for a control that draws its own glyph (the filter menu).
struct RailIconBackground: View {
    var isActive = false

    var body: some View {
        RoundedRectangle(cornerRadius: TimerComposerMetrics.railCornerRadius, style: .continuous)
            .fill(Color.white.opacity(isActive ? 0.16 : 0.08))
    }
}
