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

// A task's colour. Pure Foundation, so the logic target tests it; the views turn a `TaskColor` into
// a glass tint.
//
// A tag can have a colour, and each integration (local, Jira, GitLab) has one. A task takes the
// colour of its first tag, strictly: when that tag has no colour the task is glass, even if a later
// tag has one. Only a task with no tags at all takes its integration's colour.

/// The colour presets. Every one is a translucent glass finish; `glass` is the plain grey glass the
/// task rows had before colours existed, and the default for every tag and integration.
enum TaskColor: String, Codable, CaseIterable, Identifiable {
    case glass
    case white
    case orange
    case red
    case yellow
    case green
    case teal
    case blue
    case purple
    case pink

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .glass: return String(localized: "Glass")
        case .white: return String(localized: "White")
        case .orange: return String(localized: "Orange")
        case .red: return String(localized: "Red")
        case .yellow: return String(localized: "Yellow")
        case .green: return String(localized: "Green")
        case .teal: return String(localized: "Teal")
        case .blue: return String(localized: "Blue")
        case .purple: return String(localized: "Purple")
        case .pink: return String(localized: "Pink")
        }
    }

    var description: String {
        switch self {
        case .glass: return String(localized: "Plain grey glass, the default.")
        case .white: return String(localized: "White glass tint.")
        case .orange: return String(localized: "Orange glass tint.")
        case .red: return String(localized: "Red glass tint.")
        case .yellow: return String(localized: "Yellow glass tint.")
        case .green: return String(localized: "Green glass tint.")
        case .teal: return String(localized: "Teal glass tint.")
        case .blue: return String(localized: "Blue glass tint.")
        case .purple: return String(localized: "Purple glass tint.")
        case .pink: return String(localized: "Pink glass tint.")
        }
    }
}

/// Which colour a task shows.
enum TaskColoring {
    /// The key a tag's colour is stored under: the tag cleaned as `TaskItem` cleans tags, compared
    /// ignoring case, so "#Urgent" and "urgent" share one colour. Empty when nothing is left of it.
    static func key(for tag: String) -> String {
        TaskItem.cleanedTags([tag]).first?.lowercased() ?? ""
    }

    /// Strictly the first tag's colour, `.glass` when that tag has none. The integration's colour
    /// only when the task has no tags.
    static func color(tags: [String], tagColors: [String: TaskColor], integration: TaskColor) -> TaskColor {
        guard let first = tags.first else { return integration }
        return tagColors[key(for: first)] ?? .glass
    }

    /// The colour the user chose for the integration a task comes from.
    static func integration(for source: TaskSource, local: TaskColor, jira: TaskColor, gitlab: TaskColor) -> TaskColor {
        switch source {
        case .local: return local
        case .jira: return jira
        case .gitlab: return gitlab
        }
    }

    /// Tag colours as read from a file: keys cleaned with `key(for:)`, empty keys, unknown colour
    /// names and `.glass` (the default, never stored) dropped. Spellings that clean to one key keep
    /// the first in sorted order, so a load is deterministic.
    static func cleanedTagColors(_ raw: [String: String]) -> [String: TaskColor] {
        var result: [String: TaskColor] = [:]
        for (tag, name) in raw.sorted(by: { $0.key < $1.key }) {
            let key = key(for: tag)
            guard !key.isEmpty, result[key] == nil,
                  let color = TaskColor(rawValue: name), color != .glass else { continue }
            result[key] = color
        }
        return result
    }
}
