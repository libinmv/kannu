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

struct LiveStreamProgressIndicator: View {
    let tint: Color

    private var baseGradient: LinearGradient {
        LinearGradient(
            colors: [
                tint.opacity(0.18),
                tint.opacity(0.42),
                tint.opacity(0.18)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var centerShade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.0), location: 0.0),
                .init(color: .black.opacity(0.38), location: 0.5),
                .init(color: .black.opacity(0.0), location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.07))
            .overlay(
                Capsule()
                    .fill(baseGradient)
                    .opacity(0.9)
                    .blendMode(.plusLighter)
            )
            .overlay(
                Capsule()
                    .fill(centerShade)
                    .blendMode(.multiply)
            )
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.6), lineWidth: 0.7)
                    .blendMode(.screen)
            )
            .frame(height: 10)
            .overlay {
                Text("LIVE")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(Color.white)
                    .shadow(color: .black.opacity(0.65), radius: 4, y: 1)
            }
            .allowsHitTesting(false)
            .accessibilityLabel("Live stream indicator")
            .opacity(0.95)
    }
}
