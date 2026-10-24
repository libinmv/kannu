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

/// The open notch closes on a vertical trackpad scroll (`PanGesture`, `ContentView`'s close
/// gesture), which is the same gesture as scrolling a list or a note's text down. A view whose
/// vertical scroll is its own marks itself with `.ownsVerticalScroll()`, and the notch's scroll
/// monitor hands every event whose pointer is inside one of those views back to it untouched.
///
/// Decided by geometry, at the moment the event arrives, off the owner's live `NSView` frame — the
/// `ScrollWheelMonitor.sidewaysScrollOwners` idiom. The `.onHover` suppression tokens these views
/// also set reach the gesture only through `@State` and a re-render, which a scroll can beat (a
/// list that appeared under a pointer that has not moved never hovers at all), so they are the
/// second guard, not the first (docs/REGRESSIONS.md entry 21).
enum VerticalScrollOwnership {
    /// The views marked `.ownsVerticalScroll()`, while they are on screen. Weak, so a view that goes
    /// away without `dismantleNSView` is forgotten rather than kept.
    @MainActor static let owners = NSHashTable<NSView>.weakObjects()

    /// Whether `screenPoint` falls inside an owner that lives in `window`.
    @MainActor static func ownsScroll(at screenPoint: NSPoint, in window: NSWindow) -> Bool {
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        return owners.allObjects.contains { owner in
            guard owner.window === window, !owner.isHiddenOrHasHiddenAncestor else { return false }
            return owner.bounds.contains(owner.convert(windowPoint, from: nil))
        }
    }
}

extension View {
    /// This view's vertical scroll is its own: the open notch's swipe-to-close stands aside over it.
    func ownsVerticalScroll() -> some View {
        background(VerticalScrollOwnerView())
    }
}

private struct VerticalScrollOwnerView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        VerticalScrollOwnership.owners.add(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        VerticalScrollOwnership.owners.remove(nsView)
    }

    /// Only its frame matters: clicks and scrolls go to the content in front of it.
    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
