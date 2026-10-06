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

/// The Task list's Source filter: All | Local | Jira | GitLab. Stored in Defaults
/// (`tasksListSourceFilter`); the `Defaults.Serializable` conformance lives beside the key.
enum TaskSourceFilter: String, CaseIterable, Identifiable {
    case all
    case local
    case jira
    case gitlab

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .all: return String(localized: "All")
        case .local: return String(localized: "Local")
        case .jira: return String(localized: "Jira")
        case .gitlab: return String(localized: "GitLab")
        }
    }

    var description: String {
        switch self {
        case .all: return String(localized: "Tasks from every source.")
        case .local: return String(localized: "Tasks you added.")
        case .jira: return String(localized: "Your Jira issues.")
        case .gitlab: return String(localized: "Your GitLab issues and merge requests.")
        }
    }
}

/// The Task list's Status filter. Every listed task is To Do or In Progress: done ones are in Done
/// and hidden.
enum TaskStatusFilter: String, CaseIterable, Identifiable {
    case toDoAndInProgress
    case toDo
    case inProgress

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .toDoAndInProgress: return String(localized: "To Do + In Progress")
        case .toDo: return String(localized: "To Do")
        case .inProgress: return String(localized: "In Progress")
        }
    }

    var description: String {
        switch self {
        case .toDoAndInProgress: return String(localized: "Every open task.")
        case .toDo: return String(localized: "Tasks not started yet.")
        case .inProgress: return String(localized: "Tasks under way.")
        }
    }
}

/// Where one task stands.
enum TaskStatusFacet: Equatable {
    case toDo
    case inProgress
}

/// The Task list's four filters together.
struct TaskFilter: Equatable {
    var source: TaskSourceFilter = .all
    /// `TaskFacets.anyProject`, `TaskFacets.noProject`, or a project as `TaskFacets.project` names it.
    var project: String = TaskFacets.anyProject
    var status: TaskStatusFilter = .toDoAndInProgress
    /// `TaskFacets.anyTag`, or a tag (matched ignoring case).
    var tag: String = TaskFacets.anyTag

    static let all = TaskFilter()

    var isNarrowing: Bool { self != .all }
}

/// What the Task list filters on, worked out from a task alone. Pure, so the logic target tests it.
///
/// - **Project**: a Jira key's prefix ("PROJ" for PROJ-123); a GitLab item's path ("group/app" for
///   group/app#45 or group/app!12), or the key "#project:42" from its project id when the server
///   sent no path, shown as "Project 42" (`projectName`); none for a local task.
/// - **Status**: a remote task's status category ("indeterminate" is In Progress, anything else To
///   Do); in a file written before categories, a merge request is In Progress. A local task is In
///   Progress once it has any recorded time.
/// - **Tags**: the user's own, compared ignoring case.
enum TaskFacets {
    static let anyProject = ""
    /// The Project filter's "No project": local tasks. Starts with "#", which no Jira key or GitLab
    /// path does.
    static let noProject = "#none"
    /// A GitLab project known only by its id: the key is this prefix and the id, so the stored
    /// filter never depends on the language the label was shown in.
    static let projectIDPrefix = "#project:"
    static let anyTag = ""

    // MARK: - Project

    static func project(for task: TaskItem) -> String? {
        guard let remote = task.remote else { return nil }
        switch task.source {
        case .local:
            return nil
        case .jira:
            guard let dash = remote.key.lastIndex(of: "-"), dash > remote.key.startIndex else { return nil }
            return String(remote.key[..<dash])
        case .gitlab:
            if let marker = remote.key.lastIndex(where: { $0 == "#" || $0 == "!" }), marker > remote.key.startIndex {
                return String(remote.key[..<marker])
            }
            return remote.gitlabProjectID.map { projectIDPrefix + String($0) }
        }
    }

    /// How a project key reads in the Project picker: "Project 42" for an id-only GitLab project,
    /// the key itself otherwise.
    static func projectName(_ key: String) -> String {
        guard key.hasPrefix(projectIDPrefix), let id = Int(key.dropFirst(projectIDPrefix.count)) else { return key }
        return String(localized: "Project \(id)")
    }

    /// A stored Project filter in today's form. Before the key, an id-only project was stored as
    /// its English label, "Project 42"; that reads as "#project:42" now. No Jira key prefix or
    /// GitLab path contains a space, so the old label can name nothing else.
    static func normalizedProjectFilter(_ stored: String) -> String {
        let legacy = "Project "
        guard stored.hasPrefix(legacy), let id = Int(stored.dropFirst(legacy.count)), id >= 0 else { return stored }
        return projectIDPrefix + String(id)
    }

    // MARK: - Status

    static func status(for task: TaskItem) -> TaskStatusFacet {
        guard let remote = task.remote else {
            return task.segments.isEmpty ? .toDo : .inProgress
        }
        if let category = remote.statusCategory {
            return category == inProgressCategory ? .inProgress : .toDo
        }
        return remote.gitlabKind == .mergeRequest ? .inProgress : .toDo
    }

    /// Jira's status-category key for In Progress.
    static let inProgressCategory = "indeterminate"
    static let toDoCategory = "new"

    /// A GitLab item's status category: a merge request is In Progress; an issue is In Progress when
    /// a label says so ("In progress", "doing", "WIP", "workflow::in-progress"), To Do otherwise.
    static func gitlabCategory(kind: GitLabKind, labels: [String]) -> String {
        if kind == .mergeRequest { return inProgressCategory }
        return labels.contains(where: isInProgressLabel) ? inProgressCategory : toDoCategory
    }

    /// "In progress", "in-progress", "Doing", "WIP", and the same after a scope ("workflow::doing").
    static func isInProgressLabel(_ label: String) -> Bool {
        let scoped = label.components(separatedBy: "::").last ?? label
        let words = scoped.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
        return ["in progress", "doing", "wip"].contains(words)
    }

    /// The labels a task keeps: one line each, at most 20, each at most 50 characters.
    static func keptLabels(_ labels: [String]) -> [String] {
        Array(labels.compactMap { TaskItem.cleanedTitle($0).map { String($0.prefix(50)) } }.prefix(20))
    }

    // MARK: - Matching

    static func matches(_ task: TaskItem, filter: TaskFilter) -> Bool {
        switch filter.source {
        case .all: break
        case .local: guard task.source == .local else { return false }
        case .jira: guard task.source == .jira else { return false }
        case .gitlab: guard task.source == .gitlab else { return false }
        }
        switch filter.project {
        case anyProject: break
        case noProject: guard project(for: task) == nil else { return false }
        default: guard project(for: task) == filter.project else { return false }
        }
        switch filter.status {
        case .toDoAndInProgress: break
        case .toDo: guard status(for: task) == .toDo else { return false }
        case .inProgress: guard status(for: task) == .inProgress else { return false }
        }
        if filter.tag != anyTag {
            let wanted = filter.tag.lowercased()
            guard task.tags.contains(where: { $0.lowercased() == wanted }) else { return false }
        }
        return true
    }

    /// The tasks a Task list move counts: those `listed` already shows that also pass `filter`, so a
    /// move or a drag never shifts a task the user cannot see.
    static func listed(_ listed: @escaping TaskOrdering.Listed, filter: TaskFilter) -> TaskOrdering.Listed {
        { listed($0) && matches($0, filter: filter) }
    }

    // MARK: - What the filters offer

    /// The projects present as keys, sorted by how they read, ignoring case.
    static func projects(in tasks: [TaskItem]) -> [String] {
        let keys = Set(tasks.compactMap(project(for:)))
        return keys.sorted { projectName($0).localizedCaseInsensitiveCompare(projectName($1)) == .orderedAscending }
    }

    /// Whether any task has no project, so "No project" means something.
    static func hasTaskWithoutProject(in tasks: [TaskItem]) -> Bool {
        tasks.contains { project(for: $0) == nil }
    }

    /// The tags present, first spelling of each, sorted ignoring case.
    static func tags(in tasks: [TaskItem]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tasks.flatMap(\.tags) where seen.insert(tag.lowercased()).inserted {
            result.append(tag)
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// How many are To Do and how many In Progress: the "12 to do · 3 in progress" on the Task list row.
    static func counts(_ tasks: [TaskItem]) -> (toDo: Int, inProgress: Int) {
        let inProgress = tasks.filter { status(for: $0) == .inProgress }.count
        return (tasks.count - inProgress, inProgress)
    }
}
