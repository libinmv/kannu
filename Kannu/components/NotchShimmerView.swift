/*
 * Kannu (കണ്ണ്)
 * Copyright (C) 2024-2026 Kannu Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import SwiftUI

struct NotchShimmerView: View {
    var cornerRadius: CGFloat = 6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let phase = elapsed.truncatingRemainder(dividingBy: 2.8) / 2.8

            GeometryReader { proxy in
                let width = proxy.size.width
                let height = proxy.size.height
                let sweepWidth = max(width, height) * 0.85

                ZStack {
                    LinearGradient(
                        colors: [
                            .clear,
                            Color.white.opacity(0.06),
                            Color.white.opacity(0.18),
                            Color.white.opacity(0.28),
                            Color.white.opacity(0.18),
                            Color.white.opacity(0.06),
                            .clear,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: sweepWidth, height: height * 2.2)
                    .rotationEffect(.degrees(18))
                    .offset(x: (phase * (width + sweepWidth)) - sweepWidth)
                    .blur(radius: 2)

                    LinearGradient(
                        colors: [
                            .clear,
                            Color.white.opacity(0.04),
                            Color.white.opacity(0.12),
                            .clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .opacity(0.7 + (0.3 * sin(phase * .pi * 2)))
                }
                .frame(width: width, height: height)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
