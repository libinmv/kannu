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

import SwiftUI

struct TabButton: View {
    /// Hover bubble text, doubling as the accessibility label (docs/TOOLTIPS.md).
    let tooltip: String
    let icon: String
    let selected: Bool
    /// The caller's hover reaction (hover-to-switch). Routed through this button's own handler so
    /// the tab keeps a single hover source — a second `.onHover` at the call site fights this one.
    var onHover: ((Bool) -> Void)? = nil
    let onClick: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onClick) {
            Image(systemName: icon)
                .imageScale(.small)
                .frame(width: 26, height: 26)
                .background {
                    if isHovered && !selected {
                        Circle()
                            .fill(Color.white.opacity(0.1))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            isHovered = hovering
            onHover?(hovering)
        }
        // The tab row is at the top of the notch, so the bubble opens downwards.
        .hoverTooltip(tooltip, edge: .below, isHovering: isHovered)
        .accessibilityLabel(tooltip)
    }
}

#Preview {
    TabButton(tooltip: "Home", icon: "tray.fill", selected: true) {
        print("Tapped")
    }
}
