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

/// Where a source's syncing stands (Jira Cloud, GitLab), for the Sources section. Each source has
/// its own, so one failing never shows on, or stops, the other.
enum SourceSyncState: Equatable {
    case idle
    case syncing
    /// `count` issues (or GitLab items) read; `complete` is false when there were more than Kannu
    /// fetches.
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

    /// One short line for the notch's Tasks popover, beside its Refresh: "Synced 10:42", "Offline",
    /// "Rate limited until 10:52". A problem the user has to act on points at Brain, whose Sources
    /// row says what to do. The popover's Refresh may ask macOS for the Keychain, so that is what a
    /// pending approval suggests.
    func shortCaption(now: Date) -> String {
        switch self {
        case .idle:
            return String(localized: "Not synced yet")
        case .syncing:
            return String(localized: "Syncing…")
        case .synced(let at, _, _):
            return String(localized: "Synced \(at.formatted(date: .omitted, time: .shortened))")
        case .offline:
            return String(localized: "Offline")
        case .rateLimited(let until):
            guard until > now else { return String(localized: "You can refresh again") }
            return String(localized: "Rate limited until \(until.formatted(date: .omitted, time: .shortened))")
        case .authFailed:
            return String(localized: "Token rejected: reconnect in Brain")
        case .needsKeychainApproval:
            return String(localized: "Refresh to allow Keychain access")
        case .needsReconnect:
            return String(localized: "Reconnect in Brain")
        case .failed:
            return String(localized: "Not synced: see Brain")
        }
    }

    /// When a running rate limit ends, so a view can redraw then, and only then.
    var rateLimitEnd: Date? {
        if case .rateLimited(let until) = self { return until }
        return nil
    }

    /// Whether the Tasks page appearing may start a sync on its own, `lastSuccess` being when the
    /// last sync succeeded: only when that is at least `staleAfter` ago, and no rate limit is running.
    ///
    /// Never after the source refused the token or the saved sign-in needs reconnecting. The page
    /// appears often — each visit, and each time its row scrolls back into view — and sending a
    /// refused token again every time can lock the account: Atlassian puts it behind a CAPTCHA,
    /// which also stops the user's other API-token clients, and GitLab bans the address after
    /// repeated failed sign-ins. Only the user's Refresh or Allow Keychain Access, or a new Connect,
    /// tries again.
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
