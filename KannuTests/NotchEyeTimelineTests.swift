//
//  NotchEyeTimelineTests.swift
//  KannuTests
//
//  Copyright (C) 2026 Kannu contributors
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import XCTest

/// Show / Hide Notch's eye is one progress value from 0 (no notch) to 1 (the resting notch), and
/// every layer is a pure function of it, so the order of the effect is checked here: nothing at the
/// start, exactly the resting notch at the end, eyes only in sides that are fully out, and the sides
/// drawing back in only behind the notch's own fill.
final class NotchEyeTimelineTests: XCTestCase {

    private typealias Timeline = NotchEyeTimeline

    private static let samples = stride(from: 0.0, through: 1.0, by: 0.001).map { $0 }

    func testNothingIsDrawnBeforeTheEyeStarts() {
        for p in [-0.5, 0] {
            let frame = Timeline.frame(at: p, fadesOnly: false)
            XCTAssertEqual(frame.wing, 0, "p \(p)")
            XCTAssertEqual(frame.lightOpacity, 0, "p \(p)")
            XCTAssertEqual(frame.eyeOpacity, 0, "p \(p)")
            XCTAssertEqual(frame.fill, 0, "p \(p)")
        }
    }

    func testTheEndIsTheRestingNotch() {
        for p in [1, 1.5] {
            let frame = Timeline.frame(at: p, fadesOnly: false)
            XCTAssertEqual(frame.wing, 0, "p \(p)")
            XCTAssertEqual(frame.lightOpacity, 0, "p \(p)")
            XCTAssertEqual(frame.shimmerOpacity, 0, accuracy: 1e-9, "p \(p)")
            XCTAssertEqual(frame.eyeOpacity, 0, "p \(p)")
            XCTAssertEqual(frame.fill, 1, "p \(p)")
            XCTAssertEqual(frame.fillOpacity, 1, "p \(p)")
        }
    }

    func testTheEyesShowOnlyWhileTheSidesAreOut() {
        var sawEyes = false
        for p in Self.samples {
            let frame = Timeline.frame(at: p, fadesOnly: false)
            guard frame.eyeOpacity > 0 else { continue }
            sawEyes = true
            XCTAssertEqual(frame.wing, 1, accuracy: 1e-9, "an eye shows at p \(p) in a side that is not fully out")
        }
        XCTAssertTrue(sawEyes, "the eyes never show")
    }

    func testTheEyesOpenWhileTheyShow() {
        let open = Self.samples.filter { Timeline.frame(at: $0, fadesOnly: false).eyeOpacity >= 1 }
        XCTAssertFalse(open.isEmpty)
        XCTAssertTrue(open.contains { Timeline.frame(at: $0, fadesOnly: false).lid >= 1 }, "the eyes never open fully")
        XCTAssertLessThan(Timeline.frame(at: open[0], fadesOnly: false).lid, 0.5, "the eyes are already open when they appear")
    }

    /// White eyes over the white light could not be seen opening: they open on the notch's fill.
    func testTheEyesOpenOnTheFillNotTheLight() {
        for p in Self.samples {
            let frame = Timeline.frame(at: p, fadesOnly: false)
            guard frame.eyeOpacity > 0 else { continue }
            XCTAssertGreaterThanOrEqual(frame.fill, 0.9, "an eye shows at p \(p) before the fill is under it")
            XCTAssertLessThanOrEqual(frame.lightOpacity, 0.15, "an eye shows at p \(p) over the light")
        }
    }

    func testTheSidesDrawInOnlyBehindTheFill() {
        var sawThemOut = false
        for p in Self.samples {
            let frame = Timeline.frame(at: p, fadesOnly: false)
            if frame.wing >= 1 { sawThemOut = true }
            guard sawThemOut, frame.wing < 1 else { continue }
            XCTAssertEqual(frame.fill, 1, "the sides draw in at p \(p) before the fill covers them")
            XCTAssertEqual(frame.lightOpacity, 0, "the sides draw in at p \(p) with the light still on")
            XCTAssertEqual(frame.eyeOpacity, 0, "the sides draw in at p \(p) with the eyes still showing")
        }
        XCTAssertTrue(sawThemOut, "the sides never come out")
    }

    func testTheLightComesOnBeforeTheFillCoversIt() {
        let firstLight = Self.samples.first { Timeline.frame(at: $0, fadesOnly: false).lightOpacity > 0 }
        let firstFill = Self.samples.first { Timeline.frame(at: $0, fadesOnly: false).fill > 0 }
        XCTAssertNotNil(firstLight)
        XCTAssertNotNil(firstFill)
        XCTAssertLessThan(firstLight ?? 1, firstFill ?? 0)
    }

    func testReduceMotionOnlyFades() {
        var last = -1.0
        for p in Self.samples {
            let frame = Timeline.frame(at: p, fadesOnly: true)
            XCTAssertEqual(frame.wing, 0)
            XCTAssertEqual(frame.lightOpacity, 0)
            XCTAssertEqual(frame.eyeOpacity, 0)
            XCTAssertEqual(frame.fill, 1)
            XCTAssertGreaterThanOrEqual(frame.fillOpacity, last)
            last = frame.fillOpacity
        }
        XCTAssertEqual(Timeline.frame(at: 0, fadesOnly: true).fillOpacity, 0)
        XCTAssertEqual(Timeline.frame(at: 1, fadesOnly: true).fillOpacity, 1)
    }

    func testKeysHoldOutsideAndEaseBetween() {
        let keys: [Timeline.Key] = [(0.2, 0), (0.6, 1)]
        XCTAssertEqual(Timeline.value(of: keys, at: 0), 0)
        XCTAssertEqual(Timeline.value(of: keys, at: 0.4), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Timeline.value(of: keys, at: 1), 1)
        XCTAssertEqual(Timeline.value(of: [], at: 0.5), 0)
    }

    /// David, 2026-10-24: "make closing a bit slower and smoother, opening a bit too".
    func testTheAgreedTimings() {
        XCTAssertEqual(Timeline.showDuration, 1.25)
        XCTAssertEqual(Timeline.hideDuration, 1.1)
        XCTAssertEqual(Timeline.fadeDuration, 0.2)
    }

    /// The run's ease is SwiftUI's `timingCurve` with these points; with x at a third and two
    /// thirds the bezier is exactly smoothstep in time, which is what `Run` assumes.
    func testTheEaseIsSmoothstep() {
        let ease = Timeline.easeControlPoints
        for t in Self.samples {
            let u = 1 - t
            let x = 3 * u * u * t * ease.c0x + 3 * u * t * t * ease.c1x + t * t * t
            let y = 3 * u * u * t * ease.c0y + 3 * u * t * t * ease.c1y + t * t * t
            XCTAssertEqual(x, t, accuracy: 1e-9)
            XCTAssertEqual(y, Timeline.smoothstep(t), accuracy: 1e-9)
        }
    }

    /// No layer stops halfway through a move: each one's keys only rise, only fall or hold.
    func testEveryMoveIsOneSegment() {
        let tracks: [(String, [Timeline.Key])] = [
            ("wing", Timeline.wingKeys), ("light", Timeline.lightOpacityKeys), ("light open", Timeline.lightOpenKeys),
            ("shimmer", Timeline.shimmerKeys), ("fill", Timeline.fillKeys), ("eye", Timeline.eyeOpacityKeys),
            ("lid", Timeline.lidKeys),
        ]
        for (name, keys) in tracks {
            let steps = zip(keys, keys.dropFirst()).map { $1.value - $0.value }.filter { $0 != 0 }
            for (a, b) in zip(steps, steps.dropFirst()) {
                XCTAssertFalse((a > 0) == (b > 0), "\(name) stops halfway through a move")
            }
        }
    }

    /// A toggle mid-run plays back from where the run has got to, for its share of a full run.
    func testARunReversesFromWhereItIs() {
        let run = Timeline.Run(from: 1, to: 0, duration: 0.8, startedAt: 10)
        XCTAssertEqual(run.progress(at: 9), 1)
        XCTAssertEqual(run.progress(at: 10.2), 1 - 0.15625, accuracy: 1e-9)
        XCTAssertEqual(run.progress(at: 10.4), 0.5, accuracy: 1e-9)
        XCTAssertEqual(run.progress(at: 11), 0)
        XCTAssertEqual(Timeline.Run(from: 0.3, to: 1, duration: 0, startedAt: 0).progress(at: 0), 1)

        XCTAssertEqual(Timeline.duration(toward: 1, from: 0.5, full: Timeline.showDuration), Timeline.showDuration / 2, accuracy: 1e-9)
        XCTAssertEqual(Timeline.duration(toward: 0, from: 1, full: Timeline.hideDuration), Timeline.hideDuration, accuracy: 1e-9)
        XCTAssertEqual(Timeline.duration(toward: 1, from: 0.99, full: Timeline.showDuration), Timeline.shortestRun)
    }

    func testTheSidesFitTheRoomBesideTheNotch() {
        XCTAssertEqual(Timeline.wingWidth(closedHeight: 32, closedWidth: 200, available: 200), 44)
        XCTAssertEqual(Timeline.wingWidth(closedHeight: 10, closedWidth: 200, available: 200), 36)
        XCTAssertEqual(Timeline.wingWidth(closedHeight: 32, closedWidth: 200, available: 20), 20)
        XCTAssertEqual(Timeline.wingWidth(closedHeight: 32, closedWidth: 50, available: 200), 21, accuracy: 1e-9)
        XCTAssertEqual(Timeline.wingWidth(closedHeight: 32, closedWidth: 200, available: -5), 0)
    }
}
