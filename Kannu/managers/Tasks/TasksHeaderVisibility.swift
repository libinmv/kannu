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

/// When the open notch's header shows its Tasks button (`TasksHeaderButton`), left of the
/// clipboard button.
///
/// Tasks belong with the timer. Where there is a timer tab (the timer on, shown as a tab), that tab
/// is their home: its task column has the list, search, the filter, Refresh and Time to log, so
/// the button would only repeat it there. The column hides while a timer runs, and then the button
/// shows on that tab, for the running task's clock, Up next and Time to log. The other tabs have
/// nothing to time and never show it. With no timer tab (the timer off, or shown as a popover)
/// there is no column, so the button shows on every tab. Never with tasks off: the button's view
/// builds `TasksManager`, which must not exist then.
///
/// Pure, in the logic target. `KannuHeader` passes its own state; the rules test pins that it does.
enum TasksHeaderVisibility {
    static func isShown(enableTasks: Bool, currentViewIsTimer: Bool, timerTabExists: Bool, timerIsRunning: Bool) -> Bool {
        guard enableTasks else { return false }
        guard timerTabExists else { return true }
        return currentViewIsTimer && timerIsRunning
    }
}
