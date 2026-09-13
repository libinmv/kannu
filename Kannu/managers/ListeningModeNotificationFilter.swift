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

/// Decides whether a distributed notification might be an AirPods listening-mode change.
///
/// Kannu registers a `name: nil, object: nil` observer, so **every** distributed notification posted
/// anywhere on the system reaches this. That wildcard is deliberate and must stay: the notifications
/// that actually carry a listening-mode change are undocumented and vary by macOS release, so the
/// payload arm is the discovery mechanism. Narrowing it to a fixed name list would silently kill
/// listening-mode detection on a future release, with no error to notice.
///
/// What was wasteful is the work done per notification. The handler used to join *and* lowercase the
/// whole `userInfo` dictionary into one string before deciding it was uninteresting — an allocation
/// per system notification, for a feature the user may not have on. So: check the cheap name arm
/// first, bail immediately when there is no payload (most system notifications carry none), and scan
/// case-insensitively per entry with short-circuiting instead of materialising a lowercased copy.
enum ListeningModeNotificationFilter {
    /// The one name fragment worth matching. Broader than the explicit
    /// `com.apple.controlcenter.airpodspro.settingschanged` observer, so it also catches sibling
    /// Control Center names Apple has not shipped yet.
    ///
    /// The handler used to also match `airpodspro.settingschanged` and `audioaccessory.prefschanged`,
    /// both of which are already registered as explicit observers with their own handler — so those
    /// arms only ever produced a second refresh for a notification already handled.
    static let nameFragment = "controlcenter.airpods"

    /// Words that appear in a listening-mode payload. `lsnm` is Apple's own key for it.
    static let payloadFragments = [
        "listening", "lsnm", "noisecontrol", "anc", "transparency", "adaptive", "conversation"
    ]

    static func isPotentialListeningModeChange(name: String, userInfo: [AnyHashable: Any]?) -> Bool {
        if name.range(of: nameFragment, options: .caseInsensitive) != nil { return true }

        // The overwhelming majority of system distributed notifications carry no payload at all.
        // Answering those here is what makes the wildcard observer affordable.
        guard let userInfo, !userInfo.isEmpty else { return false }

        return userInfo.contains { key, value in
            matchesPayloadFragment("\(key)") || matchesPayloadFragment("\(value)")
        }
    }

    private static func matchesPayloadFragment(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return payloadFragments.contains { text.range(of: $0, options: .caseInsensitive) != nil }
    }
}
