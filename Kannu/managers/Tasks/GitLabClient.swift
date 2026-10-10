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

/// Reads from GitLab: the app's side of `GitLabReader`, which does the requests, with the log lines.
/// Read-only: nothing here writes to GitLab.
///
/// Its methods are nonisolated `async`, so awaiting them from the main actor runs the requests off
/// it. Logs carry status codes and counts only: never the token, the server, the user name or a
/// title.
struct GitLabClient {
    private static let log = os.Logger(subsystem: "com.kannu.app", category: "Tasks")

    let reader: GitLabReader

    init(session: URLSession = IntegrationHTTP.shared) {
        reader = GitLabReader(session: session)
    }

    func verify(_ credential: GitLabCredential) async -> GitLabReader.VerifyResult {
        let result = await reader.verify(credential)
        switch result {
        case .verified(_, let scopes):
            Self.log.info("GitLab verify: ok, scopes known \(scopes != nil, privacy: .public)")
        case .failed(let failure):
            Self.log.notice("GitLab verify failed: \(String(describing: failure), privacy: .public)")
        }
        return result
    }

    func fetchItems(_ credential: GitLabCredential, username: String, includeMergeRequests: Bool) async -> GitLabReader.Fetch {
        let fetch = await reader.fetchItems(credential, username: username, includeMergeRequests: includeMergeRequests)
        if let failure = fetch.failure {
            Self.log.notice("GitLab fetch failed: \(String(describing: failure), privacy: .public)")
        }
        return fetch
    }
}

/// The GitLab credential in the Keychain. Every call runs on one serial queue, never on the
/// caller's thread: a Keychain read can show the SecurityAgent dialog (an interactive read, or an
/// item whose access list no longer matches this build) and blocks until it is answered — on the
/// main thread that freezes Kannu (docs/REGRESSIONS.md entry 11). Serial, so a save and a read
/// cannot cross. The same shape as `JiraCredentialStore`, for its own item.
enum GitLabCredentialStore {
    enum LoadResult: Equatable {
        case found(GitLabCredential)
        case missing
        /// The item is there, but macOS wants the user to approve the read.
        case needsApproval
        /// The item is there but could not be read or did not decode.
        case broken
    }

    private static let queue = DispatchQueue(label: "com.kannu.app.tasks.gitlab-keychain", qos: .userInitiated)

    private static func onQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// `allowInteraction: false` (a background sync) never shows the dialog; a read that would need
    /// it comes back `.needsApproval`, and the user's own click retries with `true`.
    static func load(allowInteraction: Bool) async -> LoadResult {
        await onQueue {
            let read = SecureSecretsStore.read(.gitlabCredential, allowInteraction: allowInteraction)
            if read.status == errSecItemNotFound { return .missing }
            if KeychainReader.needsUserApproval(read.status) { return .needsApproval }
            guard read.status == errSecSuccess, let value = read.value,
                  let credential = GitLabCredential.decoded(value) else { return .broken }
            return .found(credential)
        }
    }

    static func save(_ credential: GitLabCredential) async -> Bool {
        guard let encoded = credential.encoded() else { return false }
        return await onQueue { SecureSecretsStore.set(encoded, for: .gitlabCredential) }
    }

    /// False when the item is still there. Never discard it: the user was told the token is gone.
    static func remove() async -> Bool {
        await onQueue { SecureSecretsStore.removeValue(for: .gitlabCredential) }
    }
}
