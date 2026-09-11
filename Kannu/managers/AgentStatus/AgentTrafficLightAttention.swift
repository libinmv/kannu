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

import Foundation

/// How the lit traffic-light dot breathes. Pinned by a test so the look cannot drift when the
/// drawing changes (it is drawn by Core Animation since the SwiftUI pulse cost a notch re-layout on
/// every display frame).
enum TrafficLightPulseSpec {
    /// Peak scale of one breath (was 1.15, widened because it read as too subtle).
    static let scale: CGFloat = 1.3
    /// Opacity at the peak of a breath.
    static let opacity: Float = 0.5
    /// One way of a breath, ease-in-out; the animation autoreverses.
    static let halfPeriod: Double = 0.7
    /// Easing back to rest when the pulse stops.
    static let settleDuration: Double = 0.15
    /// Frames per second the render server may use: a 0.7 s breath at 30 fps looks the same as at
    /// 120 and costs a quarter of the compositing.
    static let minimumFrameRate: Float = 15
    static let preferredFrameRate: Float = 30
}
