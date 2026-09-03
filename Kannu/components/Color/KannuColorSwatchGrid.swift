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

/// A grid of selectable colour swatches, shared by the settings presets and the agent traffic
/// light palette. Disabled entries are first-class: the palette needs "this colour is already
/// used by another state" to be unpickable, and expressing it here keeps that rule out of the
/// call sites.
struct KannuColorSwatchGrid: View {
    struct Item: Identifiable {
        let id: String
        let color: Color
        /// Non-nil marks the swatch unpickable and supplies the tooltip explaining why.
        var disabledReason: String?
        var accessibilityLabel: String
    }

    let items: [Item]
    let selectedID: String?
    var columns: Int = 5
    var swatchSize: CGFloat = 20
    let onSelect: (Item) -> Void

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(swatchSize + 2), spacing: 6), count: columns),
            spacing: 8
        ) {
            ForEach(items) { item in
                Button {
                    onSelect(item)
                } label: {
                    KannuColorSwatch(
                        color: item.color,
                        size: swatchSize,
                        isSelected: item.id == selectedID,
                        isDisabled: item.disabledReason != nil
                    )
                }
                .buttonStyle(.plain)
                .disabled(item.disabledReason != nil)
                .help(item.disabledReason ?? item.accessibilityLabel)
                .accessibilityLabel(Text(item.accessibilityLabel))
            }
        }
    }
}
