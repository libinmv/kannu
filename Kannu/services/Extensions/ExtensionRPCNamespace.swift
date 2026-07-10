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

/// Dual-namespace support for extension JSON-RPC methods and notifications.
/// Existing clients continue using `atoll.*`; new clients may call `kannu.*`.
enum ExtensionRPCNamespace {
    static let legacyPrefix = "atoll."
    static let preferredPrefix = "kannu."

    private static let knownSuffixes: Set<String> = [
        "getVersion",
        "requestAuthorization",
        "checkAuthorization",
        "presentLiveActivity",
        "updateLiveActivity",
        "dismissLiveActivity",
        "presentLockScreenWidget",
        "updateLockScreenWidget",
        "dismissLockScreenWidget",
        "presentNotchExperience",
        "updateNotchExperience",
        "dismissNotchExperience",
        "getShelfItems",
        "getShelfItemData",
        "showFilePicker",
        "shareShelfItems",
        "addFilesToShelf",
        "subscribeShelfEvents",
        "activityDidDismiss",
        "widgetDidDismiss",
        "notchExperienceDidDismiss",
        "authorizationDidChange",
        "shelfItemsDidChange"
    ]

    /// Resolves `atoll.*` or `kannu.*` to the canonical legacy handler key (`atoll.*`).
    static func canonicalHandlerMethod(from method: String) -> String? {
        guard let suffix = methodSuffix(from: method) else { return nil }
        return legacyPrefix + suffix
    }

    static func isAuthorizationHandshake(_ method: String) -> Bool {
        canonicalHandlerMethod(from: method) == legacyPrefix + "requestAuthorization"
    }

    /// Returns both legacy and preferred notification method names for dual emit.
    static func notificationMethods(legacyMethod: String) -> [String] {
        guard legacyMethod.hasPrefix(legacyPrefix),
              let suffix = methodSuffix(from: legacyMethod) else {
            return [legacyMethod]
        }
        return [legacyMethod, preferredPrefix + suffix]
    }

    @MainActor
    static func recordIncomingMethod(_ method: String) {
        if method.hasPrefix(preferredPrefix) {
            kannuCallCount += 1
        } else if method.hasPrefix(legacyPrefix) {
            atollCallCount += 1
        }
    }

    @MainActor private(set) static var atollCallCount = 0
    @MainActor private(set) static var kannuCallCount = 0

    /// Lightweight self-checks for namespace aliasing. Returns empty when valid.
    static func verificationErrors() -> [String] {
        var errors: [String] = []

        let requestPairs: [(String, String)] = [
            ("atoll.getVersion", "atoll.getVersion"),
            ("kannu.getVersion", "atoll.getVersion"),
            ("kannu.presentLiveActivity", "atoll.presentLiveActivity"),
            ("kannu.unknownMethod", "atoll.unknownMethod")
        ]

        for (input, expected) in requestPairs {
            let resolved = canonicalHandlerMethod(from: input)
            if input == "kannu.unknownMethod" {
                if resolved != nil {
                    errors.append("Expected nil for unknown method, got \(resolved ?? "nil")")
                }
            } else if resolved != expected {
                errors.append("Expected \(expected) for \(input), got \(resolved ?? "nil")")
            }
        }

        let notifications = notificationMethods(legacyMethod: "atoll.activityDidDismiss")
        if notifications != ["atoll.activityDidDismiss", "kannu.activityDidDismiss"] {
            errors.append("Unexpected notification alias list: \(notifications)")
        }

        if !isAuthorizationHandshake("kannu.requestAuthorization") {
            errors.append("kannu.requestAuthorization should be treated as authorization handshake")
        }

        return errors
    }

    private static func methodSuffix(from method: String) -> String? {
        let suffix: String
        if method.hasPrefix(legacyPrefix) {
            suffix = String(method.dropFirst(legacyPrefix.count))
        } else if method.hasPrefix(preferredPrefix) {
            suffix = String(method.dropFirst(preferredPrefix.count))
        } else {
            return nil
        }

        guard knownSuffixes.contains(suffix) else { return nil }
        return suffix
    }
}
