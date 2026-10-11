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

/// Turning recorded time into log entries that wait for the user's answer, the states such an
/// entry moves through, and what each answer from Jira or GitLab means for it.
///
/// Nothing here sends anything. A draft is only ever offered; logging it is a later, explicit step
/// (`TasksManager.confirmWorklog`, the only caller of the request builders). Only a remote task
/// whose policy is `.ask` gets drafts: a local task has nowhere to log to, and `.localOnly` means
/// the user said never to ask.
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
    /// rounds to 0 makes no draft: those segments stay unlogged and count toward the next one. New
    /// time added to a draft the user put off (Not now) asks again.
    ///
    /// A length the user chose survives: a Log that sent nothing leaves the typed length on the
    /// awaiting draft, and folding it again (more time, or the next launch) keeps the user's change
    /// and adds only the new time to it.
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
        let addsTime = candidates.contains { $0.draftID == nil }
        for index in task.segments.indices where belongs(task.segments[index]) {
            task.segments[index].draftID = id
        }
        if let existing = drafts.firstIndex(where: { $0.id == id }) {
            // What the draft's own segments came to when last folded; the rest is the user's change.
            let foldedBefore = TaskTimeMath.roundedForLog(candidates.filter { $0.draftID == id }.reduce(0) {
                $0 + TaskTimeMath.seconds(of: $1, now: $1.end ?? $1.start)
            })
            let chosen = foldedBefore > 0 ? drafts[existing].seconds - foldedBefore : 0
            let kept = rounded + chosen
            drafts[existing].seconds = kept >= 60 ? kept : rounded
            drafts[existing].started = started
            drafts[existing].hostScope = remote.hostScope
            if addsTime { drafts[existing].deferredAt = nil }
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
    ///
    /// The card of an uncertain draft says so: `confirmWorklog` cleared the message when it started
    /// sending, so one is given here from the task's source (`source`, nil when the task is gone —
    /// that card says it cannot be sent instead).
    static func normalizedAtLoad(_ drafts: [WorklogDraft], source: (WorklogDraft) -> TaskSource?) -> [WorklogDraft] {
        drafts.map { draft in
            var draft = draft
            if let next = transition(draft.state, on: .relaunched) { draft.state = next }
            if draft.state == .uncertain, draft.message == nil, let source = source(draft) {
                draft.message = uncertainAtLaunchMessage(source)
            }
            return draft
        }
    }

    /// What an entry Kannu stopped while sending says at the next launch.
    static func uncertainAtLaunchMessage(_ source: TaskSource) -> String? {
        switch source {
        case .gitlab:
            return String(localized: "May already be logged — check GitLab")
        case .jira:
            return String(localized: "Kannu stopped while sending this, so it may already be logged. Retry checks Jira first and logs it only if it is not there.")
        case .local:
            return nil
        }
    }

    /// Whether Time to log shows a draft: still waiting for an answer, being sent, refused, or
    /// perhaps logged. Logged and kept-local drafts are done with.
    static func isOpen(_ state: WorklogState) -> Bool {
        switch state {
        case .awaiting, .sending, .failed, .uncertain: return true
        case .logged, .keptLocal: return false
        }
    }

    // MARK: - What the notch asks about

    /// Whether the notch's Tasks popover shows the draft's card: open, and not put off with Not now.
    /// A put-off entry waits in Brain › Tasks › Time to log until more time is added to it.
    static func isAskingNow(_ draft: WorklogDraft) -> Bool {
        isOpen(draft.state) && !(draft.state == .awaiting && draft.deferredAt != nil)
    }

    /// Whether the draft waits for the user's answer — Log, Retry, Mark as Logged or Keep local only —
    /// which lights the yellow dot on the notch's Tasks button. One being sent does not wait for
    /// anything, and Not now is an answer.
    static func needsAnswer(_ draft: WorklogDraft) -> Bool {
        isAskingNow(draft) && draft.state != .sending
    }

    /// How many entries wait for an answer: the dot, and the Tasks button's VoiceOver label.
    static func waitingCount(_ drafts: [WorklogDraft]) -> Int {
        drafts.reduce(0) { $0 + (needsAnswer($1) ? 1 : 0) }
    }

    // MARK: - The length sent

    /// A length as it is sent: rounded to whole minutes (GitLab takes nothing finer), at least a
    /// minute, at most `WorkDuration.maxSeconds`.
    static func loggableSeconds(_ seconds: Int) -> Int? {
        guard seconds >= 0 else { return nil }
        let rounded = ((seconds + 30) / 60) * 60
        guard rounded >= 60, rounded <= WorkDuration.maxSeconds else { return nil }
        return rounded
    }

    /// The card's duration field, read with `WorkDuration.parse` ("1h 15m", "75m", "1.25h"), as it
    /// would be sent; nil when it is not a length Kannu would send.
    static func loggableSeconds(typed text: String) -> Int? {
        WorkDuration.parse(text).flatMap(loggableSeconds(_:))
    }

    // MARK: - Whether a draft can be sent from here

    enum Availability: Equatable {
        case ready
        /// The source is not connected, or is connected to another site or server than the one the
        /// time was recorded against. A draft is never sent anywhere else.
        case notConnected
        /// GitLab with a token that cannot log time (`read_api`).
        case readOnly
        /// The task lacks what the request is built from: an id that is not a Jira issue id, a
        /// GitLab item without its project or number, or no task at all.
        case missingDetails
    }

    static func availability(
        of draft: WorklogDraft,
        task: TaskItem?,
        jiraHost: String,
        gitlabHost: String,
        gitlabCanLogTime: Bool
    ) -> Availability {
        guard let task, task.id == draft.taskID, let remote = task.remote else { return .missingDetails }
        switch task.source {
        case .local:
            return .missingDetails
        case .jira:
            guard !jiraHost.isEmpty, jiraHost == draft.hostScope else { return .notConnected }
            return JiraAPI.isIssueID(remote.remoteID) ? .ready : .missingDetails
        case .gitlab:
            guard !gitlabHost.isEmpty, gitlabHost == draft.hostScope else { return .notConnected }
            guard gitlabCanLogTime else { return .readOnly }
            guard remote.gitlabKind != nil, (remote.gitlabProjectID ?? 0) > 0, (remote.gitlabIID ?? 0) > 0 else {
                return .missingDetails
            }
            return .ready
        }
    }

    // MARK: - What an answer means

    /// What one send came to, from the answer to the request (and, for Jira, the check after a lost
    /// answer).
    enum Verdict: Equatable {
        case logged(remoteID: String?)
        /// Refused: a 4xx other than 401 and 429, or a redirect. The server's reason when it gave one.
        case refused(status: Int, reason: String?)
        /// 401: the token was refused.
        case authRejected(status: Int)
        /// It never reached the server: offline, unreachable, or a rate limit.
        case notSent(HTTPOutcome)
        /// Jira lost the answer, and the one read-only check found no such entry.
        case checkedNotFound
        /// It may have arrived and could not be checked.
        case uncertain
    }

    /// The verdict an answer to a write gives on its own. A lost answer (`.ambiguous`: a timeout, a
    /// dropped connection, a 5xx) is `.uncertain` here; `WorklogPoster` checks Jira once before
    /// settling for that.
    static func verdict(for outcome: HTTPOutcome, reason: String?) -> Verdict {
        switch outcome {
        case .ok:
            return .logged(remoteID: nil)
        case .redirected(let status):
            return .refused(status: status, reason: nil)
        case .rejected(let status):
            return .refused(status: status, reason: reason)
        case .auth(let status):
            return .authRejected(status: status)
        case .rateLimited, .offline, .failedBeforeSend:
            return .notSent(outcome)
        case .ambiguous:
            return .uncertain
        }
    }

    /// What a verdict does to a draft being sent, and what its card says then.
    static func resolution(of verdict: Verdict, source: TaskSource) -> (event: Event, message: String?) {
        let name = sourceName(source)
        switch verdict {
        case .logged:
            return (.succeeded, nil)
        case .refused(let status, let reason):
            let base: String
            switch (source, status) {
            case (.gitlab, 403):
                base = String(localized: "GitLab refused it (403): the token needs the api scope, or you may not log time on this item.")
            case (_, 400):
                base = String(localized: "\(name) refused it (400). Time tracking may be off for this project.")
            case (_, 403):
                base = String(localized: "\(name) refused it (403): you may not log work on this issue.")
            case (_, 404):
                base = String(localized: "\(name) cannot find this item any more (404).")
            case (_, 300..<400):
                base = String(localized: "\(name) answered with a redirect (\(status)), which Kannu never follows. Nothing was logged.")
            default:
                base = String(localized: "\(name) refused it (\(status)).")
            }
            guard let reason else { return (.rejected, base) }
            return (.rejected, String(localized: "\(base) \(name) says: \(reason)"))
        case .authRejected(let status):
            return (.rejected, String(localized: "\(name) did not accept the token (\(status)): it may have expired or been revoked. Reconnect \(name) in Sources, then retry."))
        case .notSent(let outcome):
            switch outcome {
            case .offline:
                return (.rejected, String(localized: "This Mac is offline, so nothing was sent. Retry once you are back online."))
            case .rateLimited:
                return (.rejected, String(localized: "\(name) is limiting requests, so nothing was sent. Retry in a minute."))
            default:
                return (.rejected, String(localized: "Kannu could not reach \(name), so nothing was sent. Retry later."))
            }
        case .checkedNotFound:
            return (.rejected, String(localized: "\(name) did not answer, and the entry is not there, so nothing was logged. Retry."))
        case .uncertain:
            switch source {
            case .gitlab:
                return (.ambiguous, String(localized: "May already be logged — check GitLab"))
            case .jira, .local:
                return (.ambiguous, String(localized: "\(name) did not answer, so this may already be logged. Retry checks \(name) first and logs it only if it is not there."))
            }
        }
    }

    /// Jira's read-only check before a retry could not finish, so nothing was sent. A draft that may
    /// already be logged stays uncertain; any other fails, with the reason.
    static func checkFailure(_ outcome: HTTPOutcome?, mayAlreadyBeLogged: Bool) -> (event: Event, message: String) {
        let event: Event = mayAlreadyBeLogged ? .ambiguous : .rejected
        switch outcome {
        case .offline?:
            return (event, String(localized: "This Mac is offline, so Kannu could not check Jira and sent nothing. Retry once you are back online."))
        case .auth(let status)?:
            return (event, String(localized: "Jira did not accept the token (\(status)), so nothing was sent. Reconnect Jira in Sources, then retry."))
        case .rateLimited?:
            return (event, String(localized: "Jira is limiting requests, so Kannu could not check it and sent nothing. Retry in a minute."))
        default:
            return (event, String(localized: "Kannu could not check Jira for this entry, so it sent nothing. Retry later."))
        }
    }

    /// A server's reason as a card shows it: one line, control characters gone, at most 200
    /// characters. It is the server's text, shown verbatim, never as markup. Nil when empty.
    static func displayReason(_ text: String) -> String? {
        let scalars = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " as Unicode.Scalar : $0 }
        let words = String(String.UnicodeScalarView(scalars)).split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }
        let line = words.joined(separator: " ")
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }

    // MARK: - The card

    /// "Jira" or "GitLab": names, not words, so never translated.
    static func sourceName(_ source: TaskSource) -> String {
        switch source {
        case .jira: return "Jira"
        case .gitlab: return "GitLab"
        case .local: return String(localized: "this Mac")
        }
    }

    /// "Log 1h 15m to PROJ-123?", "Log 45m to group/app!12?".
    static func headline(seconds: Int, key: String) -> String {
        String(localized: "Log \(WorkDuration.format(seconds)) to \(key)?")
    }

    /// "started today 14:02 · Jira", "started yesterday 09:15 · GitLab", "started 2 Oct 14:02 · Jira".
    static func caption(started: Date, now: Date, source: TaskSource, calendar: Calendar = .current) -> String {
        let time = started.formatted(date: .omitted, time: .shortened)
        let when: String
        if calendar.isDate(started, inSameDayAs: now) {
            when = String(localized: "started today \(time)")
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(started, inSameDayAs: yesterday) {
            when = String(localized: "started yesterday \(time)")
        } else {
            when = String(localized: "started \(started.formatted(.dateTime.day().month(.abbreviated))) \(time)")
        }
        return "\(when) · \(sourceName(source))"
    }
}
