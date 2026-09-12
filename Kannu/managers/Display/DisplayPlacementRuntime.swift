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
import Defaults

/// The thin layer between live `NSScreen`s and the pure `DisplayPlacementResolver`.
///
/// Nothing is stored: every answer is computed from the screens as they are right now. A cached set
/// of displays is exactly what goes stale when a dock wakes and fires four configuration changes in a
/// row, and `NSScreen` objects are not promised to survive a reconfiguration — so identity lives in
/// `CGDirectDisplayID`, which is stable, and the pointer is read when asked rather than tracked.
@MainActor
enum DisplayPlacementRuntime {

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    static func facts(for screens: [NSScreen] = NSScreen.screens) -> [ScreenFacts] {
        screens.compactMap { screen in
            guard let id = displayID(for: screen) else { return nil }
            return ScreenFacts(
                id: id,
                name: screen.localizedName,
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                hasNotch: screen.safeAreaInsets.top > 0,
                frame: screen.frame
            )
        }
    }

    /// The display the pointer is on, or nil when it cannot be placed.
    static func pointerDisplayID() -> CGDirectDisplayID? {
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else { return nil }
        return displayID(for: screen)
    }

    static func mainDisplayID() -> CGDirectDisplayID? {
        (NSScreen.main ?? NSScreen.screens.first).flatMap(displayID(for:))
    }

    /// The displays Kannu should occupy right now.
    static func activeDisplayIDs(mode: DisplayPlacement = Defaults[.displayPlacement]) -> [CGDirectDisplayID] {
        DisplayPlacementResolver.screensToShowOn(
            facts(),
            mode: mode,
            chosenName: KannuViewCoordinator.shared.preferredScreen,
            pointerOn: pointerDisplayID(),
            mainScreen: mainDisplayID()
        )
    }

    /// The single screen Kannu belongs on, for the modes that use one window.
    static func activeScreen(mode: DisplayPlacement = Defaults[.displayPlacement]) -> NSScreen? {
        guard let id = activeDisplayIDs(mode: mode).first else { return nil }
        return NSScreen.screens.first { displayID(for: $0) == id }
    }

    static func needsPointerTracking(mode: DisplayPlacement = Defaults[.displayPlacement]) -> Bool {
        DisplayPlacementResolver.needsPointerTracking(facts(), mode: mode)
    }
}

extension DisplayPlacement {
    /// Whether Kannu runs one window per display (the `windows`/`viewModels` dictionaries) or a
    /// single window on a resolved screen.
    ///
    /// Keyed on the *mode*, never on how many displays happen to be connected: if the count decided
    /// this, plugging a second monitor in would move Kannu between two different window lifecycles
    /// mid-flight, which is a worse bug than the one being fixed.
    var usesOneWindowPerDisplay: Bool { self == .allDisplays }
}
