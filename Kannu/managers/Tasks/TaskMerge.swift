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

/// One issue (or GitLab merge request) as a source returned it, already reduced to what a task keeps.
struct RemoteIssue: Equatable {
    /// The source's stable id (a Jira issue id; a GitLab global id with its kind), never the key: a
    /// key changes when an issue moves.
    var remoteID: String
    var key: String
    var title: String
    var status: String
    var isDoneRemotely: Bool
    var estimateSeconds: Int?
    var spentSeconds: Int?
    /// GitLab only.
    var gitlab: GitLabRef? = nil
    /// "new", "indeterminate" or "done" (`RemoteTaskInfo.statusCategory`).
    var statusCategory: String? = nil
    /// The item's labels; nil when the source sent none.
    var labels: [String]? = nil
    /// The standard facts (`RemoteTaskInfo`'s of the same names), refreshed on every sync.
    var weight: Int? = nil
    var milestone: String? = nil
    var dueDate: Date? = nil
    var assignee: String? = nil
    var parentTitle: String? = nil
    var priority: String? = nil
    var issueType: String? = nil
    var updatedAt: Date? = nil
    var commentCount: Int? = nil
    var checklistDone: Int? = nil
    var checklistTotal: Int? = nil
    var linkedMergeRequests: Int? = nil
    var iteration: String? = nil
    var healthStatus: String? = nil
    var isDraft: Bool? = nil
    var hasConflicts: Bool? = nil
    var author: String? = nil

    /// Where a GitLab item lives: what the next PR needs to log time to it, and its page.
    struct GitLabRef: Equatable {
        var kind: GitLabKind
        var projectID: Int
        var iid: Int
        /// Already checked to be on the connected server (`GitLabHost.isWebURL`); nil otherwise.
        var webURL: String?
    }
}

/// What a sync brought back. `complete` is false when the source had more than Kannu fetched (the
/// page cap) or did not say it was done: then nothing can be concluded from an issue's absence.
struct RemoteFetch: Equatable {
    var issues: [RemoteIssue]
    var complete: Bool
}

enum SyncOutcome: Equatable {
    case fetched(RemoteFetch)
    /// Any page failed. The task list must not change.
    case failed
}

/// Folding a sync into the task list. Pure, and applied on the main actor to the list as it is
/// *now* — never a wholesale replace — so an edit made while the request was out survives it.
///
/// - A task matches an issue on (source, remote id) within the same site or server. A match
///   refreshes what the source owns (key, title, status and its category, labels, estimate, logged
///   time, last seen, and a GitLab item's kind, project, number and page) and keeps what the user
///   owns: Kannu's id, the place in the order, the local estimate, the recorded time, the log
///   policy, the tags and whether it is done or archived by the user. A task that had gone, or was
///   archived on its own after going, and came back is active again. A task the user archived stays
///   archived, but is marked as still listed (`closedAt` cleared), so the archive never clears it.
/// - A task turning `.gone` is stamped `closedAt` (when the source stopped listing it). An
///   archived one the fetch no longer returns is stamped too, if it was not already.
/// - A new issue is appended at the end of the order. An issue listed twice counts once: the first.
/// - A complete fetch turns the *active* tasks it did not return into `.gone`. A capped one marks
///   nothing gone. A failed one changes nothing.
/// - Tasks of this source from another site or server become `.gone` on any successful fetch: the
///   user connected a different one, and its issues are not theirs to work on here.
/// - A task in `keepingActive` (the one being timed) never becomes `.gone`, for either reason: its
///   row holds the only Stop button in the list. The first sync after its timing ends decides.
enum TaskMerge {
    struct Result: Equatable {
        var tasks: [TaskItem]
        var added: Int
        var updated: Int
        var gone: Int

        var changed: Bool { added + updated + gone > 0 }
    }

    static func apply(
        _ outcome: SyncOutcome,
        source: TaskSource,
        hostScope: String,
        to tasks: [TaskItem],
        now: Date,
        // No default: every caller says which task is being timed.
        keepingActive: Set<UUID>,
        newID: () -> UUID = UUID.init
    ) -> Result {
        guard case .fetched(let fetch) = outcome else {
            return Result(tasks: tasks, added: 0, updated: 0, gone: 0)
        }

        var result = tasks
        var indexByRemoteID: [String: Int] = [:]
        for (index, task) in result.enumerated() where task.source == source && task.remote?.hostScope == hostScope {
            if let remoteID = task.remote?.remoteID, indexByRemoteID[remoteID] == nil {
                indexByRemoteID[remoteID] = index
            }
        }

        var seen = Set<String>()
        var added = 0
        var updated = 0
        var appended: [TaskItem] = []
        for issue in fetch.issues where seen.insert(issue.remoteID).inserted {
            let title = TaskItem.cleanedTitle(issue.title) ?? issue.key
            if let index = indexByRemoteID[issue.remoteID], var remote = result[index].remote {
                var task = result[index]
                let before = task
                remote.key = issue.key
                remote.status = issue.status
                remote.isDoneRemotely = issue.isDoneRemotely
                remote.remoteEstimateSeconds = issue.estimateSeconds
                remote.remoteSpentSeconds = issue.spentSeconds
                remote.statusCategory = issue.statusCategory
                remote.labels = issue.labels
                remote.weight = issue.weight
                remote.milestone = issue.milestone
                remote.dueDate = issue.dueDate
                remote.assignee = issue.assignee
                remote.parentTitle = issue.parentTitle
                remote.priority = issue.priority
                remote.issueType = issue.issueType
                remote.updatedAt = issue.updatedAt
                remote.commentCount = issue.commentCount
                remote.checklistDone = issue.checklistDone
                remote.checklistTotal = issue.checklistTotal
                remote.linkedMergeRequests = issue.linkedMergeRequests
                remote.iteration = issue.iteration
                remote.healthStatus = issue.healthStatus
                remote.isDraft = issue.isDraft
                remote.hasConflicts = issue.hasConflicts
                remote.author = issue.author
                if let gitlab = issue.gitlab {
                    remote.gitlabKind = gitlab.kind
                    remote.gitlabProjectID = gitlab.projectID
                    remote.gitlabIID = gitlab.iid
                    remote.gitlabWebURL = gitlab.webURL
                }
                task.title = title
                switch task.visibility {
                case .gone:
                    task.visibility = .active
                    task.closedAt = nil
                case .archived where !task.archivedByUser:
                    // Archived on its own after it went (merge requests switched off, unassigned):
                    // listed again, it returns with its time, as a gone one always has.
                    task.visibility = .active
                    task.closedAt = nil
                    task.archivedAt = nil
                case .archived:
                    // The user put it away: it stays. Still listed, so the archive never clears it.
                    task.closedAt = nil
                case .active, .done:
                    break
                }
                task.remote = remote
                // Last seen moves on every sync; on its own it is not a change worth saving.
                if task != before { updated += 1 }
                task.remote?.lastSeenAt = now
                result[index] = task
            } else {
                let remote = RemoteTaskInfo(
                    remoteID: issue.remoteID,
                    key: issue.key,
                    hostScope: hostScope,
                    status: issue.status,
                    isDoneRemotely: issue.isDoneRemotely,
                    remoteEstimateSeconds: issue.estimateSeconds,
                    remoteSpentSeconds: issue.spentSeconds,
                    gitlabProjectID: issue.gitlab?.projectID,
                    gitlabIID: issue.gitlab?.iid,
                    lastSeenAt: now,
                    gitlabKind: issue.gitlab?.kind,
                    gitlabWebURL: issue.gitlab?.webURL,
                    statusCategory: issue.statusCategory,
                    labels: issue.labels,
                    weight: issue.weight,
                    milestone: issue.milestone,
                    dueDate: issue.dueDate,
                    assignee: issue.assignee,
                    parentTitle: issue.parentTitle,
                    priority: issue.priority,
                    issueType: issue.issueType,
                    updatedAt: issue.updatedAt,
                    commentCount: issue.commentCount,
                    checklistDone: issue.checklistDone,
                    checklistTotal: issue.checklistTotal,
                    linkedMergeRequests: issue.linkedMergeRequests,
                    iteration: issue.iteration,
                    healthStatus: issue.healthStatus,
                    isDraft: issue.isDraft,
                    hasConflicts: issue.hasConflicts,
                    author: issue.author
                )
                appended.append(TaskItem(id: newID(), source: source, title: title, remote: remote, createdAt: now))
                added += 1
            }
        }

        var gone = 0
        for index in result.indices where result[index].source == source && !keepingActive.contains(result[index].id) {
            let remote = result[index].remote
            let otherSite = remote?.hostScope != hostScope
            let missing = fetch.complete && !otherSite && !(remote.map { seen.contains($0.remoteID) } ?? false)
            guard otherSite || missing else { continue }
            switch result[index].visibility {
            case .active:
                result[index].visibility = .gone
                result[index].closedAt = now
                gone += 1
            case .archived where result[index].closedAt == nil:
                // No longer listed: from here the archive may clear it.
                result[index].closedAt = now
                updated += 1
            case .gone, .done, .archived:
                break
            }
        }

        return Result(tasks: result + appended, added: added, updated: updated, gone: gone)
    }
}
