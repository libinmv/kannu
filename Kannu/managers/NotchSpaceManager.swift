/*
 * Kannu (കണ്ണ്)
 * Copyright (C) 2024-2026 Kannu Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Kannu (കണ്ണ്)
 * See NOTICE for details.
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

class NotchSpaceManager {
    static let shared = NotchSpaceManager()
    /// Kannu's own top-level space (absolute level Int32.max), shown above every space. Every notch
    /// window lives here and in no other space, on every hide option:
    /// `AppDelegate.pinNotchWindows` adds it and takes it out of the desktop and fullscreen spaces.
    let notchSpace: CGSSpace
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {
        notchSpace = CGSSpace(level: 2147483647) // Max level
    }
}
