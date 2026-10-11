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

/// Where Jira syncing stands, for the Sources section.
enum JiraSyncState: Equatable {
    case idle
    case syncing
    /// `count` issues read; `complete` is false when there were more than Kannu fetches.
    case synced(at: Date, count: Int, complete: Bool)
    case offline
    /// Refresh is off until then.
    case rateLimited(until: Date)
    /// The token was refused.
    case authFailed(status: Int)
    /// macOS wants the user to approve reading the saved token.
    case needsKeychainApproval
    /// The saved sign-in is missing, unreadable, or for another site than the one shown.
    case needsReconnect
    case failed(String)

    /// Whether the Tasks page appearing may start a sync on its own, `lastSuccess` being when the
    /// last sync succeeded: only when that is at least `staleAfter` ago, and no rate limit is running.
    ///
    /// Never after Jira refused the token or the saved sign-in needs reconnecting. The page appears
    /// often — each visit, and each time its row scrolls back into view — and sending a refused
    /// token again every time can lock the Atlassian account behind a CAPTCHA, which also stops the
    /// user's other API-token clients. Only the user's Refresh or Allow Keychain Access, or a new
    /// Connect, tries again.
    func allowsSyncOnAppear(lastSuccess: Date?, now: Date, staleAfter: TimeInterval) -> Bool {
        switch self {
        case .authFailed, .needsReconnect:
            return false
        case .rateLimited(let until) where until > now:
            return false
        default:
            break
        }
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= staleAfter
    }
}
