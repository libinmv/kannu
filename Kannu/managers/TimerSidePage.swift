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

/// The pages of the timer tab's side column (`TimerSideColumn`): Tasks, the task order with a ▶ on
/// each row, and Presets, the preset cards. Tasks is the left-hand page, Presets the right-hand one.
///
/// Pure, in the logic target: which page the tab opens on, and what a two-finger swipe does.
enum TimerSidePage: String, CaseIterable, Identifiable, Equatable {
    case tasks
    case presets

    var id: String { rawValue }

    /// The page the timer tab opens on. Tasks when there is a Tasks page and Jira or GitLab is
    /// connected, since then the task order is what the user came to start from; otherwise
    /// Presets when there is a Presets page; otherwise Tasks, the only page left.
    static func initial(
        tasksAvailable: Bool,
        presetsAvailable: Bool,
        jiraConnected: Bool,
        gitlabConnected: Bool
    ) -> TimerSidePage {
        if tasksAvailable && (jiraConnected || gitlabConnected) { return .tasks }
        if presetsAvailable { return .presets }
        return .tasks
    }

    // MARK: - Swipe

    /// How far one gesture must travel sideways, in points, before it changes the page.
    static let swipeThreshold: Double = 40
    /// How much more sideways than vertical a gesture must be: a vertical scroll of the list that
    /// drifts sideways never changes the page.
    static let swipeDominance: Double = 1.5

    /// The page one gesture's accumulated deltas lead to, or nil when they lead nowhere new.
    ///
    /// `dx` and `dy` are in AppKit's natural-scrolling sense: fingers moving left give a negative
    /// `dx`, which brings in the right-hand page (Presets), as if the fingers pushed the column
    /// along; fingers moving right bring back Tasks. Only a clearly horizontal gesture of at least
    /// `threshold` points counts.
    static func swiped(
        from current: TimerSidePage,
        dx: Double,
        dy: Double,
        threshold: Double = swipeThreshold
    ) -> TimerSidePage? {
        guard abs(dx) >= threshold, abs(dx) > abs(dy) * swipeDominance else { return nil }
        let target: TimerSidePage = dx < 0 ? .presets : .tasks
        return target == current ? nil : target
    }
}

/// One two-finger gesture over the side column, from its first event to its last: the deltas so
/// far, and whether it already changed the page. A gesture changes the page at most once, so a
/// long swipe that overshoots and comes back never flips the column twice.
struct TimerSideSwipe: Equatable {
    /// Net sideways travel, signed.
    private(set) var dx: Double = 0
    /// Total vertical travel, unsigned.
    private(set) var dy: Double = 0
    private(set) var hasFlipped = false

    /// A new gesture began (or the last one ended): nothing counted yet.
    mutating func reset() {
        self = TimerSideSwipe()
    }

    /// Adds one event's deltas (natural-scrolling sense). Returns the page to show, at most once
    /// per gesture. `dx` stays signed, for the direction; `dy` counts all vertical travel, so a
    /// list scrolled down and back up in one gesture never nets out to a sideways swipe.
    mutating func add(dx: Double, dy: Double, current: TimerSidePage) -> TimerSidePage? {
        self.dx += dx
        self.dy += abs(dy)
        guard !hasFlipped, let page = TimerSidePage.swiped(from: current, dx: self.dx, dy: self.dy) else {
            return nil
        }
        hasFlipped = true
        return page
    }
}
