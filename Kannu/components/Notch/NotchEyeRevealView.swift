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

/// Show / Hide Notch's eye, drawn as a pure function of `NotchEyeState.progress`.
///
/// Both views are `Animatable` on the progress, and AppDelegate animates that one value with a
/// single eased run, so SwiftUI hands every in-between value to `NotchEyeTimeline.frame(at:)` and
/// nothing here runs a clock of its own: no timeline, no repeating animation, nothing left running
/// once the eye settles.

/// Counts the eye's drawn frames, so the app log can tell a run that animated from one that
/// popped (`AppDelegate.runNotchEye`).
@MainActor
enum NotchEyeFrames {
    static var count = 0
}

/// Stands in for the closed notch's content while the eye plays: it widens the closed body by a
/// side on each side, and the notch's own fill and clip shape follow it, the way the inline HUD's
/// slots widen the notch. At rest it is exactly the resting width.
struct NotchEyeSpacer: View, Animatable {
    var progress: Double
    var fadesOnly: Bool
    var restingWidth: CGFloat
    var wingWidth: CGFloat
    var height: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let frame = NotchEyeTimeline.frame(at: progress, fadesOnly: fadesOnly)
        Color.clear
            .frame(width: max(0, restingWidth + 2 * wingWidth * frame.wing), height: height)
    }
}

/// The closed notch's body while the eye plays: a light that opens, a shimmer across it, one eye
/// in each side, and the notch's own `fill` spreading over the light from the notch outward.
struct NotchEyeView<Fill: View>: View, Animatable {
    var progress: Double
    var fadesOnly: Bool
    var wingWidth: CGFloat
    /// On a notched MacBook the middle is the hardware cutout, where no light can be seen, so the
    /// light and the fill come out of the notch's edges. On an island they grow from the middle.
    var centreIsHardware: Bool
    var eyeColor: Color
    @ViewBuilder var fill: () -> Fill

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let frame = NotchEyeTimeline.frame(at: progress, fadesOnly: fadesOnly)
        let _ = NotchEyeFrames.count += 1
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let side = wingWidth * frame.wing
            let restingWidth = max(0, width - 2 * side)
            let start = centreIsHardware ? restingWidth / 2 : 0
            let lightHalf = start + (width / 2 - start) * frame.wing
            let fillHalf = fadesOnly ? width / 2 : start + (width / 2 - start) * frame.fill

            ZStack {
                if frame.lightOpacity > 0, lightHalf > 0 {
                    light(halfWidth: lightHalf, start: start, height: height, frame: frame)
                }
                if frame.fill > 0, frame.fillOpacity > 0 {
                    fill()
                        .frame(width: width, height: height)
                        .mask {
                            Rectangle().frame(width: max(0, fillHalf * 2), height: height)
                        }
                        .opacity(frame.fillOpacity)
                }
                if frame.eyeOpacity > 0, side > 0 {
                    let eyeSize = min(wingWidth, height) * 0.5
                    let eyeX = side / 2
                    eye(size: eyeSize, frame: frame)
                        .position(x: eyeX, y: height / 2)
                    eye(size: eyeSize, frame: frame)
                        .position(x: width - eyeX, y: height / 2)
                }
            }
            .frame(width: width, height: height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A seam of light that opens to the notch's height, a shimmer passing across it. The light is
    /// drawn below full white so the shimmer has room to brighten it. On a notched MacBook two
    /// bands run out from the notch's edges across the sides, the only part anyone can see; on an
    /// island one band crosses from side to side.
    private func light(halfWidth: CGFloat, start: CGFloat, height: CGFloat, frame: NotchEyeTimeline.Frame) -> some View {
        let width = halfWidth * 2
        let lightHeight = 2 + (height - 2) * frame.lightOpen
        let band = max(18, width * (start > 0 ? 0.12 : 0.18))
        let offsets: [CGFloat] = start > 0
            ? { let reach = start - band / 2 + (halfWidth - start + band) * frame.shimmer
                return [-reach, reach] }()
            : [-width / 2 - band / 2 + (width + band) * frame.shimmer]
        return Capsule()
            .fill(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.8), .white.opacity(0.45)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                ZStack {
                    ForEach(offsets.indices, id: \.self) { index in
                        LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: band, height: height * 1.6)
                            .rotationEffect(.degrees(18))
                            .offset(x: offsets[index])
                    }
                }
                .opacity(frame.shimmerOpacity)
                .blendMode(.plusLighter)
            }
            .clipShape(Capsule())
            .frame(width: width, height: lightHeight)
            .opacity(frame.lightOpacity)
    }

    /// The eyelid is a vertical squash: shut at 0.08, open at 1. It opens on the notch's fill.
    private func eye(size: CGFloat, frame: NotchEyeTimeline.Frame) -> some View {
        Image(systemName: "eye.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(eyeColor)
            .scaleEffect(x: 1, y: frame.lid, anchor: .center)
            .opacity(frame.eyeOpacity)
    }
}
