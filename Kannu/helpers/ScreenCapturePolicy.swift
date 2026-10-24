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

import Foundation

/// What a window is, for screen capture. Said once, when the window registers with
/// `ScreenCaptureVisibilityManager`.
enum ScreenCaptureScope: Int {
    /// The notch and everything drawn as part of it: the music and timer satellites, the
    /// lock-screen widgets, the fullscreen artwork.
    case notch
    /// A standalone window: Brain (the Settings window), onboarding, the clipboard, the Screen Assistant.
    case panel
}

/// Which Kannu windows ask macOS to be left out of screenshots and recordings
/// (`NSWindow.sharingType = .none`).
///
/// A request, not a guarantee: Apple documents `.none` as a legacy value not to be relied on to
/// keep content out of a capture, and some capture tools ignore it. It is still the only per-window
/// signal an app has; excluding windows is otherwise the capturing app's choice (ScreenCaptureKit's
/// content filter). The descriptions below say so. The old toggle used the same mechanism.
///
/// The default shows everything, as the old toggle's default did. "Hide the notch" keeps the notch
/// and its satellites out of captures while Brain and the other panels stay capturable, which the
/// old toggle could not do: it ignored each window's scope and hid them all together. This setting
/// cannot affect Mission Control's previews or the Space-switch transition; those are drawn by
/// WindowServer, not captured.
///
/// Foundation-only so the logic target can pin the rule; the app target adds
/// `Defaults.Serializable` next to its key.
enum ScreenCaptureVisibility: String, CaseIterable, Identifiable {
    case hideNotch
    case hideEverything
    case showEverything

    var id: String { rawValue }

    func hides(_ scope: ScreenCaptureScope) -> Bool {
        switch self {
        case .hideNotch: return scope == .notch
        case .hideEverything: return true
        case .showEverything: return false
        }
    }

    var localizedName: String {
        switch self {
        case .hideNotch: return String(localized: "Hide the notch")
        case .hideEverything: return String(localized: "Hide everything")
        case .showEverything: return String(localized: "Show everything")
        }
    }

    var description: String {
        switch self {
        case .hideNotch:
            return String(localized: "Asks macOS to leave the notch, its music and timer controls and the lock-screen widgets out of screenshots and recordings. Some capture tools ignore this. Brain and other windows are captured.")
        case .hideEverything:
            return String(localized: "Asks macOS to leave every Kannu window, Brain included, out of screenshots and recordings. Some capture tools ignore this.")
        case .showEverything:
            return String(localized: "Kannu appears in screenshots and recordings.")
        }
    }
}
