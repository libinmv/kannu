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

/// Text that, when it is clipped, slides into view while the pointer rests on it, once, and
/// settles back. One line slides sideways; several lines (a two-line title) slide up.
///
/// The layout is exactly a truncating `Text` with the same line limit: the truncated text defines
/// the frame, so nothing around it moves — a card's `ViewThatFits` sees the same heights hovered or
/// not. While revealing, the full text is drawn over it inside the same clipped frame and offset.
/// Whether the text is clipped is measured (the full copy's size against the frame), not guessed:
/// each size is written straight to state as it appears and changes (`SizeReader`). It used to
/// travel through two preference keys, whose `onPreferenceChange` reported zero sizes here and
/// never the real ones — so nothing ever counted as clipped and nothing slid.
///
/// Not `MarqueeText`: that is a wrap-around ticker for the music title, needing a fixed width and
/// running for as long as it is on screen. This runs only while hovered and only when clipped
/// (`HoverRevealMotion`), stays still under Reduce Motion, and does nothing at rest.
///
/// One hover source per control (docs/TOOLTIPS.md rule 3): it owns its `.onHover` unless a parent
/// passes `isActive` — a list row's one hover drives its title and caption together.
struct HoverRevealText: View {
    private let content: Text
    private let label: String?
    private let lines: Int
    private let activeOverride: Bool?

    @State private var isHovering = false
    @State private var frameSize: CGSize = .zero
    @State private var fullSize: CGSize = .zero
    @State private var offset: CGFloat = 0
    @State private var isRevealing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Its own hover.
    init(_ string: String, font: Font, lines: Int = 1) {
        self.init(Text(verbatim: string).font(font), label: string, lines: lines, active: nil)
    }

    /// Driven by a parent's hover.
    init(_ string: String, font: Font, lines: Int = 1, isActive: Bool) {
        self.init(Text(verbatim: string).font(font), label: string, lines: lines, active: isActive)
    }

    /// Styled text (a caption with an orange part), its own hover.
    init(_ text: Text, lines: Int = 1) {
        self.init(text, label: nil, lines: lines, active: nil)
    }

    /// Styled text, driven by a parent's hover.
    init(_ text: Text, lines: Int = 1, isActive: Bool) {
        self.init(text, label: nil, lines: lines, active: isActive)
    }

    private init(_ content: Text, label: String?, lines: Int, active: Bool?) {
        self.content = content
        self.label = label
        self.lines = max(1, lines)
        self.activeOverride = active
    }

    private var isActive: Bool { activeOverride ?? isHovering }
    private var isVertical: Bool { lines > 1 }
    private var overflow: CGFloat {
        isVertical ? fullSize.height - frameSize.height : fullSize.width - frameSize.width
    }

    /// What starts (or stops) a slide: the hover, and whether the text is clipped. The sizes can
    /// arrive after the hover does (text that appears under the pointer), so being measured as
    /// clipped starts the slide too, instead of a hover that found nothing to reveal.
    private var trigger: SlideTrigger {
        SlideTrigger(isActive: isActive, isClipped: HoverRevealMotion.shouldReveal(overflow: Double(overflow), reduceMotion: false))
    }

    var body: some View {
        content
            .lineLimit(lines)
            .opacity(isRevealing ? 0 : 1)
            .background(SizeReader(size: $frameSize))
            .overlay(alignment: .topLeading) {
                fullText
                    .background(SizeReader(size: $fullSize))
                    .offset(x: isVertical ? 0 : offset, y: isVertical ? offset : 0)
                    .opacity(isRevealing ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .clipped()
            .modifier(OwnHover(enabled: activeOverride == nil, isHovering: $isHovering))
            .task(id: trigger) { await slide() }
            .modifier(FullLabel(label: label))
    }

    /// The whole text: one unbroken line, or every line at the frame's width.
    @ViewBuilder
    private var fullText: some View {
        if isVertical {
            content.fixedSize(horizontal: false, vertical: true)
        } else {
            content.lineLimit(1).fixedSize()
        }
    }

    /// One slide per hover. Leaving hover changes the task's id (`trigger`), which cancels this one;
    /// the next (inactive) run settles everything back.
    private func slide() async {
        guard isActive, HoverRevealMotion.shouldReveal(overflow: Double(overflow), reduceMotion: reduceMotion) else {
            settle()
            return
        }
        try? await Task.sleep(for: .seconds(HoverRevealMotion.startDelay))
        guard !Task.isCancelled else { return }
        let distance = overflow
        let speed = isVertical ? HoverRevealMotion.verticalPointsPerSecond : HoverRevealMotion.horizontalPointsPerSecond
        let travel = HoverRevealMotion.travelDuration(distance: Double(distance), pointsPerSecond: speed)
        isRevealing = true
        withAnimation(.linear(duration: travel)) { offset = -distance }
        try? await Task.sleep(for: .seconds(travel + HoverRevealMotion.holdAtEnd))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: HoverRevealMotion.returnDuration)) { offset = 0 }
        try? await Task.sleep(for: .seconds(HoverRevealMotion.returnDuration))
        guard !Task.isCancelled else { return }
        isRevealing = false
    }

    private func settle() {
        guard isRevealing || offset != 0 else { return }
        if reduceMotion {
            offset = 0
        } else {
            withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
        }
        isRevealing = false
    }
}

private struct SlideTrigger: Equatable {
    let isActive: Bool
    let isClipped: Bool
}

/// Writes the size of the view it backs into state, as it appears and whenever it changes.
private struct SizeReader: View {
    @Binding var size: CGSize

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { size = proxy.size }
                .onChange(of: proxy.size) { _, new in size = new }
        }
    }
}

/// The view's own `.onHover`, only when no parent drives it.
private struct OwnHover: ViewModifier {
    let enabled: Bool
    @Binding var isHovering: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onHover { isHovering = $0 }
        } else {
            content
        }
    }
}

/// VoiceOver reads the whole string once, however much of it shows.
private struct FullLabel: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: label))
        } else {
            content
        }
    }
}
