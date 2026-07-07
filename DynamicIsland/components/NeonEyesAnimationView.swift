/*
 * Kannu (കണ്ണ്)
 * Copyright (C) 2024-2026 Kannu Contributors
 *
 * Procedural neon eyes animation inspired by the bundled eyes artwork.
 */

import SwiftUI

struct NeonEyesAnimationView: View {
    enum PlaybackMode: Equatable {
        case loop
        case oneShot
    }

    enum Placement {
        case center
        case side
    }

    var playbackMode: PlaybackMode = .loop
    var placement: Placement = .center
    var onComplete: (() -> Void)? = nil

    @State private var glowPhase = false
    @State private var blinkProgress: CGFloat = 1
    @State private var didFinishOneShot = false

    private let eyeColor = Color(red: 0.0, green: 0.82, blue: 1.0)
    private let pupilColor = Color(red: 0.55, green: 0.95, blue: 1.0)

    var body: some View {
        GeometryReader { proxy in
            let metrics = eyeMetrics(in: proxy.size)

            HStack(spacing: metrics.spacing) {
                if placement == .center {
                    Spacer(minLength: 0)
                }

                neonEye(
                    width: metrics.eyeWidth,
                    height: metrics.eyeHeight,
                    pupilSize: metrics.pupilSize,
                    lineWidth: metrics.lineWidth
                )
                neonEye(
                    width: metrics.eyeWidth,
                    height: metrics.eyeHeight,
                    pupilSize: metrics.pupilSize,
                    lineWidth: metrics.lineWidth
                )

                if placement == .center {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: placement == .side ? .trailing : .center)
        }
        .task(id: playbackMode) {
            switch playbackMode {
            case .loop:
                await runLoopPlayback()
            case .oneShot:
                await runOneShotPlayback()
            }
        }
    }

    private struct EyeMetrics {
        let eyeWidth: CGFloat
        let eyeHeight: CGFloat
        let spacing: CGFloat
        let pupilSize: CGFloat
        let lineWidth: CGFloat
    }

    private func eyeMetrics(in size: CGSize) -> EyeMetrics {
        switch placement {
        case .side:
            let availableWidth = max(8, size.width)
            let spacing = max(1, availableWidth * 0.07)
            let eyeWidth = max(2.5, (availableWidth - spacing) / 2)
            let eyeHeight = min(max(4, size.height * 0.8), eyeWidth * 0.62)
            let pupilSize = max(1.6, eyeHeight * 0.15)
            let lineWidth = max(0.75, eyeHeight * 0.09)
            return EyeMetrics(
                eyeWidth: eyeWidth,
                eyeHeight: eyeHeight,
                spacing: spacing,
                pupilSize: pupilSize,
                lineWidth: lineWidth
            )
        case .center:
            let eyeHeight = max(8, min(size.height * 0.68, size.width * 0.11))
            let eyeWidth = eyeHeight * 1.75
            let spacing = eyeWidth * 0.3
            let pupilSize = max(3, eyeHeight * 0.16)
            let lineWidth = max(1.1, eyeHeight * 0.095)
            return EyeMetrics(
                eyeWidth: eyeWidth,
                eyeHeight: eyeHeight,
                spacing: spacing,
                pupilSize: pupilSize,
                lineWidth: lineWidth
            )
        }
    }

    @ViewBuilder
    private func neonEye(
        width: CGFloat,
        height: CGFloat,
        pupilSize: CGFloat,
        lineWidth: CGFloat
    ) -> some View {
        ZStack {
            AlmondEyeOutline()
                .stroke(eyeColor.opacity(glowPhase ? 0.95 : 0.72), lineWidth: lineWidth)
                .shadow(color: eyeColor.opacity(glowPhase ? 0.95 : 0.55), radius: glowPhase ? 8 : 4)
                .shadow(color: eyeColor.opacity(0.35), radius: glowPhase ? 14 : 8)

            Circle()
                .fill(pupilColor)
                .frame(width: pupilSize, height: pupilSize)
                .shadow(color: eyeColor.opacity(0.9), radius: 4)
                .shadow(color: eyeColor.opacity(0.45), radius: 8)
        }
        .frame(width: width, height: height)
        .scaleEffect(x: 1, y: blinkProgress, anchor: .center)
    }

    private func runLoopPlayback() async {
        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
            glowPhase = true
        }

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            await performBlink(duration: 0.12)
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await performBlink(duration: 0.12)
            try? await Task.sleep(nanoseconds: 3_600_000_000)
        }
    }

    private func runOneShotPlayback() async {
        withAnimation(.easeInOut(duration: 0.8)) {
            glowPhase = true
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }
        await performBlink(duration: 0.14)
        try? await Task.sleep(nanoseconds: 180_000_000)
        guard !Task.isCancelled else { return }
        await performBlink(duration: 0.14)
        try? await Task.sleep(nanoseconds: 2_200_000_000)
        guard !Task.isCancelled else { return }
        finishOneShotIfNeeded()
    }

    @MainActor
    private func performBlink(duration: TimeInterval) async {
        withAnimation(.easeIn(duration: duration * 0.45)) {
            blinkProgress = 0.08
        }
        try? await Task.sleep(nanoseconds: UInt64(duration * 0.45 * 1_000_000_000))
        withAnimation(.easeOut(duration: duration * 0.55)) {
            blinkProgress = 1
        }
        try? await Task.sleep(nanoseconds: UInt64(duration * 0.55 * 1_000_000_000))
    }

    @MainActor
    private func finishOneShotIfNeeded() {
        guard playbackMode == .oneShot, !didFinishOneShot else { return }
        didFinishOneShot = true
        onComplete?()
    }
}

private struct AlmondEyeOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let insetX = rect.width * 0.02
        let left = rect.minX + insetX
        let right = rect.maxX - insetX
        let midY = rect.midY
        let topControlY = rect.minY + rect.height * 0.08
        let bottomControlY = rect.maxY - rect.height * 0.08

        path.move(to: CGPoint(x: left, y: midY))
        path.addQuadCurve(
            to: CGPoint(x: right, y: midY),
            control: CGPoint(x: rect.midX, y: topControlY)
        )
        path.addQuadCurve(
            to: CGPoint(x: left, y: midY),
            control: CGPoint(x: rect.midX, y: bottomControlY)
        )
        return path
    }
}

#Preview {
    NeonEyesAnimationView()
        .frame(width: 220, height: 36)
        .padding()
        .background(Color.black)
}
