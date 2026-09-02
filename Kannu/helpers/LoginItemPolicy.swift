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

/// When Kannu may touch the "launch at login" registration on the user's behalf.
///
/// The Settings toggle is always authoritative: it reflects live `SMAppService` state, and these
/// rules exist so the app can set a sensible default *once* without ever overriding a choice the
/// user made afterwards. Pure and Foundation-only so `LoginItemPolicyTests` can pin every rule.
enum LoginItemPolicy {
    /// True only for the one-time default on a fresh install.
    ///
    /// Gated on `hasAutoEnabledBefore` rather than on the current state: a user who switches the
    /// toggle off must stay off forever, and an app that silently re-registers itself after an
    /// opt-out is exactly the behaviour people are right to resent.
    static func shouldAutoEnable(
        isInstalled: Bool,
        hasAutoEnabledBefore: Bool,
        isCurrentlyRegistered: Bool
    ) -> Bool {
        guard isInstalled else { return false }        // never pin a build-folder path
        guard !hasAutoEnabledBefore else { return false } // one time, ever
        return !isCurrentlyRegistered
    }

    /// True when an already-enabled login item points at a stale bundle path and must be
    /// re-registered from the copy running now.
    ///
    /// `SMAppService.mainApp` pins whichever bundle called `register()`, so moving or reinstalling
    /// the app leaves the OS launching the old path. Repairing is deliberately conditional on the
    /// path having changed: the previous implementation unregistered and re-registered on *every*
    /// launch, so one transient failure silently lost launch-at-login for good.
    static func shouldRepairRegistration(
        isInstalled: Bool,
        isEnabled: Bool,
        currentPath: String,
        lastRegisteredPath: String
    ) -> Bool {
        guard isInstalled else { return false }
        guard isEnabled else { return false }  // never turns a disabled item back on
        return currentPath != lastRegisteredPath
    }
}
