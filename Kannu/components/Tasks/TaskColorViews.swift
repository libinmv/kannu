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

// How a `TaskColor` looks. The model (`TaskColor.swift`) is pure Foundation for the logic tests;
// everything that draws one lives here, so the notch rows, the timer's Tasks page and Brain cannot
// drift apart. No help-tag tooltips in this file: these views also sit in the notch, where they
// never render (docs/TOOLTIPS.md) — the swatches carry accessibility labels instead.

extension TaskColor {
    /// The tint over the glass; nil for `.glass`, the plain grey glass with no tint.
    var tint: Color? {
        switch self {
        case .glass: return nil
        case .white: return .white
        case .orange: return .orange
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .teal: return .teal
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        }
    }

    /// The colour a picker swatch fills with: the tint, or a translucent grey for glass.
    var swatch: Color {
        tint ?? Color.gray.opacity(0.35)
    }
}

private enum TaskColorMetrics {
    /// The tint laid over the white base: enough to read as colour, still glass.
    static let tintFill: Double = 0.2
    /// The 1 pt edge that keeps a tinted row distinct from its neighbours.
    static let tintStroke: Double = 0.45
    static let strokeWidth: CGFloat = 1
    static let dotSize: CGFloat = 10
    static let swatchSize: CGFloat = 14
    static let paletteSwatchSize: CGFloat = 20
    static let palettePadding: CGFloat = 12
}

/// A task row's background. `.glass` is exactly the fill the rows always had, `Color.white` at
/// `base` in a continuous rounded rectangle; a colour adds a translucent tint and a thin tinted
/// edge over that same base, so every preset keeps the glass finish over the dark notch.
struct TaskGlassBackground: View {
    let color: TaskColor
    var cornerRadius: CGFloat = 10
    var base: Double = 0.05

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(Color.white.opacity(base))
            if let tint = color.tint {
                shape.fill(tint.opacity(TaskColorMetrics.tintFill))
                shape.strokeBorder(tint.opacity(TaskColorMetrics.tintStroke), lineWidth: TaskColorMetrics.strokeWidth)
            }
        }
    }
}

/// A task's colour as a small dot before its title. Glass draws nothing — the plain look rows had
/// before colours — but keeps the frame, so the column still lines up. Decorative: the first tag it
/// comes from is already in the row's text.
struct TaskColorDot: View {
    let color: TaskColor

    var body: some View {
        Group {
            if let tint = color.tint {
                Circle()
                    .fill(tint)
                    .overlay(Circle().strokeBorder(.quaternary, lineWidth: TaskColorMetrics.strokeWidth))
            } else {
                Color.clear
            }
        }
        .frame(width: TaskColorMetrics.dotSize, height: TaskColorMetrics.dotSize)
        .accessibilityHidden(true)
    }
}

/// A swatch button that opens the presets. Picking one sets `selection` and closes the popover.
struct TaskColorPickerButton: View {
    @Binding var selection: TaskColor
    var swatchSize: CGFloat = TaskColorMetrics.swatchSize
    /// What VoiceOver reads, when the swatch needs to say what it colours (one of several tags);
    /// nil reads "Colour: <colour>".
    var accessibilityLabel: String?

    var body: some View {
        KannuColorPickerButton(
            color: selection.swatch,
            swatchSize: swatchSize,
            accessibilityLabel: accessibilityLabel ?? String(localized: "Colour: \(selection.localizedName)")
        ) {
            TaskColorPalette(selection: $selection)
        }
    }
}

/// The presets, glass first, through the shared swatch grid.
private struct TaskColorPalette: View {
    @Binding var selection: TaskColor
    @Environment(\.dismiss) private var dismiss

    private var items: [KannuColorSwatchGrid.Item] {
        TaskColor.allCases.map { option in
            KannuColorSwatchGrid.Item(id: option.rawValue, color: option.swatch, accessibilityLabel: option.localizedName)
        }
    }

    var body: some View {
        KannuColorSwatchGrid(
            items: items,
            selectedID: selection.rawValue,
            columns: 5,
            swatchSize: TaskColorMetrics.paletteSwatchSize
        ) { item in
            guard let picked = TaskColor(rawValue: item.id) else { return }
            selection = picked
            dismiss()
        }
        .padding(TaskColorMetrics.palettePadding)
    }
}
