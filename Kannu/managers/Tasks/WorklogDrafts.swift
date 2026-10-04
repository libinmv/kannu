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

/// Turning recorded time into log entries that wait for the user's answer, and the states such an
/// entry moves through.
///
/// Nothing here sends anything. A draft is only ever offered; logging it is a later, explicit step.
/// Only a remote task whose policy is `.ask` gets drafts: a local task has nowhere to log to, and
/// `.localOnly` means the user said never to ask.
enum WorklogDrafts {
    enum Event: Equatable {
        case send
        case succeeded
        case rejected
        case ambiguous
        case retry
        case keepLocal
        /// Kannu started again and found the draft in this state.
        case relaunched
    }

    /// Folds the task's unlogged, finished segments into its one awaiting draft.
    ///
    /// The draft's length is the exact total of every segment in it, rounded to the nearest 15
    /// minutes — so two 5-minute stretches make one 15-minute entry, not two empty ones. A total that
    /// rounds to 0 makes no draft: those segments stay unlogged and count toward the next one.
    static func folding(
        _ task: TaskItem,
        into drafts: [WorklogDraft],
        newID: () -> UUID = UUID.init
    ) -> (task: TaskItem, drafts: [WorklogDraft]) {
        guard task.source != .local, let remote = task.remote, task.logPolicy == .ask else {
            return (task, drafts)
        }
        let pending = drafts.first { $0.taskID == task.id && $0.state == .awaiting }
        let belongs: (WorkSegment) -> Bool = { segment in
            segment.end != nil && (segment.draftID == nil || segment.draftID == pending?.id)
        }
        let candidates = task.segments.filter(belongs)
        let exact = candidates.reduce(0) { $0 + TaskTimeMath.seconds(of: $1, now: $1.end ?? $1.start) }
        let rounded = TaskTimeMath.roundedForLog(exact)

        var task = task
        var drafts = drafts
        guard rounded > 0, let started = candidates.map(\.start).min() else {
            // Nothing worth logging yet. A pending draft that no longer adds up is withdrawn.
            if let pending {
                drafts.removeAll { $0.id == pending.id }
                for index in task.segments.indices where task.segments[index].draftID == pending.id {
                    task.segments[index].draftID = nil
                }
            }
            return (task, drafts)
        }

        let id = pending?.id ?? newID()
        for index in task.segments.indices where belongs(task.segments[index]) {
            task.segments[index].draftID = id
        }
        if let existing = drafts.firstIndex(where: { $0.id == id }) {
            drafts[existing].seconds = rounded
            drafts[existing].started = started
            drafts[existing].hostScope = remote.hostScope
        } else {
            drafts.append(WorklogDraft(id: id, taskID: task.id, seconds: rounded, started: started, hostScope: remote.hostScope))
        }
        return (task, drafts)
    }

    /// The state `event` moves a draft to, or nil when it does not apply in `state`.
    static func transition(_ state: WorklogState, on event: Event) -> WorklogState? {
        switch (state, event) {
        case (.awaiting, .send), (.failed, .retry), (.uncertain, .retry):
            return .sending
        case (.sending, .succeeded), (.uncertain, .succeeded):
            return .logged
        case (.sending, .rejected), (.uncertain, .rejected):
            return .failed
        case (.sending, .ambiguous), (.sending, .relaunched):
            return .uncertain
        case (.awaiting, .keepLocal), (.failed, .keepLocal), (.uncertain, .keepLocal):
            return .keptLocal
        default:
            return nil
        }
    }

    /// A draft still `.sending` when the file loads was being sent when Kannu stopped. Whether it
    /// arrived is unknown, so it becomes `.uncertain` and is never sent again without a check.
    static func normalizedAtLoad(_ drafts: [WorklogDraft]) -> [WorklogDraft] {
        drafts.map { draft in
            guard let next = transition(draft.state, on: .relaunched) else { return draft }
            var draft = draft
            draft.state = next
            return draft
        }
    }
}
