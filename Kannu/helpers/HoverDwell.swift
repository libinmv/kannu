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

/// Dwell gate for the hidden-edge hover poll: the pointer must rest inside the entry rect for
/// `minimum` seconds before the island slides in, so a pointer merely crossing the top edge on its
/// way to a browser tab does not summon it. Foundation-only so the logic test target can pin it.
struct HoverDwell {
    private(set) var insideSince: Date?

    /// Inside on this tick. The first entry time is kept across later ticks.
    mutating func noteInside(at now: Date) {
        if insideSince == nil { insideSince = now }
    }

    /// Outside on this tick (or the hover was consumed): the clock starts over next time.
    mutating func noteOutside() { insideSince = nil }

    func isSatisfied(at now: Date, minimum: TimeInterval) -> Bool {
        guard let insideSince else { return false }
        return now.timeIntervalSince(insideSince) >= minimum
    }
}
