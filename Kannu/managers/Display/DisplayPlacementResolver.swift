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

/// Which displays Kannu puts itself on.
///
/// This replaces three settings that together could not say the obvious thing. `showOnAllDisplays`
/// defaulted to true, so every display got a window; every non-notch display then hid its island
/// until the pointer rested at the top edge for a second; and neither row said which display it
/// meant. A user with a MacBook and a monitor saw Kannu in the notch, nothing on the monitor, and no
/// way to tell why.
public enum DisplayPlacement: String, CaseIterable, Identifiable, Equatable {
    /// The default: the external display when one is plugged in, the built-in when none is.
    case externalTakesOver
    /// One Kannu per display.
    case allDisplays
    /// The built-in display only, whatever else is connected.
    case builtInOnly
    /// One named display.
    case chooseDisplay

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .externalTakesOver: return String(localized: "External display takes over")
        case .allDisplays: return String(localized: "All displays")
        case .builtInOnly: return String(localized: "Built-in display only")
        case .chooseDisplay: return String(localized: "A display I choose")
        }
    }

    public var description: String {
        switch self {
        case .externalTakesOver:
            return String(localized: "Kannu moves to the external display while one is connected, and returns to the built-in one when it is unplugged. With two or more external displays it follows the pointer.")
        case .allDisplays:
            return String(localized: "One Kannu on every display.")
        case .builtInOnly:
            return String(localized: "Kannu stays on the built-in display and ignores anything else you plug in.")
        case .chooseDisplay:
            return String(localized: "Kannu stays on the display you pick. If it is disconnected, Kannu falls back to the main display.")
        }
    }
}

/// Everything the placement decision needs about one screen, so the decision can be tested without
/// an `NSScreen` — and without the two monitors this was written on a Mac that does not have.
public struct ScreenFacts: Equatable {
    public let id: CGDirectDisplayID
    public let name: String
    public let isBuiltIn: Bool
    public let hasNotch: Bool
    public let frame: CGRect

    public init(id: CGDirectDisplayID, name: String, isBuiltIn: Bool, hasNotch: Bool = false, frame: CGRect = .zero) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.hasNotch = hasNotch
        self.frame = frame
    }
}

/// The one place that answers "where does Kannu go".
///
/// Pure, and keyed on `CGDirectDisplayID` rather than `localizedName`, because two identical
/// monitors share a name and every override in the app used to collapse them into one.
public enum DisplayPlacementResolver {

    /// The displays Kannu should occupy, in the order given.
    ///
    /// - Parameters:
    ///   - pointerOn: the display the pointer is on, used only when the mode is
    ///     `externalTakesOver` and two or more externals are connected — the only case with a
    ///     running cost, which is why it is the only case that tracks the pointer.
    ///   - mainScreen: the display to fall back to when a choice cannot be honoured.
    public static func screensToShowOn(
        _ screens: [ScreenFacts],
        mode: DisplayPlacement,
        chosenName: String? = nil,
        pointerOn: CGDirectDisplayID? = nil,
        mainScreen: CGDirectDisplayID? = nil
    ) -> [CGDirectDisplayID] {
        guard !screens.isEmpty else { return [] }
        let fallback = mainScreen.flatMap { id in screens.first { $0.id == id }?.id } ?? screens[0].id

        switch mode {
        case .allDisplays:
            return screens.map(\.id)

        case .builtInOnly:
            // No built-in at all means clamshell, or a Mac mini. Showing nothing would make the app
            // vanish with no way to get it back, so it falls back like `chooseDisplay` does.
            return [screens.first(where: \.isBuiltIn)?.id ?? fallback]

        case .chooseDisplay:
            guard let chosenName else { return [fallback] }
            return [screens.first { $0.name == chosenName }?.id ?? fallback]

        case .externalTakesOver:
            let externals = screens.filter { !$0.isBuiltIn }
            if externals.isEmpty {
                return [screens.first(where: \.isBuiltIn)?.id ?? fallback]
            }
            if externals.count == 1 {
                return [externals[0].id]
            }
            // Two or more externals: no way to guess which one the user is looking at, so follow the
            // pointer. A pointer on the built-in display still counts — that is where they are.
            if let pointerOn, screens.contains(where: { $0.id == pointerOn }) {
                return [pointerOn]
            }
            return [fallback]
        }
    }

    /// True when the placement needs the pointer tracked. Every other case costs nothing, and the
    /// monitor is installed and torn down on this answer alone.
    public static func needsPointerTracking(_ screens: [ScreenFacts], mode: DisplayPlacement) -> Bool {
        mode == .externalTakesOver && screens.filter { !$0.isBuiltIn }.count >= 2
    }
}
