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

/// Where hover may open the notch on a MacBook display: the hardware notch itself, and nothing
/// around it. The hover area also takes in the +8 pt growth, the music and agent wings (which sit
/// over menu-bar items) and the agent band below the notch (which sits over window toolbars and
/// tabs); resting there must not open a panel over what the user was about to click.
enum NotchInteractionGeometry {
    /// The hardware notch in screen coordinates, or nil on a screen without one.
    ///
    /// Width mirrors `getClosedNotchSize` in `sizing/matters.swift`: the screen minus the menu-bar
    /// areas either side of the notch (`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`),
    /// plus the 4 pt it draws. Centred like the window Kannu draws it in (`resizeWindow`), so the
    /// rect is the notch Kannu actually draws over the hardware one. Height is `safeAreaInsets.top`,
    /// measured down from the top edge.
    static func physicalNotchRect(screenFrame: CGRect, leftAreaWidth: CGFloat, rightAreaWidth: CGFloat,
                                  topInset: CGFloat) -> CGRect? {
        guard topInset > 0 else { return nil }
        let width = screenFrame.width - leftAreaWidth - rightAreaWidth + 4
        guard width > 0 else { return nil }
        return CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - topInset,
                      width: width, height: topInset)
    }

    /// Whether a pointer location is on the hardware notch. The top edge is inclusive: the pointer
    /// pinned against the top of the screen reports `y == screenFrame.maxY`, and that counts.
    static func isOnPhysicalNotch(_ point: CGPoint, notch: CGRect) -> Bool {
        point.x >= notch.minX && point.x <= notch.maxX && point.y >= notch.minY && point.y <= notch.maxY
    }
}
