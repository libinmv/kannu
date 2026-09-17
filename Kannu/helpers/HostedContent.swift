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

// A borderless panel must never have an NSHostingView as its `contentView`.
//
// When a hosting view *is* a window's content view, SwiftUI attaches a window-size bridge to it
// (`NSHostingView.updateRequiredBridges` checks `window.contentView === self`), and on every
// `windowDidLayout` that bridge clamps the window to the SwiftUI content's minimum and maximum
// size — `sizingOptions = []` does not switch it off. Kannu sizes these panels itself
// (`resizeWindows`, the HUD and lock-screen managers), so the two fight: Kannu sets a frame, the
// bridge sets another, the frame change invalidates the safe-area corner insets, and layout runs
// again until AppKit's update-constraints limit throws and the app aborts
// (`Kannu-2026-08-29-234024.ips`, `Kannu-2026-09-17-123317.ips`; docs/REGRESSIONS.md entry 17).
// Verified on the running notch window: bridge present as the content view, absent as a subview.
//
// Nesting the hosting view inside a plain container removes the bridge at its source, so no
// SwiftUI code path can resize the panel. Titled windows (Settings, onboarding) keep the direct
// assignment on purpose: there, content-driven window sizing is the feature.

/// The plain content view that holds a hosting view full-size. Transparent to hit-testing and
/// first-mouse: the hosting view underneath still decides both.
final class HostingContainerView: NSView {
    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        subviews.first?.acceptsFirstMouse(for: event) ?? false
    }
}

extension NSWindow {
    /// Installs `hostingView` as the panel's content, nested in a `HostingContainerView` so
    /// SwiftUI never drives the panel's size. Calling it again with the view already installed is
    /// a no-op, like assigning the same `contentView` twice.
    func setHostedContent<Content: View>(_ hostingView: NSHostingView<Content>) {
        if hostedContentView === hostingView { return }
        hostingView.sizingOptions = []
        let container = HostingContainerView(frame: NSRect(origin: .zero, size: contentRect(forFrameRect: frame).size))
        hostingView.removeFromSuperview()
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        contentView = container
    }

    /// The view `setHostedContent` installed, or the plain content view for a window that never
    /// used it. Use this wherever code used to read `contentView` back as a hosting view.
    var hostedContentView: NSView? {
        if let container = contentView as? HostingContainerView { return container.subviews.first }
        return contentView
    }
}
