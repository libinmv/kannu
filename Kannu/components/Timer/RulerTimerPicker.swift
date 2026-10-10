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
import Defaults

#if canImport(AppKit)
import AppKit

// The trackpad scroll monitor is the shared `ScrollWheelMonitor` (HorizontalSwipeMonitor.swift):
// NSView.scrollWheel is not delivered when SwiftUI layers sit above the representable.

// MARK: - Haptic

private func triggerHaptic() {
    NSHapticFeedbackManager.defaultPerformer.perform(
        .alignment,
        performanceTime: .now
    )
}
#endif

// MARK: - RulerTimerPicker

struct RulerTimerPicker: View {
    @EnvironmentObject private var vm: KannuViewModel

    @Binding var hours: Int
    @Binding var minutes: Int
    @Binding var seconds: Int
    let tintColor: Color
    let startAction: () -> Void
    /// The pointer entered (true) or left (false) the ruler strip, whose sideways scroll sets the
    /// minutes: `NotchTimerView` holds its tab-wide page swipe off meanwhile.
    var onScrollAreaHover: (Bool) -> Void = { _ in }

    // Raw continuous value for smooth dragging
    @State private var totalMinutes: Double = 10.0
    @State private var dragStartValue: Double = 10.0
    @State private var isDragging = false
    @State private var lastHapticMinute: Int = -1
    @State private var isSuppressingScrollGestures = false
    /// `@State`, so the token survives a re-render: a plain `let` minted a new one each time, and a
    /// release then named a token that was never inserted, leaving the notch's scroll gesture off.
    @State private var scrollSuppressionToken = UUID()

    private let range: ClosedRange<Double> = 0...90
    private let tickSpacing: CGFloat = 10   // px per minute
    private let fadeWidth: CGFloat = 48     // width of edge fade

    var body: some View {
        VStack(spacing: 0) {
            rulerArea
            controlRow
        }
        .onAppear { syncFromBindings() }
        .onChange(of: hours)   { _, _ in syncFromBindings() }
        .onChange(of: minutes) { _, _ in syncFromBindings() }
        .onChange(of: seconds) { _, _ in syncFromBindings() }
        .onChange(of: totalMinutes) { _, newVal in
            let rounded = Int(newVal.rounded())
            hours   = rounded / 60
            minutes = rounded % 60
            seconds = 0
            fireHapticIfNeeded(roundedMinute: rounded)
        }
    }

    // MARK: Ruler

    private var rulerArea: some View {
        GeometryReader { geo in
            let width = geo.size.width

            ZStack(alignment: .top) {
                // ── tick marks and labels ──
                Canvas { ctx, size in
                    let centerX = size.width / 2
                    let currentMinutes = totalMinutes

                    let span = Int(ceil((size.width / 2) / tickSpacing)) + 3
                    let start = max(0, Int(currentMinutes) - span)
                    let end   = min(90, Int(currentMinutes) + span)

                    for m in start...end {
                        let x = centerX + CGFloat(Double(m) - currentMinutes) * tickSpacing
                        let isMajor = (m % 5 == 0)

                        // tick
                        let tickH: CGFloat = isMajor ? 16 : 10
                        let tickW: CGFloat = isMajor ? 2 : 1.5
                        let opacity: Double = isMajor ? 0.9 : 0.5
                        let rect = CGRect(
                            x: x - tickW / 2,
                            y: isMajor ? 14 : 18,
                            width: tickW,
                            height: tickH
                        )
                        ctx.fill(
                            Path(roundedRect: rect, cornerRadius: 1),
                            with: .color(tintColor.opacity(opacity))
                        )

                        // label every 5 minutes
                        if isMajor {
                            let str = "\(m)"
                            let resolved = ctx.resolve(
                                Text(str)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundColor(tintColor.opacity(0.85))
                            )
                            let textSize = resolved.measure(in: CGSize(width: 40, height: 20))
                            ctx.draw(resolved, at: CGPoint(x: x, y: 6), anchor: .center)
                            _ = textSize
                        }
                    }
                }
                .frame(height: TimerComposerMetrics.rulerCanvasHeight)

                // ── pointer triangle ──
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(tintColor)
                    .frame(width: width)
                    .offset(y: TimerComposerMetrics.rulerPointerOffset)

                // ── drag gesture overlay ──
                Color.clear
                    .frame(width: width, height: TimerComposerMetrics.rulerAreaHeight)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                if !isDragging {
                                    isDragging = true
                                    dragStartValue = totalMinutes
                                }
                                let change = Double(-value.translation.width) / Double(tickSpacing)
                                var next = dragStartValue + change
                                next = min(max(range.lowerBound, next), range.upperBound)
                                totalMinutes = next
                            }
                            .onEnded { _ in
                                isDragging = false
                                withAnimation(.smooth(duration: 0.15)) {
                                    totalMinutes = totalMinutes.rounded()
                                }
                            }
                    )
            }
            // ── edge fade mask ──
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: fadeWidth)

                    Rectangle()
                        .frame(maxWidth: .infinity)

                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: fadeWidth)
                }
            )
#if canImport(AppKit)
            .background {
                ScrollWheelMonitor { event in
                    guard event.isHorizontalTrackpadScroll else { return false }
                    applyTrackpadScroll(event.scrollingDeltaX)
                    return true
                }
            }
#endif
            .onHover { hovering in
                updateScrollGestureSuppression(hovering)
                onScrollAreaHover(hovering)
            }
        }
        // Sized by TimerComposerMetrics so the timer tab fits without the notch growing.
        .frame(height: TimerComposerMetrics.rulerAreaHeight)
        .onDisappear {
            updateScrollGestureSuppression(false)
            onScrollAreaHover(false)
        }
    }

    // MARK: Control row

    private var controlRow: some View {
        HStack(alignment: .center, spacing: 0) {
            // Start Timer pill button — style matches the screenshot
            Button(action: {
                guard totalMinutes.rounded() > 0 else { return }
                startAction()
            }) {
                Text(String(localized: "Start Timer"))
                    .font(.system(size: TimerComposerMetrics.buttonFontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(tintColor)
                    .padding(.horizontal, 16)
                    .frame(height: TimerComposerMetrics.rulerButtonHeight)
                    .background(
                        Capsule()
                            .fill(tintColor.opacity(0.18))
                    )
                    .overlay(
                        Capsule()
                            .stroke(tintColor.opacity(0.25), lineWidth: 1.5)
                    )
            }
            .buttonStyle(.plain)
            .opacity(totalMinutes.rounded() == 0 ? 0.45 : 1.0)
            .disabled(totalMinutes.rounded() == 0)

            Spacer()

            // Large time readout
            Text(formattedDisplayTime)
                .font(.system(size: TimerComposerMetrics.rulerReadoutFontSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(height: TimerComposerMetrics.rulerReadoutHeight)
                .foregroundStyle(tintColor)
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.12), value: Int(totalMinutes.rounded()))
        }
        .padding(.horizontal, 6)
        .padding(.top, TimerComposerMetrics.rulerControlTopPadding)
    }

    // MARK: Helpers

#if canImport(AppKit)
    private func applyTrackpadScroll(_ delta: CGFloat) {
        // scrollingDeltaX: positive = right; invert so scrolling right increases time
        let change = Double(-delta) / Double(tickSpacing)
        var next = totalMinutes + change
        next = min(max(range.lowerBound, next), range.upperBound)
        totalMinutes = next
    }

    private func updateScrollGestureSuppression(_ hovering: Bool) {
        guard hovering != isSuppressingScrollGestures else { return }
        isSuppressingScrollGestures = hovering
        vm.setScrollGestureSuppression(hovering, token: scrollSuppressionToken)
    }
#endif

    private func syncFromBindings() {
        guard !isDragging else { return }
        let newTotal = Double(hours * 60 + minutes)
        if abs(totalMinutes - newTotal) > 0.01 {
            totalMinutes = newTotal
        }
    }

    private func fireHapticIfNeeded(roundedMinute: Int) {
#if canImport(AppKit)
        if roundedMinute != lastHapticMinute {
            lastHapticMinute = roundedMinute
            triggerHaptic()
        }
#endif
    }

    private var formattedDisplayTime: String {
        let m = Int(totalMinutes.rounded())
        let hrs  = m / 60
        let mins = m % 60
        if hrs > 0 {
            return String(format: "%d:%02d:00", hrs, mins)
        } else {
            return String(format: "%02d:00", mins)
        }
    }
}
