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

/// When the traffic light's attention cues start and stop. Each rule has a "next change" so a
/// view can wake once at the exact moment instead of re-evaluating on a periodic timer (two 1 Hz
/// timers and an unbounded 10 Hz one used to do that).
enum AgentTrafficLightAttention {
    /// A finished run's red dot breathes this long, then holds steady.
    static let redPulseSeconds: TimeInterval = 4
    /// "For 5 seconds, then glyph": the closed-notch pill's lifetime.
    static let fiveSecondPillSeconds: TimeInterval = 5
    /// The open panel's red badge blinks this long after a run ends.
    static let openPanelRedBlinkSeconds: TimeInterval = 5

    /// Yellow and green breathe while lit; red only within `redPulseSeconds` of the completion.
    static func pulses(yellowOrGreen: Bool, red: Bool, completedAt: Date?, now: Date) -> Bool {
        if red { return completedAt.map { now.timeIntervalSince($0) < redPulseSeconds } ?? false }
        return yellowOrGreen
    }

    /// When `pulses` next changes by itself — the end of the red window — or nil.
    static func pulseChange(red: Bool, completedAt: Date?, now: Date) -> Date? {
        guard red, let completedAt else { return nil }
        let end = completedAt.addingTimeInterval(redPulseSeconds)
        return end > now ? end : nil
    }

    static func pillVisible(fiveSecondMode: Bool, firstSeen: Date, now: Date) -> Bool {
        !fiveSecondMode || now.timeIntervalSince(firstSeen) < fiveSecondPillSeconds
    }

    static func pillChange(fiveSecondMode: Bool, firstSeen: Date, now: Date) -> Date? {
        guard fiveSecondMode else { return nil }
        let end = firstSeen.addingTimeInterval(fiveSecondPillSeconds)
        return end > now ? end : nil
    }

    static func blinks(startedAt: Date?, now: Date) -> Bool {
        startedAt.map { now.timeIntervalSince($0) < openPanelRedBlinkSeconds } ?? false
    }

    static func blinkChange(startedAt: Date?, now: Date) -> Date? {
        guard let startedAt else { return nil }
        let end = startedAt.addingTimeInterval(openPanelRedBlinkSeconds)
        return end > now ? end : nil
    }
}
