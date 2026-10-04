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

/// One issue as a source returned it, already reduced to what a task keeps.
struct RemoteIssue: Equatable {
    /// The source's stable id (a Jira issue id), never the key: a key changes when an issue moves.
    var remoteID: String
    var key: String
    var title: String
    var status: String
    var isDoneRemotely: Bool
    var estimateSeconds: Int?
    var spentSeconds: Int?
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
/// - A task matches an issue on (source, remote id) within the same site. A match refreshes what
///   the source owns (key, title, status, estimate, logged time, last seen) and keeps what the user
///   owns: Kannu's id, the place in the order, the local estimate, the recorded time, the log
///   policy and whether it is done or hidden. A task that had gone and came back is active again.
/// - A new issue is appended at the end of the order. An issue listed twice counts once: the first.
/// - A complete fetch turns the *active* tasks it did not return into `.gone`. A capped one marks
///   nothing gone. A failed one changes nothing.
/// - Tasks of this source from another site become `.gone` on any successful fetch: the user
///   connected a different site, and the old site's issues are not theirs to work on here.
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
                task.title = title
                if task.visibility == .gone { task.visibility = .active }
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
                    gitlabProjectID: nil,
                    gitlabIID: nil,
                    lastSeenAt: now
                )
                appended.append(TaskItem(id: newID(), source: source, title: title, remote: remote, createdAt: now))
                added += 1
            }
        }

        var gone = 0
        for index in result.indices where result[index].source == source && result[index].visibility == .active
            && !keepingActive.contains(result[index].id) {
            let remote = result[index].remote
            let otherSite = remote?.hostScope != hostScope
            let missing = fetch.complete && !otherSite && !(remote.map { seen.contains($0.remoteID) } ?? false)
            if otherSite || missing {
                result[index].visibility = .gone
                gone += 1
            }
        }

        return Result(tasks: result + appended, added: added, updated: updated, gone: gone)
    }
}
