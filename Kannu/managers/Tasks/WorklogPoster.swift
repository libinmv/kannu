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

/// What Jira needs to find an entry Kannu may already have sent: the entry's marker, and the
/// author, start and length to fall back on for a worklog without it.
struct JiraWorklogLookup: Equatable {
    var credential: JiraCredential
    var issueID: String
    var entry: UUID
    /// The connected account (`/myself`); empty matches nothing by author.
    var accountID: String
    var started: Date
    var seconds: Int
}

/// Sends a worklog the user confirmed, and reads back when its answer was lost. Foundation only,
/// over `IntegrationHTTP` (ephemeral, 20 s, every redirect refused), so the logic target runs it
/// against a `URLProtocol` stub.
///
/// It sends only the request it is handed, and those are built in one place:
/// `TasksManager.confirmWorklog`, from the user's own click (`WorklogConsentRulesTests`). The only
/// requests it makes on its own are Jira's read-only checks.
struct WorklogPoster {
    /// What Jira's read-only check found.
    enum Lookup: Equatable {
        /// The entry is there; its worklog id, when Jira gave one.
        case found(remoteID: String?)
        case notFound
        /// The check itself failed: the answer, or nil for one that did not read as Jira's.
        case failed(HTTPOutcome?)
    }

    let session: URLSession
    /// How long Jira gets to finish committing a POST whose answer was lost before the second
    /// read-only check. Only tests change it: shorter so the suite does not wait, longer to pin a
    /// wait that is cut short.
    let recheckDelay: Duration
    /// What the wait sleeps on. Tests hand in a clock that says when the wait began, so a test of
    /// the wait being cut short can prove it was the wait, and not the first read, that was cancelled.
    let clock: any Clock<Duration>

    init(
        session: URLSession = IntegrationHTTP.shared,
        recheckDelay: Duration = .seconds(3),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.session = session
        self.recheckDelay = recheckDelay
        self.clock = clock
    }

    /// POSTs a worklog built by `JiraAPI.addWorklogRequest`. When the answer is lost (a timeout, a
    /// dropped connection, a 5xx) the entry may or may not be there, so Jira is asked, read only,
    /// with `lookup` (`verifyLostJiraWorklog`): found is logged, missing twice is not, and a check
    /// that fails leaves it uncertain.
    func postJiraWorklog(_ request: URLRequest, lookup: JiraWorklogLookup) async -> WorklogDrafts.Verdict {
        let exchange = await IntegrationHTTP.send(request, session: session)
        switch exchange.outcome {
        case .ok:
            let id = exchange.data.flatMap(JiraAPI.decodeWorklog)?.id
            return .logged(remoteID: id.flatMap { $0.isEmpty ? nil : $0 })
        case .ambiguous:
            return await verifyLostJiraWorklog(lookup)
        default:
            return WorklogDrafts.verdict(for: exchange.outcome, reason: JiraAPI.refusalReason(exchange.data))
        }
    }

    /// The read-only checks after a lost answer. A POST whose answer was lost may still be
    /// committing on Jira's side, so one read that finds nothing is not an answer: it waits
    /// `recheckDelay` and reads once more, and only two misses say the entry is not there. A read
    /// that fails, or a wait cut short by cancellation, leaves it uncertain — never "not logged" on
    /// a guess, because that is what lets Keep Local Only drop an entry Jira holds.
    func verifyLostJiraWorklog(_ lookup: JiraWorklogLookup) async -> WorklogDrafts.Verdict {
        switch await findJiraWorklog(lookup) {
        case .found(let id):
            return .logged(remoteID: id)
        case .failed:
            return .uncertain
        case .notFound:
            break
        }
        do {
            try await clock.sleep(for: recheckDelay)
        } catch {
            return .uncertain
        }
        switch await findJiraWorklog(lookup) {
        case .found(let id):
            return .logged(remoteID: id)
        case .notFound:
            return .checkedNotFound
        case .failed:
            return .uncertain
        }
    }

    /// One read-only `GET /rest/api/3/issue/{id}/worklog`, around the entry's start, for the entry
    /// with Kannu's marker (or, without one, the same author, start and length).
    func findJiraWorklog(_ lookup: JiraWorklogLookup) async -> Lookup {
        guard let request = JiraAPI.worklogsRequest(lookup.credential, issueID: lookup.issueID, around: lookup.started) else {
            return .failed(nil)
        }
        let exchange = await IntegrationHTTP.send(request, session: session)
        guard case .ok = exchange.outcome else { return .failed(exchange.outcome) }
        guard let data = exchange.data, let page = JiraAPI.decodeWorklogPage(data) else { return .failed(nil) }
        guard let match = JiraAPI.matchingWorklog(
            in: page.worklogs,
            entry: lookup.entry,
            accountID: lookup.accountID,
            started: lookup.started,
            seconds: lookup.seconds
        ) else { return .notFound }
        return .found(remoteID: match.id.isEmpty ? nil : match.id)
    }

    /// POSTs time built by `GitLabAPI.addSpentTimeRequest`. GitLab returns no entry id and keeps no
    /// marker, so a lost answer cannot be checked: it is uncertain, and the user decides.
    func postGitLabSpend(_ request: URLRequest) async -> WorklogDrafts.Verdict {
        let exchange = await IntegrationHTTP.send(request, session: session)
        return WorklogDrafts.verdict(for: exchange.outcome, reason: GitLabAPI.refusalReason(exchange.data))
    }
}
