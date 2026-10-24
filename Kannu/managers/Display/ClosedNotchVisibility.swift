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

    /// Whether a window has fallen off the space the user is on and must be put back. Since
    /// 2026-10-22 this serves the clipboard panel, which belongs on the managed spaces; the notch
    /// lives in its own space and uses `notchSpaceRepair`.
    ///
    /// The notch is a `.canJoinAllSpaces` panel, so it belongs on every space, fullscreen ones
    /// included. Around a sleep or a lock, macOS can reset **every** app's all-spaces windows to just
    /// the desktop and whichever fullscreen space was current (measured 2026-09-30: Kannu's notch,
    /// Slack, Claude and Control Center windows all left at the same two of eleven spaces). The
    /// window stays ordered in and fully opaque, so nothing in Kannu notices, yet in any other
    /// fullscreen app there is simply no notch until relaunch. Ordering it front again, or
    /// re-assigning its collection behaviour, does not bring the membership back; re-adding it to
    /// the spaces does.
    ///
    /// Only a window that should be on screen qualifies: one hidden for the lock screen is off
    /// every space on purpose.
    static func shouldRejoinSpaces(
        isOnActiveSpace: Bool,
        isOrderedIn: Bool,
        hiddenForLock: Bool,
        screenLocked: Bool
    ) -> Bool {
        !isOnActiveSpace && isOrderedIn && !hiddenForLock && !screenLocked
    }

    /// What to do so a notch window lives in Kannu's notch space and in no other space.
    enum NotchSpaceRepair: Equatable {
        case none
        /// Not in the notch space: add it there, and only once that is confirmed leave the rest.
        case joinNotchSpace
        /// In the notch space and on these other spaces too: leave them.
        case leaveOtherSpaces(Set<UInt64>)
        /// In the notch space, ordered in, yet not on screen: the notch space is not showing it.
        /// Being seen beats staying still, so it goes back on every managed space (2026-09-30).
        case fallBackToManagedSpaces
    }

    /// The notch's space repair, decided from what WindowServer reports, never from
    /// `NSWindow.isOnActiveSpace`, which is false by design for a window that lives only in the
    /// notch space. Asking it put the notch back on every desktop and fullscreen space at the first
    /// switch after each launch (2026-10-22).
    ///
    /// The notch space is shown above every space, so a window there shows everywhere. Another
    /// membership adds a copy of the notch to that space, which is what this repair removes. Any
    /// space other than the notch space counts, tile sub-spaces of a fullscreen space included, so
    /// no list of managed spaces is needed.
    ///
    /// `notchSpaceUnseen` marks a window the notch space failed to show at an earlier check (a
    /// fallback, or a strip that left it off screen). Its other spaces are then what keep it visible,
    /// so they stay until a wake, unlock or reposition clears the mark and the strip is tried again;
    /// otherwise the fallback and the strip would undo each other at every check.
    ///
    /// A window hidden for the lock screen, or not ordered in, is left alone.
    static func notchSpaceRepair(
        memberships: Set<UInt64>,
        notchSpaceID: UInt64,
        isOrderedIn: Bool,
        isOnScreen: Bool,
        notchSpaceUnseen: Bool,
        hiddenForLock: Bool,
        screenLocked: Bool
    ) -> NotchSpaceRepair {
        guard isOrderedIn, !hiddenForLock, !screenLocked else { return .none }
        guard memberships.contains(notchSpaceID) else { return .joinNotchSpace }
        guard isOnScreen else { return .fallBackToManagedSpaces }
        let others = memberships.subtracting([notchSpaceID])
        guard !others.isEmpty, !notchSpaceUnseen else { return .none }
        return .leaveOtherSpaces(others)
    }
}
