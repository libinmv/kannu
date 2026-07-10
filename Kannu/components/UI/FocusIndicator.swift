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

struct FocusIndicator: View {
    @ObservedObject var manager = DoNotDisturbManager.shared

    var body: some View {
        Capsule()
            .fill(Color.black)
            .overlay {
                focusIcon
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 24, height: 24)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }

    private var focusMode: FocusModeType {
        FocusModeType.resolve(
            identifier: manager.currentFocusModeIdentifier,
            name: manager.currentFocusModeName
        )
    }

    private var focusIcon: Image {
        focusMode.activeIcon
    }

    private var accentColor: Color {
        focusMode.accentColor
    }

    private var accessibilityLabel: String {
        let trimmedName = manager.currentFocusModeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName: String
        if trimmedName.isEmpty {
            baseName = focusMode.displayName
        } else {
            baseName = trimmedName
        }

        let finalName = focusMode == .doNotDisturb ? "Focus" : baseName
        return "Focus active: \(finalName)"
    }
}

#Preview {
    FocusIndicator()
        .frame(width: 30, height: 30)
        .background(Color.gray.opacity(0.2))
}
