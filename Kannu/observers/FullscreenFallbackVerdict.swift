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

/// Decides "is that window really fullscreen?" when the Accessibility grant is missing.
///
/// With the grant, `AXFullScreen` answers exactly. Without it the frame alone cannot: on a
/// notched Mac a *maximized* window and a native-fullscreen window both match the screen's safe
/// area, and assuming fullscreen once hid the notch for every maximized media window
/// (`FullscreenMediaDetector.isInNativeFullscreen`'s history). The distinguishing signal that
/// needs no grant is the menu bar: native fullscreen hides it, a maximized window never does.
///
/// Pure geometry over window records so the rule is testable; the detector feeds it one
/// `CGWindowList` snapshot converted to AppKit coordinates (origin bottom-left, y up).
///
/// Known residual: with "Automatically hide and show the menu bar" on, the menu bar is absent
/// even outside fullscreen, so a maximized now-playing window can still hide the notch under
/// `.nowPlayingOnly`. That trade is accepted — the alternative left fullscreen hiding dead for
/// every build whose re-sign dropped the grant.
enum FullscreenFallbackVerdict {
    /// One on-screen window, in AppKit coordinates. `layer` is the raw `kCGWindowLayer`.
    struct WindowRecord: Equatable {
        let layer: Int
        let frame: CGRect
    }

    /// The menu bar window's layer: `CGWindowLevelForKey(.mainMenuWindow)`. Passed in by the
    /// caller (and spelled out by tests) so this file stays free of AppKit.
    ///
    /// A window counts as that screen's menu bar when it sits on the menu-bar layer, hugs the
    /// screen's top edge, and is at least half the screen wide — status-item spill windows
    /// share the layer but never the width.
    static func menuBarIsVisible(onScreenWithFrame screenFrame: CGRect,
                                 windows: [WindowRecord],
                                 menuBarLayer: Int) -> Bool {
        windows.contains { window in
            window.layer == menuBarLayer
                && abs(window.frame.maxY - screenFrame.maxY) <= 2
                && window.frame.width >= screenFrame.width / 2
                && window.frame.intersects(screenFrame)
        }
    }

    /// The verdict for a window the detector already matched against the screen's safe area:
    /// genuinely fullscreen when it covers the whole screen frame (menu-bar band included —
    /// nothing maximized can), or when the menu bar is gone from that screen.
    static func isLikelyFullscreen(windowFrame: CGRect,
                                   screenFrame: CGRect,
                                   menuBarVisible: Bool) -> Bool {
        let coversWholeScreen = windowFrame.minX <= screenFrame.minX + 2
            && windowFrame.maxX >= screenFrame.maxX - 2
            && windowFrame.minY <= screenFrame.minY + 2
            && windowFrame.maxY >= screenFrame.maxY - 2
        return coversWholeScreen || !menuBarVisible
    }
}
