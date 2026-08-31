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
import AppKit

/// Where a tooltip bubble sits relative to its control.
enum HoverTooltipEdge {
    case above
    case below
}

/// A SwiftUI-drawn hover tooltip for the notch.
///
/// SwiftUI's `.help(...)` is dead here: it compiles to `NSView.toolTip`, and AppKit only shows
/// tooltips for the **active** application. Kannu is an `LSUIElement` accessory app whose notch is a
/// non-activating panel, so it never becomes active and the tooltip manager never runs — verified
/// live (zero tooltip events while hovering). `.onHover` does fire, which is what hover-reveal
/// already relies on, so the bubble is drawn in-app instead.
///
/// It is an overlay rather than a `.popover` because a popover renders in its own window and
/// coordinates with the notch's hover-open state, which would fight the reveal/hide logic.
struct HoverTooltip: ViewModifier {
    let text: String
    let edge: HoverTooltipEdge
    /// Set the pointing-hand cursor while hovered. Callers that used to do this with their own
    /// `.onHover` must use this instead: two hover handlers on one control fight, and the tooltip
    /// stops appearing.
    let pointingHandCursor: Bool

    @State private var hovering = false
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                hovering = isHovering
                if pointingHandCursor {
                    if isHovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
                if isHovering {
                    // Short delay so brushing past a control does not flash a bubble.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        if hovering { withAnimation(.easeOut(duration: 0.12)) { visible = true } }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.1)) { visible = false }
                }
            }
            .overlay(alignment: edge == .above ? .bottomTrailing : .topTrailing) {
                if visible {
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        // `.fixedSize()` on BOTH axes is load-bearing. This is an overlay, so the
                        // proposed width is the parent control's — often a ~14pt icon button.
                        // Relaxing the horizontal axis makes the bubble lay out at that width and
                        // effectively vanish. Sizing to the text's ideal width escapes the parent.
                        // Long labels are handled by keeping the strings short, not by wrapping.
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                        .offset(y: edge == .above ? -22 : 22)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(100)
                }
            }
    }
}

extension View {
    /// Notch-safe replacement for `.help(...)`, which never renders in this app.
    /// The bubble is an overlay, so it is subject to any ancestor clip — a `ScrollView` or
    /// `.clipped()` will swallow whatever falls outside the content bounds. Choose `edge` by where
    /// the control sits in its container, not by aesthetics: a control at the top of a scroll view
    /// must open `.below`, or the bubble lands in the clipped region and is never seen.
    /// - Parameter edge: `.above` for controls low in their container, `.below` for those near the top.
    func hoverTooltip(
        _ text: String,
        edge: HoverTooltipEdge = .above,
        pointingHandCursor: Bool = false
    ) -> some View {
        modifier(HoverTooltip(text: text, edge: edge, pointingHandCursor: pointingHandCursor))
    }
}

// test
