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

/// Where Show / Hide Notch's eye animation is. `AppDelegate.applyNotchVisibility` is the only
/// writer; every notch window's `ContentView` draws it.
enum NotchEyePhase: Equatable {
    case settled
    case opening
    case closing
}

struct NotchEyeState: Equatable {
    var phase: NotchEyePhase = .settled
    /// 0 is no notch at all, 1 is the resting closed notch. Showing runs it up, hiding runs the same
    /// frames back down, so hiding is the exact reverse by construction. It is animated by the
    /// transaction that writes it, so the views see every value in between.
    var progress: Double = 1
    /// Reduce Motion: the notch only fades.
    var fadesOnly = false

    var isAnimating: Bool { phase != .settled }

    static let settled = NotchEyeState()
}

/// The eye's timings and frames, pure so they are tested.
///
/// Showing, as progress runs 0 to 1: a seam of light appears at the notch and spreads out to both
/// sides, opens into a bright band with a shimmer passing across it, the notch's own fill spreads
/// over the light from the notch outward, an eye opens in each side on that fill, the eyes fade,
/// and the sides draw back in to the resting notch. Hiding plays it backwards: the eye closes, the
/// fill draws back off the light, and the light shuts to a seam. The eyes open on the fill, not on
/// the light: white on white, the opening could not be seen.
enum NotchEyeTimeline {
    static let showDuration: TimeInterval = 1.25
    static let hideDuration: TimeInterval = 1.1
    /// Reduce Motion, either way.
    static let fadeDuration: TimeInterval = 0.2
    /// An open notch closes before the eye does: a critically damped close spring is most of the
    /// way there by then.
    static let closeFirst: TimeInterval = 0.3
    /// A reversal near the end still gets a visible run.
    static let shortestRun: TimeInterval = 0.12
    static let settleDuration: TimeInterval = 0.3

    struct Frame: Equatable {
        /// How far the sides are out, 0 to 1.
        var wing: Double
        var lightOpacity: Double
        /// The light's height, from a 2 pt seam (0) to the notch's height (1).
        var lightOpen: Double
        /// The shimmer band's position across the light, 0 to 1.
        var shimmer: Double
        var shimmerOpacity: Double
        /// The eyelid, as a vertical scale: 0.08 is shut, 1 is open.
        var lid: Double
        var eyeOpacity: Double
        /// How far the notch's fill has spread from the notch out to the sides, 0 to 1. Nothing
        /// of the fill is drawn at 0.
        var fill: Double
        var fillOpacity: Double
    }

    typealias Key = (at: Double, value: Double)

    // Each layer's moves are single long segments: every key is a stop (smoothstep has no speed at
    // its ends), so a move split in two stutters in the middle.
    static let wingKeys: [Key] = [(0.04, 0), (0.26, 1), (0.88, 1), (1.00, 0)]
    static let lightOpacityKeys: [Key] = [(0, 0), (0.12, 1), (0.34, 1), (0.56, 0)]
    static let lightOpenKeys: [Key] = [(0.14, 0), (0.34, 1)]
    static let shimmerKeys: [Key] = [(0.20, 0), (0.48, 1)]
    static let fillKeys: [Key] = [(0.38, 0), (0.58, 1)]
    static let eyeOpacityKeys: [Key] = [(0.56, 0), (0.60, 1), (0.82, 1), (0.88, 0)]
    static let lidKeys: [Key] = [(0.58, 0.08), (0.76, 1)]

    static func frame(at progress: Double, fadesOnly: Bool) -> Frame {
        let p = min(max(progress, 0), 1)
        if fadesOnly {
            return Frame(wing: 0, lightOpacity: 0, lightOpen: 0, shimmer: 0, shimmerOpacity: 0,
                         lid: 1, eyeOpacity: 0, fill: 1, fillOpacity: smoothstep(p))
        }
        let shimmer = value(of: shimmerKeys, at: p)
        return Frame(
            wing: value(of: wingKeys, at: p),
            lightOpacity: value(of: lightOpacityKeys, at: p),
            lightOpen: value(of: lightOpenKeys, at: p),
            shimmer: shimmer,
            shimmerOpacity: sin(Double.pi * shimmer) * 0.6,
            lid: value(of: lidKeys, at: p),
            eyeOpacity: value(of: eyeOpacityKeys, at: p),
            fill: value(of: fillKeys, at: p),
            fillOpacity: 1
        )
    }

    /// Held outside the keys, eased between them.
    static func value(of keys: [Key], at p: Double) -> Double {
        guard let first = keys.first, let last = keys.last else { return 0 }
        if p <= first.at { return first.value }
        if p >= last.at { return last.value }
        for (a, b) in zip(keys, keys.dropFirst()) where p <= b.at {
            let t = b.at > a.at ? (p - a.at) / (b.at - a.at) : 1
            return a.value + (b.value - a.value) * smoothstep(t)
        }
        return last.value
    }

    static func smoothstep(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// How far each side reaches out: about the notch's height plus room for the eye, never more
    /// than the window has beside the resting notch.
    static func wingWidth(closedHeight: Double, closedWidth: Double, available: Double) -> Double {
        max(0, min(max(36, closedHeight + 12), closedWidth * 0.42, available))
    }

    /// The time a run takes from `from` to `target`: a full run's share, so a reversal halfway
    /// through takes half as long back.
    static func duration(toward target: Double, from: Double, full: TimeInterval) -> TimeInterval {
        max(shortestRun, full * abs(target - from))
    }

    /// The run's ease, as the bezier control points SwiftUI's `timingCurve` takes. With x at a third
    /// and two thirds, the curve's x is its parameter, so it is exactly `smoothstep` in time: the
    /// eye starts and ends at rest, and `Run.progress(at:)` knows where it is to the frame.
    static let easeControlPoints = (c0x: 1.0 / 3, c0y: 0.0, c1x: 2.0 / 3, c1y: 1.0)

    /// One eased run of the progress, timed by the app's clock: where a reversal starts from.
    struct Run: Equatable {
        var from: Double
        var to: Double
        var duration: TimeInterval
        var startedAt: TimeInterval

        func progress(at now: TimeInterval) -> Double {
            guard duration > 0 else { return to }
            let t = min(max((now - startedAt) / duration, 0), 1)
            return from + (to - from) * NotchEyeTimeline.smoothstep(t)
        }
    }
}
