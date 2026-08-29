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

/// In-app colour picker: a saturation/brightness plane, a hue slider and a hex field.
///
/// Exists because `NSColorPanel` is unreliable in an `LSUIElement` accessory app — the panel
/// either never appears or arrives with no target, which is what made the old "Show Colors…"
/// path dead. Everything here is SwiftUI, so it works wherever a popover does.
///
/// Hue is kept in local state rather than derived from the bound colour on every render: hue is
/// undefined for greys, so a round-trip through black would otherwise snap the knob to red.
struct ColorSpectrumPicker: View {
    @Binding var color: Color
    var supportsOpacity: Bool = false

    @State private var hue: Double = 0
    @State private var saturation: Double = 1
    @State private var brightness: Double = 1
    @State private var hexText: String = ""
    @State private var didSeed = false

    private let planeHeight: CGFloat = 120
    private let sliderHeight: CGFloat = 14
    private let knobSize: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            saturationBrightnessPlane
            hueSlider
            hexRow
        }
        .onAppear { seedFromBoundColorIfNeeded() }
    }

    // MARK: - Plane

    private var saturationBrightnessPlane: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(hue: hue, saturation: 1, brightness: 1)
                LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                knob(at: ColorSpectrumMath.point(
                    saturation: saturation,
                    brightness: brightness,
                    width: geo.size.width,
                    height: geo.size.height
                ))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let result = ColorSpectrumMath.saturationBrightness(
                        atX: value.location.x, y: value.location.y,
                        width: geo.size.width, height: geo.size.height
                    )
                    saturation = result.saturation
                    brightness = result.brightness
                    pushColor()
                }
            )
        }
        .frame(height: planeHeight)
    }

    // MARK: - Hue

    private var hueSlider: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6.0)
                        .map { Color(hue: $0, saturation: 1, brightness: 1) },
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))

                Circle()
                    .fill(Color(hue: hue, saturation: 1, brightness: 1))
                    .frame(width: sliderHeight + 4, height: sliderHeight + 4)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .shadow(radius: 1)
                    .offset(x: ColorSpectrumMath.x(forHue: hue, width: geo.size.width) - (sliderHeight + 4) / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    hue = ColorSpectrumMath.hue(atX: value.location.x, width: geo.size.width)
                    pushColor()
                }
            )
        }
        .frame(height: sliderHeight + 4)
    }

    // MARK: - Hex

    private var hexRow: some View {
        HStack(spacing: 6) {
            KannuColorSwatch(color: color, size: 18)
            TextField("#RRGGBB", text: $hexText)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .onSubmit { applyHex() }
        }
    }

    // MARK: - Plumbing

    private func knob(at point: (x: Double, y: Double)) -> some View {
        Circle()
            .strokeBorder(color.contrastingForeground, lineWidth: 2)
            .frame(width: knobSize, height: knobSize)
            .offset(x: point.x - knobSize / 2, y: point.y - knobSize / 2)
    }

    private func seedFromBoundColorIfNeeded() {
        guard !didSeed else { return }
        didSeed = true
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        srgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        hue = Double(h)
        saturation = Double(s)
        brightness = Double(b)
        hexText = ColorSpectrumMath.hexString(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent)
        )
    }

    private func pushColor() {
        let updated = Color(hue: hue, saturation: saturation, brightness: brightness)
        color = updated
        if let srgb = NSColor(updated).usingColorSpace(.sRGB) {
            hexText = ColorSpectrumMath.hexString(
                red: Double(srgb.redComponent),
                green: Double(srgb.greenComponent),
                blue: Double(srgb.blueComponent)
            )
        }
    }

    /// Invalid input reverts to the current colour rather than applying something arbitrary.
    private func applyHex() {
        guard let rgb = ColorSpectrumMath.rgb(fromHex: hexText) else {
            if let srgb = NSColor(color).usingColorSpace(.sRGB) {
                hexText = ColorSpectrumMath.hexString(
                    red: Double(srgb.redComponent),
                    green: Double(srgb.greenComponent),
                    blue: Double(srgb.blueComponent)
                )
            }
            return
        }
        let picked = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        picked.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        hue = Double(h)
        saturation = Double(s)
        brightness = Double(b)
        color = Color(nsColor: picked)
        hexText = ColorSpectrumMath.hexString(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
