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

/// The Terms of Use the user accepts before Kannu does anything.
///
/// Kannu used to act the moment it launched — spawning helpers, raising permission prompts, writing
/// agent hooks into `~/.claude` and `~/.cursor` — with nothing anyone had agreed to. The only
/// disclaimer was the GPL on GitHub, and the licence never even shipped inside the app. The gate in
/// `AppDelegate.applicationDidFinishLaunching` now holds the whole launch until the current version
/// here has been accepted.
///
/// `TERMS.md` at the repository root is the one copy of the text: bundled into the app, shown by the
/// gate, linked from About and published on the website. Its `Version N` line and `currentVersion`
/// are pinned together by `TermsOfUseTests`.
enum TermsOfUse {
    /// Bump this — and the `Version` line in `TERMS.md` — for any change the user should see again.
    /// Every user whose accepted version is lower is shown the gate at their next launch.
    static let currentVersion = 1

    /// Resource names in the app bundle. `LICENSE` and `NOTICE` have no extension.
    static let termsResource = (name: "TERMS", extension: "md")
    static let licenseResource = (name: "LICENSE", extension: "")
    static let noticeResource = (name: "NOTICE", extension: "")

    /// Whether a user who accepted `acceptedVersion` may use Kannu without seeing the gate. Nil means
    /// they never accepted anything — every install from before the gate existed.
    static func isAccepted(acceptedVersion: Int?) -> Bool {
        guard let acceptedVersion else { return false }
        return acceptedVersion >= currentVersion
    }

    /// The `Version N` a terms document declares, or nil. Used by the test that keeps the text and the
    /// constant in step, so a bumped text can never ship with a stale constant or the reverse.
    static func declaredVersion(in text: String) -> Int? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(6) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Version ") else { continue }
            let digits = trimmed.dropFirst("Version ".count).prefix { $0.isNumber }
            return Int(digits)
        }
        return nil
    }
}
