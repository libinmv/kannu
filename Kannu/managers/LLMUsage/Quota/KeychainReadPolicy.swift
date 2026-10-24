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

/// When Kannu may let macOS show its "allow access" dialog for another tool's keychain item.
///
/// Kannu reads sign-ins other tools keep in the login keychain: Codex's "Codex Auth" and
/// cursor-agent's "cursor-access-token". Kannu is not on those items' access lists, so a read that
/// is allowed to prompt shows the dialog. Automatic refreshes and the background poll must never do
/// that; only a refresh the user asked for, through the card's fix-it button, may.
///
/// Foundation-only, so the decision is pinned by `KeychainReadPolicyTests`. `KeychainReader` makes
/// the reads; the closures here are how callers hand them in.
enum KeychainReadPolicy {
    /// What one keychain read returned.
    struct Outcome: Equatable {
        var value: String?
        /// The item is there, but macOS wants the user to approve the read
        /// (`KeychainReader.needsUserApproval`).
        var needsApproval = false
    }

    enum Resolution: Equatable, Sendable {
        case found(String)
        /// Only the user can unblock the read, so the card offers its fix-it button.
        case needsApproval
        case missing

        var value: String? {
            if case .found(let value) = self { return value }
            return nil
        }
    }

    /// Reads silently first, then tries `fallback` (a source that never prompts, such as Cursor's
    /// state.vscdb), and only when `interactive` reads once more with the dialog allowed. A
    /// non-interactive call therefore never prompts, and an interactive one prompts at most once.
    static func resolve(
        interactive: Bool,
        fallback: () -> String? = { nil },
        read: (_ allowInteraction: Bool) -> Outcome
    ) -> Resolution {
        let silent = read(false)
        if let value = silent.value { return .found(value) }
        if let value = fallback() { return .found(value) }
        guard interactive else { return silent.needsApproval ? .needsApproval : .missing }
        let prompted = read(true)
        if let value = prompted.value { return .found(value) }
        // A denied dialog leaves the item where it was, so the button stays for another try.
        return silent.needsApproval || prompted.needsApproval ? .needsApproval : .missing
    }
}

/// One legacy plaintext secret's move from Defaults into Kannu's Keychain item, decided from a
/// silent read of that item (`SecureSecretsStore.migrateFromDefaultsIfNeeded`). An item that is
/// already there wins, readable or not, and the plaintext copy goes; the legacy value is stored
/// only where nothing is; anything else (a locked keychain, say) waits for the next launch.
enum LegacySecretMigration {
    enum Step: Equatable {
        case store
        case clearLegacy
        case retryNextLaunch
    }

    static func step(existingValue: String?, needsApproval: Bool, itemNotFound: Bool) -> Step {
        if let existingValue, !existingValue.isEmpty { return .clearLegacy }
        if needsApproval { return .clearLegacy }
        if itemNotFound || existingValue != nil { return .store }
        return .retryNextLaunch
    }
}

/// One credential read shared by everything a refresh does.
///
/// A Cursor refresh asks for its token from the quota guard, usage-summary, the connect fallback, the
/// events check and every events page: up to a dozen reads, each of which could reach the keychain.
/// Inside `withSingleRead` the first read is reused, including by nested scopes and child tasks
/// (task-locals are inherited). The scope is keyed by keychain service, so one credential's scope
/// never answers for another's.
enum CredentialReadScope {
    private struct Resolved: Sendable {
        let service: String
        let resolution: KeychainReadPolicy.Resolution
    }

    @TaskLocal private static var current: Resolved?

    static func withSingleRead<T>(
        service: String,
        read: () -> KeychainReadPolicy.Resolution,
        _ body: () async throws -> T
    ) async rethrows -> T {
        if current?.service == service { return try await body() }
        return try await $current.withValue(Resolved(service: service, resolution: read())) {
            try await body()
        }
    }

    /// The enclosing scope's resolution for `service`, or a fresh `read` outside one.
    static func resolution(
        service: String,
        orRead read: () -> KeychainReadPolicy.Resolution
    ) -> KeychainReadPolicy.Resolution {
        if let current, current.service == service { return current.resolution }
        return read()
    }
}
