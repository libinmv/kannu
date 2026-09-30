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

import CoreGraphics
import Foundation

/// Where the clipboard panel opens, as pure geometry (no AppKit, so it is testable).
///
/// The bug this replaces (2026-09-30): the panel restored any saved origin that merely
/// *intersected* `NSScreen.main`'s visible frame — and `NSScreen.main` is the key window's
/// screen, not the one the user is looking at. Summoned over a fullscreen app on another
/// display, the panel opened on the wrong screen or almost entirely off-screen: running, and
/// not visible. A one-pixel overlap counted as "on screen", and `(0, 0)` — a legitimate
/// bottom-left origin — doubled as the "nothing saved" sentinel.
enum ClipboardPanelPlacement {
    /// How much of the panel must land inside the screen, per axis, before a saved origin is
    /// trusted; anything less and the panel is effectively invisible or ungrabbable.
    static let minimumVisible: CGFloat = 60

    /// The index of the frame under the pointer — the screen the user is actually looking at.
    /// `nil` when the pointer is on no known screen (mid display reconfiguration); the caller
    /// falls back to its default screen.
    static func screenIndex(under pointer: CGPoint, screenFrames: [CGRect]) -> Int? {
        screenFrames.firstIndex { $0.contains(pointer) }
    }

    /// The origin to open at on the target screen: the saved origin when at least
    /// `minimumVisible` of the panel in each axis lands inside `visibleFrame`, otherwise the
    /// centre of `visibleFrame`.
    static func origin(saved: CGPoint?, panelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        if let saved {
            let visible = CGRect(origin: saved, size: panelSize).intersection(visibleFrame)
            if visible.width >= Swift.min(minimumVisible, panelSize.width),
               visible.height >= Swift.min(minimumVisible, panelSize.height) {
                return saved
            }
        }
        return CGPoint(x: (visibleFrame.midX - panelSize.width / 2).rounded(),
                       y: (visibleFrame.midY - panelSize.height / 2).rounded())
    }
}
