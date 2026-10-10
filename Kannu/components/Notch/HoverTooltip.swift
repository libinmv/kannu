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

/// How far from the control the bubble is placed.
private enum HoverTooltipPlacement {
    /// 22pt from the control's anchoring edge. Clears a ~14pt glyph, and the callers that wrap a
    /// whole row (`clickableSession`) rely on the bubble rendering inside that row.
    case fixedOffset
    /// 8pt clear of the control's own edge, whatever its size. Used for the shared icon buttons
    /// (30–54pt), where a fixed 22pt would put the bubble on top of the glyph.
    case clearOfControl
}

/// The bubble itself. Both placements draw exactly this.
private struct HoverTooltipBubble: View {
    let text: String

    var body: some View {
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
    }
}

/// Shows the bubble after a short delay while `isHovering` is true. It owns no hover handler of
/// its own: the caller's single `.onHover` drives it, so a control never has two hover sources.
private struct HoverTooltipPresenter: ViewModifier {
    let text: String
    let edge: HoverTooltipEdge
    let alignment: HorizontalAlignment
    let placement: HoverTooltipPlacement
    let isHovering: Bool

    @State private var hovering = false
    @State private var visible = false
    @State private var showWork: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .onChange(of: isHovering) { _, newValue in
                update(hovering: newValue)
            }
            .overlay(alignment: overlayAlignment) {
                if visible {
                    positioned(HoverTooltipBubble(text: text))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(100)
                }
            }
    }

    private var overlayAlignment: Alignment {
        switch placement {
        case .fixedOffset:
            Alignment(horizontal: alignment, vertical: edge == .above ? .bottom : .top)
        case .clearOfControl:
            Alignment(horizontal: alignment, vertical: edge == .above ? .top : .bottom)
        }
    }

    @ViewBuilder
    private func positioned(_ bubble: HoverTooltipBubble) -> some View {
        switch (placement, edge) {
        case (.fixedOffset, .above):
            bubble.offset(y: -22)
        case (.fixedOffset, .below):
            bubble.offset(y: 22)
        case (.clearOfControl, .above):
            // The bubble's bottom sits 8pt above the control's top edge.
            bubble.alignmentGuide(.top) { $0[.bottom] + 8 }
        case (.clearOfControl, .below):
            // The bubble's top sits 8pt below the control's bottom edge.
            bubble.alignmentGuide(.bottom) { $0[.top] - 8 }
        }
    }

    private func update(hovering isHovering: Bool) {
        hovering = isHovering
        // Cancel the pending show on every edge: an uncancelled asyncAfter from an
        // earlier hover-in survived a hover-out and fired for the next hover-in early,
        // which is exactly the brush-past flash the delay exists to prevent.
        showWork?.cancel()
        if isHovering {
            // Short delay so brushing past a control does not flash a bubble.
            let work = DispatchWorkItem {
                if hovering { withAnimation(.easeOut(duration: 0.12)) { visible = true } }
            }
            showWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        } else {
            showWork = nil
            withAnimation(.easeOut(duration: 0.1)) { visible = false }
        }
    }
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
    let alignment: HorizontalAlignment
    /// Set the pointing-hand cursor while hovered. Callers that used to do this with their own
    /// `.onHover` must use this instead: two hover handlers on one control fight, and the tooltip
    /// stops appearing.
    let pointingHandCursor: Bool

    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                hovering = isHovering
                if pointingHandCursor {
                    if isHovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
            }
            .modifier(HoverTooltipPresenter(
                text: text,
                edge: edge,
                alignment: alignment,
                placement: .fixedOffset,
                isHovering: hovering
            ))
    }
}

extension View {
    /// Notch-safe replacement for `.help(...)`, which never renders in this app.
    /// The bubble is an overlay, so it is subject to any ancestor clip — a `ScrollView` or
    /// `.clipped()` will swallow whatever falls outside the content bounds. Choose `edge` by where
    /// the control sits in its container, not by aesthetics: a control at the top of a scroll view
    /// must open `.below`, or the bubble lands in the clipped region and is never seen.
    /// - Parameter edge: `.above` for controls low in their container, `.below` for those near the top.
    /// - Parameter alignment: which side of the control the bubble lines up with. `.trailing` grows
    ///   the bubble leftwards; pass `.leading` for a control at the left edge of its window.
    func hoverTooltip(
        _ text: String,
        edge: HoverTooltipEdge = .above,
        alignment: HorizontalAlignment = .trailing,
        pointingHandCursor: Bool = false
    ) -> some View {
        modifier(HoverTooltip(
            text: text,
            edge: edge,
            alignment: alignment,
            pointingHandCursor: pointingHandCursor
        ))
    }

    /// The hover-driven variant, for a control that already has its own `.onHover` (it needs the
    /// hover state for its highlight). It adds no hover handler: pass that control's hover state
    /// as `isHovering`, so the control keeps exactly one hover source. The bubble sits 8pt clear of
    /// the control's edge, so it never covers a large glyph.
    func hoverTooltip(
        _ text: String,
        edge: HoverTooltipEdge = .above,
        alignment: HorizontalAlignment = .trailing,
        isHovering: Bool
    ) -> some View {
        modifier(HoverTooltipPresenter(
            text: text,
            edge: edge,
            alignment: alignment,
            placement: .clearOfControl,
            isHovering: isHovering
        ))
    }

    /// Tooltip plus accessibility label for a shared icon-only button. The tooltip text doubles as
    /// the label VoiceOver reads, so the two can never disagree. `nil` leaves the view untouched,
    /// for the rare caller (the lock screen) that has no notch to draw a bubble in.
    @ViewBuilder
    func iconButtonTooltip(
        _ text: String?,
        edge: HoverTooltipEdge = .above,
        alignment: HorizontalAlignment = .trailing,
        isHovering: Bool
    ) -> some View {
        if let text {
            self
                .hoverTooltip(text, edge: edge, alignment: alignment, isHovering: isHovering)
                .accessibilityLabel(text)
        } else {
            self
        }
    }
}
