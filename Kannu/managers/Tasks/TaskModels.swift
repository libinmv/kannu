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

// The task list as it is stored in `tasks.json`. Pure Foundation, so the logic target tests it.
//
// A task is local, or comes from Jira or GitLab (`TaskSource`, `RemoteTaskInfo`). Time recorded on a
// remote task becomes a `WorklogDraft` that waits for the user's answer (`WorklogDrafts`); only
// `TasksManager.confirmWorklog` ever sends one.

enum TaskSource: String, Codable, Equatable {
    case local
    case jira
    case gitlab
}

/// Whether a remote task's recorded time is offered for logging.
enum LogPolicy: String, Codable, Equatable {
    /// Each finished stretch of work is folded into one draft that waits for the user's answer.
    case ask
    /// Time is recorded here and never offered for logging.
    case localOnly
}

enum TaskVisibility: String, Codable, Equatable {
    /// In the task order.
    case active
    /// Marked done.
    case done
    /// Hidden by the user (a remote task cannot be deleted, only hidden).
    case hidden
    /// A remote task the last complete sync no longer returned.
    case gone
}

/// Which kind of GitLab item a task is. Issues and merge requests number their global ids
/// separately, so the kind is part of a GitLab task's `remoteID` too (`GitLabAPI.remoteID`).
enum GitLabKind: String, Codable, Equatable {
    case issue
    case mergeRequest
}

/// What Kannu knows about a task that lives in Jira or GitLab. Nil for a local task.
struct RemoteTaskInfo: Codable, Equatable {
    /// The Jira issue id, or the GitLab global id with its kind (`issue:76`, `mr:31`): the stable
    /// key a sync matches on.
    var remoteID: String
    /// "PROJ-123", "group/app#45" or "group/app!12". Refreshed on every sync, because an item can
    /// move.
    var key: String
    /// The Jira site's host, or the GitLab server's base URL (`https://gitlab.com`), the task came
    /// from.
    var hostScope: String
    var status: String
    var isDoneRemotely: Bool
    var remoteEstimateSeconds: Int?
    /// Time the server already has logged. Shown on its own, never added to tracked time.
    var remoteSpentSeconds: Int?
    var gitlabProjectID: Int?
    var gitlabIID: Int?
    var lastSeenAt: Date
    /// GitLab only: an issue or a merge request. Nil for Jira, and in a file written before GitLab.
    var gitlabKind: GitLabKind? = nil
    /// GitLab only: the item's page, kept only when it is on the server the task came from
    /// (`GitLabHost.isWebURL`), and checked again before it is opened.
    var gitlabWebURL: String? = nil
    /// Where the item stands, in Jira's status-category words: "new" (To Do), "indeterminate" (In
    /// Progress) or "done". Jira's own `status.statusCategory.key`; for GitLab, set by
    /// `GitLabAPI.remoteIssue` (`TaskFacets.gitlabCategory`). Nil in a file written before it.
    var statusCategory: String? = nil
    /// GitLab only: the item's labels, as the server sent them. Read for the In Progress facet and
    /// never sent anywhere. Nil for Jira, and in a file written before it.
    var labels: [String]? = nil

    private enum CodingKeys: String, CodingKey {
        case remoteID, key, hostScope, status, isDoneRemotely, remoteEstimateSeconds, remoteSpentSeconds
        case gitlabProjectID, gitlabIID, lastSeenAt, gitlabKind, gitlabWebURL, statusCategory, labels
    }
}

extension RemoteTaskInfo {
    /// The GitLab fields came after the first version and default instead of failing, so a file
    /// written before them still reads. A kind this version does not know (a newer Kannu's) reads
    /// as nil rather than costing the user the whole file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        remoteID = try container.decode(String.self, forKey: .remoteID)
        key = try container.decode(String.self, forKey: .key)
        hostScope = try container.decode(String.self, forKey: .hostScope)
        status = try container.decode(String.self, forKey: .status)
        isDoneRemotely = try container.decode(Bool.self, forKey: .isDoneRemotely)
        remoteEstimateSeconds = try container.decodeIfPresent(Int.self, forKey: .remoteEstimateSeconds)
        remoteSpentSeconds = try container.decodeIfPresent(Int.self, forKey: .remoteSpentSeconds)
        gitlabProjectID = try container.decodeIfPresent(Int.self, forKey: .gitlabProjectID)
        gitlabIID = try container.decodeIfPresent(Int.self, forKey: .gitlabIID)
        lastSeenAt = try container.decode(Date.self, forKey: .lastSeenAt)
        gitlabKind = (try? container.decodeIfPresent(GitLabKind.self, forKey: .gitlabKind)) ?? nil
        gitlabWebURL = try container.decodeIfPresent(String.self, forKey: .gitlabWebURL)
        statusCategory = try? container.decodeIfPresent(String.self, forKey: .statusCategory)
        labels = try? container.decodeIfPresent([String].self, forKey: .labels)
    }
}

/// One stretch of actual work on a task.
struct WorkSegment: Codable, Identifiable, Equatable {
    enum Origin: String, Codable, Equatable {
        /// Recorded while the task was timed with Kannu's timer.
        case timer
        /// Added by hand ("Add Time").
        case manual
        /// Was still open when Kannu loaded the file: Kannu quit or crashed while it was being
        /// timed. Until the user sets its end it has none, and it counts for nothing.
        case recovered
    }

    let id: UUID
    var start: Date
    /// Nil while the segment is open.
    var end: Date?
    var origin: Origin
    /// The draft this segment was folded into; nil while it is unlogged.
    var draftID: UUID?

    init(id: UUID = UUID(), start: Date, end: Date? = nil, origin: Origin, draftID: UUID? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.origin = origin
        self.draftID = draftID
    }

    /// Open and being recorded right now.
    var isLive: Bool { end == nil && origin != .recovered }

    /// Open because Kannu stopped while it was being recorded; waiting for the user to set its end.
    var isInterrupted: Bool { end == nil && origin == .recovered }
}

struct TaskItem: Codable, Identifiable, Equatable {
    /// Kannu's own id. Stable for the task's whole life, whatever happens to a remote key.
    let id: UUID
    var source: TaskSource
    var title: String
    /// The user's estimate. Wins over the remote one for display.
    var localEstimateSeconds: Int?
    var remote: RemoteTaskInfo?
    /// The actual time, as recorded.
    var segments: [WorkSegment]
    var logPolicy: LogPolicy
    var visibility: TaskVisibility
    let createdAt: Date
    /// The user's own tags. Kannu's only: never sent to Jira or GitLab. Cleaned by `cleanedTags`.
    var tags: [String]
    /// When a local task's reminder is due. Nil when it has none; never set on a remote task.
    var scheduledAt: Date?

    init(
        id: UUID = UUID(),
        source: TaskSource = .local,
        title: String,
        localEstimateSeconds: Int? = nil,
        remote: RemoteTaskInfo? = nil,
        segments: [WorkSegment] = [],
        logPolicy: LogPolicy = .ask,
        visibility: TaskVisibility = .active,
        createdAt: Date = Date(),
        tags: [String] = [],
        scheduledAt: Date? = nil
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.localEstimateSeconds = localEstimateSeconds
        self.remote = remote
        self.segments = segments
        self.logPolicy = logPolicy
        self.visibility = visibility
        self.createdAt = createdAt
        self.tags = tags
        self.scheduledAt = scheduledAt
    }

    var effectiveEstimateSeconds: Int? { localEstimateSeconds ?? remote?.remoteEstimateSeconds }

    /// The longest title kept. Long enough for any issue summary, short enough for one row.
    static let maxTitleLength = 200

    /// A typed title made into one clean line, or nil when nothing is left of it.
    static func cleanedTitle(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard !words.isEmpty else { return nil }
        let joined = words.joined(separator: " ")
        guard joined.count > maxTitleLength else { return joined }
        return String(joined.prefix(maxTitleLength)).trimmingCharacters(in: .whitespaces)
    }

    /// At most this many tags on one task.
    static let maxTags = 10
    /// A longer tag is cut to this many characters.
    static let maxTagLength = 24

    /// Tags as Kannu keeps them: one line each, without a leading "#", at most `maxTagLength`
    /// characters, the first spelling of each (compared ignoring case), at most `maxTags`.
    static func cleanedTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in raw {
            var text = tag.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
            while text.hasPrefix("#") { text.removeFirst() }
            text = String(text.trimmingCharacters(in: .whitespaces).prefix(maxTagLength))
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
            result.append(text)
            if result.count == maxTags { break }
        }
        return result
    }

    /// Tags typed in one field, separated by commas: "writing, #urgent".
    static func parsedTags(_ text: String) -> [String] {
        cleanedTags(text.components(separatedBy: CharacterSet(charactersIn: ",\n")))
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, title, localEstimateSeconds, remote, segments, logPolicy, visibility, createdAt
        case tags, scheduledAt
    }

    /// Fields added after the first version default instead of failing, so an older file still
    /// reads. Unknown keys are ignored, so a newer file reads too.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        source = try container.decodeIfPresent(TaskSource.self, forKey: .source) ?? .local
        title = try container.decode(String.self, forKey: .title)
        localEstimateSeconds = try container.decodeIfPresent(Int.self, forKey: .localEstimateSeconds)
        remote = try container.decodeIfPresent(RemoteTaskInfo.self, forKey: .remote)
        segments = try container.decodeIfPresent([WorkSegment].self, forKey: .segments) ?? []
        logPolicy = try container.decodeIfPresent(LogPolicy.self, forKey: .logPolicy) ?? .ask
        visibility = try container.decodeIfPresent(TaskVisibility.self, forKey: .visibility) ?? .active
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        tags = Self.cleanedTags((try? container.decodeIfPresent([String].self, forKey: .tags)) ?? [])
        scheduledAt = try? container.decodeIfPresent(Date.self, forKey: .scheduledAt)
    }
}

enum WorklogState: String, Codable, Equatable {
    /// Waiting for the user to log it, keep it, or leave it.
    case awaiting
    /// Being sent. Saved before the request goes out, so a relaunch knows to check.
    case sending
    case logged
    /// Refused, or never sent. Can be retried.
    case failed
    /// Sent, but no answer came back: it may or may not be logged.
    case uncertain
    /// The user chose to keep this time on this Mac only.
    case keptLocal
}

/// Time waiting to be logged to a remote task. One pending draft per task.
struct WorklogDraft: Codable, Identifiable, Equatable {
    /// Also the marker a Jira worklog carries, so a retry can find an earlier attempt.
    let id: UUID
    let taskID: UUID
    var seconds: Int
    var started: Date
    var comment: String?
    var hostScope: String
    var state: WorklogState
    /// What the last attempt ended with, for the card: a refusal's reason, "may already be
    /// logged". Nil while nothing needs saying.
    var message: String?
    var remoteWorklogID: String?
    /// When the user answered Not now. The card folds into one line until more time is added to
    /// the draft, which asks again. Optional, so a file written before it still reads.
    var deferredAt: Date?

    init(
        id: UUID = UUID(),
        taskID: UUID,
        seconds: Int,
        started: Date,
        comment: String? = nil,
        hostScope: String,
        state: WorklogState = .awaiting,
        message: String? = nil,
        remoteWorklogID: String? = nil,
        deferredAt: Date? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.seconds = seconds
        self.started = started
        self.comment = comment
        self.hostScope = hostScope
        self.state = state
        self.message = message
        self.remoteWorklogID = remoteWorklogID
        self.deferredAt = deferredAt
    }
}

/// The whole of `tasks.json`. The order of `tasks` is the order the user set.
struct TasksFile: Codable, Equatable {
    static let currentVersion = 1
    static let empty = TasksFile(version: currentVersion, tasks: [], drafts: [])

    var version: Int
    var tasks: [TaskItem]
    var drafts: [WorklogDraft]
    /// Each tag's colour, keyed by `TaskColoring.key(for:)`. A tag without an entry is `.glass`,
    /// which is never stored. Kannu's only, like the tags themselves.
    var tagColors: [String: TaskColor]

    init(
        version: Int = TasksFile.currentVersion,
        tasks: [TaskItem],
        drafts: [WorklogDraft],
        tagColors: [String: TaskColor] = [:]
    ) {
        self.version = version
        self.tasks = tasks
        self.drafts = drafts
        self.tagColors = tagColors
    }

    private enum CodingKeys: String, CodingKey {
        case version, tasks, drafts, tagColors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        tasks = try container.decodeIfPresent([TaskItem].self, forKey: .tasks) ?? []
        drafts = try container.decodeIfPresent([WorklogDraft].self, forKey: .drafts) ?? []
        // Added after the first version, and only decoration: a missing or malformed value, or a
        // colour this version does not know, never costs the file. Each entry decodes on its own,
        // so one bad value costs only that tag's colour.
        let rawColors = (try? container.decodeIfPresent([String: LossyString].self, forKey: .tagColors)) ?? [:]
        tagColors = TaskColoring.cleanedTagColors(rawColors.compactMapValues(\.value))
    }

    /// A string, or nil when the value is anything else.
    private struct LossyString: Decodable {
        let value: String?

        init(from decoder: Decoder) {
            value = try? decoder.singleValueContainer().decode(String.self)
        }
    }

    /// A segment still open in a file being loaded was being timed when Kannu stopped: a quit that
    /// could not save, a crash, a force quit. Kannu never guesses when the work ended, so each one
    /// becomes `.recovered`, counts for nothing, and waits for the user. Returns how many changed.
    @discardableResult
    mutating func markOpenSegmentsInterrupted() -> Int {
        var changed = 0
        for taskIndex in tasks.indices {
            for segmentIndex in tasks[taskIndex].segments.indices where tasks[taskIndex].segments[segmentIndex].isLive {
                tasks[taskIndex].segments[segmentIndex].origin = .recovered
                changed += 1
            }
        }
        return changed
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
