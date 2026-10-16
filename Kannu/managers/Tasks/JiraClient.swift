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
import os
import Security

/// Reads from Jira Cloud. Read-only: nothing here writes to Jira.
///
/// Its methods are nonisolated `async`, so awaiting them from the main actor runs the requests off
/// it (the `CursorUsageEventsClient` shape, with the session injected). Every request goes through
/// `IntegrationHTTP`: ephemeral, 20 s, no redirects.
struct JiraClient {
    enum Failure: Equatable {
        /// The credential's site is not one Kannu would send a request to.
        case badSite
        case http(HTTPOutcome)
        /// A 2xx whose body was not what Jira sends.
        case decode
    }

    enum VerifyResult: Equatable {
        case verified(JiraMyself)
        case failed(Failure)
    }

    private static let log = os.Logger(subsystem: "com.kannu.app", category: "Tasks")

    let session: URLSession

    init(session: URLSession = IntegrationHTTP.shared) {
        self.session = session
    }

    /// `GET /rest/api/3/myself`: whether the site accepts this email and token, and whose they are.
    func verify(_ credential: JiraCredential) async -> VerifyResult {
        guard let request = JiraAPI.myselfRequest(credential) else { return .failed(.badSite) }
        let exchange = await IntegrationHTTP.send(request, session: session)
        guard case .ok = exchange.outcome else {
            Self.log.notice("Jira verify failed: \(String(describing: exchange.outcome), privacy: .public)")
            return .failed(.http(exchange.outcome))
        }
        guard let data = exchange.data, let myself = JiraAPI.decodeMyself(data) else { return .failed(.decode) }
        return .verified(myself)
    }

    /// The issues the filter selects: at most `JiraAPI.maxPages` pages. Any page that fails fails
    /// the whole sync, so a half-read list never marks the other half gone.
    func fetchIssues(_ credential: JiraCredential, jql: String) async -> (outcome: SyncOutcome, failure: Failure?) {
        var issues: [RemoteIssue] = []
        var pageToken: String?
        var pages = 0
        while true {
            guard let request = JiraAPI.searchRequest(credential, jql: jql, nextPageToken: pageToken) else {
                return (.failed, .badSite)
            }
            let exchange = await IntegrationHTTP.send(request, session: session)
            guard case .ok = exchange.outcome else {
                Self.log.notice("Jira search page \(pages + 1, privacy: .public) failed: \(String(describing: exchange.outcome), privacy: .public)")
                return (.failed, .http(exchange.outcome))
            }
            guard let data = exchange.data, let page = JiraAPI.decodeSearchPage(data) else {
                Self.log.notice("Jira search page \(pages + 1, privacy: .public) did not decode")
                return (.failed, .decode)
            }
            pages += 1
            issues += page.issues.map(JiraAPI.remoteIssue(from:))
            switch JiraAPI.nextStep(after: page, pagesFetched: pages) {
            case .next(let next):
                pageToken = next
            case .done(let complete):
                return (.fetched(RemoteFetch(issues: issues, complete: complete)), nil)
            case .capped:
                return (.fetched(RemoteFetch(issues: issues, complete: false)), nil)
            }
        }
    }
}

/// The Jira credential in the Keychain. Every call runs on one serial queue, never on the caller's
/// thread: a Keychain read can show the SecurityAgent dialog (an interactive read, or an item whose
/// access list no longer matches this build) and blocks until it is answered — on the main thread
/// that freezes Kannu (docs/REGRESSIONS.md entry 11). Serial, so a save and a read cannot cross.
enum JiraCredentialStore {
    enum LoadResult: Equatable {
        case found(JiraCredential)
        case missing
        /// The item is there, but macOS wants the user to approve the read.
        case needsApproval
        /// The item is there but could not be read or did not decode.
        case broken
    }

    private static let queue = DispatchQueue(label: "com.kannu.app.tasks.jira-keychain", qos: .userInitiated)

    private static func onQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// `allowInteraction: false` (a background sync) never shows the dialog; a read that would need
    /// it comes back `.needsApproval`, and the user's own click retries with `true`.
    static func load(allowInteraction: Bool) async -> LoadResult {
        await onQueue {
            let read = SecureSecretsStore.read(.jiraCredential, allowInteraction: allowInteraction)
            if read.status == errSecItemNotFound { return .missing }
            if KeychainReader.needsUserApproval(read.status) { return .needsApproval }
            guard read.status == errSecSuccess, let value = read.value,
                  let credential = JiraCredential.decoded(value) else { return .broken }
            return .found(credential)
        }
    }

    static func save(_ credential: JiraCredential) async -> Bool {
        guard let encoded = credential.encoded() else { return false }
        return await onQueue { SecureSecretsStore.set(encoded, for: .jiraCredential) }
    }

    /// False when the item is still there. Never discard it: the user was told the token is gone.
    static func remove() async -> Bool {
        await onQueue { SecureSecretsStore.removeValue(for: .jiraCredential) }
    }
}
