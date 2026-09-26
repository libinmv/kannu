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

/// Whether the closed notch hides itself, and how tall it is when it does not.
///
/// These two rules used to live only inside `KannuViewModel` — one as a Combine graph, one as a
/// one-line computed property — where neither could be tested, because that type is `@MainActor`
/// and pulls in SwiftUI and `NSScreen`. Both rules had the same defect: they treated *"Kannu does
/// not know which screen it is on yet"* as a fact about the hardware. The first left
/// `hideOnClosed` latched at its initial value because a nil screen was filtered out of the
/// publisher entirely; the second read a nil screen as "this display has no notch". Together they
/// produced an unpainted, zero-height, non-interactive notch on a notched MacBook, for the whole
/// session, while the app was otherwise perfectly healthy.
///
/// So the distinction this type exists to make is: **an unknown screen is not a notchless screen.**
enum ClosedNotchVisibility {
    /// Whether the closed notch should hide because a fullscreen app owns its screen.
    ///
    /// - Parameters:
    ///   - detectionEnabled: the user's `enableFullscreenMediaDetection` setting.
    ///   - screen: the display Kannu believes it is on, or `nil` before that is resolved.
    ///   - fullscreenStatus: the detector's per-screen verdicts, keyed by display name.
    ///
    /// A `nil` screen, or a screen the detector has not reported on, answers `false`. Hiding is the
    /// exception that needs evidence; showing is the default. Answering `true` without evidence is
    /// what made the app look broken.
    static func shouldHideClosedNotch(
        detectionEnabled: Bool,
        screen: String?,
        fullscreenStatus: [String: Bool]
    ) -> Bool {
        guard detectionEnabled, let screen else { return false }
        return fullscreenStatus[screen] ?? false
    }

    /// The height the closed notch occupies.
    ///
    /// - Parameters:
    ///   - hideOnClosed: the verdict from `shouldHideClosedNotch`.
    ///   - topSafeAreaInset: the resolved screen's top inset; `nil` when no screen resolved at all.
    ///   - closedHeight: the notch's normal closed height.
    ///
    /// Collapses to zero only where there is genuinely nothing to occupy — a notchless screen with
    /// a fullscreen app on it. A screen that cannot be resolved keeps its height: that is a
    /// bookkeeping gap, and guessing "notchless" from it removes the hover target too, so the user
    /// cannot even bring the notch back by pointing at it.
    static func effectiveClosedNotchHeight(
        hideOnClosed: Bool,
        topSafeAreaInset: CGFloat?,
        closedHeight: CGFloat
    ) -> CGFloat {
        guard let topSafeAreaInset else { return closedHeight }
        let noNotchAndFullscreen = hideOnClosed && topSafeAreaInset <= 0
        return noNotchAndFullscreen ? 0 : closedHeight
    }
}
