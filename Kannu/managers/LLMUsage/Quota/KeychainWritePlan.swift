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
import Security

/// How `KeychainReader` saves a secret, decided before any Security call is made.
///
/// A save used to update the existing item in place (`SecItemUpdate`, with `SecItemAdd` only when
/// nothing was there). An update keeps the item's access list, so an item someone pre-planted under
/// Kannu's service and account with a permissive list ("any application may read this") would have
/// received the user's API key and kept handing it to whoever planted it. A save now deletes the item
/// and adds a fresh one: `SecItemAdd` builds a new access list that trusts only the app creating the
/// item, so the list on a Kannu secret is always the one Kannu made. (2026-10-04)
///
/// Pure apart from the status constants, so `KeychainWritePlanTests` can pin every rule.
enum KeychainWritePlan: Equatable {
    /// Delete whatever sits at this service and account, then add the item fresh.
    case recreate
    /// Not Kannu's item. Other apps' credentials (Codex's "Codex Auth", Cursor's
    /// "cursor-access-token", Claude Code's "Claude Code-credentials") are read-only to Kannu.
    case refuse

    /// Every keychain service Kannu owns starts with this. The trailing dot keeps
    /// "com.kannu.application" and the bare prefix itself out.
    static let ownedServicePrefix = "com.kannu.app."

    static func forSaving(service: String) -> KeychainWritePlan {
        isKannuOwned(service: service) ? .recreate : .refuse
    }

    static func isKannuOwned(service: String) -> Bool {
        service.hasPrefix(ownedServicePrefix) && service.count > ownedServicePrefix.count
    }

    /// True when a delete left nothing behind at that service and account. Any other status
    /// (approval denied, keychain locked, a broken item) means an item may still be there: an add
    /// would fail as a duplicate, and updating that item is exactly what this plan exists to avoid,
    /// so the save stops there.
    static func deleteLeftNothing(_ status: OSStatus) -> Bool {
        status == errSecSuccess || status == errSecItemNotFound
    }

    /// The value a save puts back after its fresh add returned `addStatus`, given what the item held
    /// before the delete. Delete-then-add is not atomic: once the delete has run, a failed add leaves
    /// no item at all, and the secret the user already had would be gone after a relaunch — the old
    /// in-place update left it untouched on failure. So a failed add re-adds the prior value, through
    /// another fresh add with Kannu's own access list. Nil when the add succeeded or there was nothing
    /// to put back. (2026-10-04)
    static func valueToRestore(afterAdd addStatus: OSStatus, prior: String?) -> String? {
        addStatus == errSecSuccess ? nil : prior
    }
}
