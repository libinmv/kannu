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

/// The shared trigger for every colour picker: a swatch button that opens a popover whose
/// contents the caller supplies. Keeping the trigger here means the settings rows and the agent
/// palette look identical while their behaviour (free colours vs a closed palette) stays their own.
struct KannuColorPickerButton<Content: View>: View {
    let color: Color
    var swatchSize: CGFloat = 16
    var accessibilityLabel: String
    @ViewBuilder let content: () -> Content

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            KannuColorSwatch(color: color, size: swatchSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            content()
        }
    }
}
