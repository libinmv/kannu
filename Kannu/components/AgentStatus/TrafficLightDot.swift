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

import AppKit
import SwiftUI

/// A traffic-light dot drawn by Core Animation. The breath runs in the render server, so a lit dot
/// breathing for an hour costs the main thread nothing; the SwiftUI `.repeatForever` pulse it
/// replaces re-laid out the whole notch on every display frame (up to 120 a second on ProMotion).
/// Same pattern as `AudioSpectrum` (MusicVisualizer.swift).
final class TrafficLightDotView: NSView {
    private let dot = CALayer()
    private var diameter: CGFloat = 10
    private var isPulsing = false
    private static let pulseKey = "kannu.dot.pulse"
    private static let settleKey = "kannu.dot.settle"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        // No implicit animations: colour and geometry changes apply at once.
        dot.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(),
                       "cornerRadius": NSNull(), "transform": NSNull(), "opacity": NSNull()]
        layer?.addSublayer(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Hover, clicks and drags stay with the SwiftUI views around the dot.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// SwiftUI sets the frame after `makeNSView`; re-centre the dot whenever it changes.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        dot.cornerRadius = diameter / 2
        dot.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    func update(color: CGColor, diameter newDiameter: CGFloat, pulsing: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.backgroundColor = color
        CATransaction.commit()
        if newDiameter != diameter {
            diameter = newDiameter
            needsLayout = true
        }
        guard pulsing != isPulsing else { return }
        isPulsing = pulsing
        if pulsing { addPulse() } else { settle() }
    }

    func stop() {
        isPulsing = false
        dot.removeAllAnimations()
    }

    private func addPulse() {
        guard window != nil else { return }
        dot.removeAnimation(forKey: Self.settleKey)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = TrafficLightPulseSpec.scale
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = TrafficLightPulseSpec.opacity
        let breath = CAAnimationGroup()
        breath.animations = [scale, fade]
        breath.duration = TrafficLightPulseSpec.halfPeriod
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breath.isRemovedOnCompletion = false
        breath.preferredFrameRateRange = CAFrameRateRange(minimum: TrafficLightPulseSpec.minimumFrameRate,
                                                          maximum: TrafficLightPulseSpec.preferredFrameRate,
                                                          preferred: TrafficLightPulseSpec.preferredFrameRate)
        dot.add(breath, forKey: Self.pulseKey)
    }

    /// Eases back to rest from wherever the breath was; the model values never changed.
    private func settle() {
        let presentation = dot.presentation()
        dot.removeAnimation(forKey: Self.pulseKey)
        guard window != nil, let presentation else { return }
        let currentScale = (presentation.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
        let currentOpacity = presentation.opacity
        guard abs(currentScale - 1) > 0.01 || abs(currentOpacity - 1) > 0.01 else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = currentScale
        scale.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = currentOpacity
        fade.toValue = 1.0
        let rest = CAAnimationGroup()
        rest.animations = [scale, fade]
        rest.duration = TrafficLightPulseSpec.settleDuration
        rest.timingFunction = CAMediaTimingFunction(name: .easeOut)
        dot.add(rest, forKey: Self.settleKey)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            dot.removeAllAnimations()
        } else if isPulsing, dot.animation(forKey: Self.pulseKey) == nil {
            addPulse()
        }
    }
}

/// SwiftUI face of `TrafficLightDotView`.
struct TrafficLightDot: NSViewRepresentable {
    let color: Color
    let diameter: CGFloat
    let pulsing: Bool

    func makeNSView(context: Context) -> TrafficLightDotView {
        let view = TrafficLightDotView(frame: .zero)
        view.update(color: color.resolve(in: context.environment).cgColor, diameter: diameter, pulsing: pulsing)
        return view
    }

    func updateNSView(_ view: TrafficLightDotView, context: Context) {
        view.update(color: color.resolve(in: context.environment).cgColor, diameter: diameter, pulsing: pulsing)
    }

    static func dismantleNSView(_ view: TrafficLightDotView, coordinator: ()) {
        view.stop()
    }
}
