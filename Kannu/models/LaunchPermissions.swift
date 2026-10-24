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

/// A macOS permission Kannu's features touch on their own, which raises the system's prompt the
/// first time. A fresh install used to raise four of them in the same second as the welcome music;
/// now the onboarding's Permissions step asks for each one, and nothing else may touch them first.
enum LaunchPermission: String, CaseIterable, Identifiable {
    case accessibility
    case bluetooth
    case downloads
    case location
    /// Automation of the music app chosen as the source (Spotify or Apple Music).
    case musicAutomation
    /// Automation of Notes, for Apple Notes sync.
    case notesAutomation
    /// Warp's agent sessions, which live in another app's container.
    case warp

    var id: String { rawValue }
}

/// What Kannu knows of a permission without asking the system for it.
enum PermissionAnswer: Equatable {
    /// Neither the system nor the user has answered.
    case notAsked
    /// The system has an answer (allowed or not), or the user pressed Allow and the request ran:
    /// touching it again raises no prompt.
    case asked
    /// The user pressed Not now: its feature stays off until they allow it in Brain.
    case deferred
}

enum LaunchPermissionPolicy {
    /// Whether a feature may make the first touch that raises `permission`'s prompt. Before
    /// onboarding is complete only an answered permission may be touched, so nothing pops up over
    /// the onboarding window or the welcome music. After it, a deferred one still may not; one
    /// never asked may, because the user turned its feature on later, in context.
    static func mayTouch(onboardingComplete: Bool, answer: PermissionAnswer) -> Bool {
        switch answer {
        case .asked: return true
        case .deferred: return false
        case .notAsked: return onboardingComplete
        }
    }

    /// The features a fresh setup turned on, which decide the Permissions step's rows. A feature
    /// that is off never touches its permission, so its row is left out and macOS asks, in
    /// context, if the user turns it on later.
    struct Features: Equatable {
        var systemHUD: Bool
        var downloads: Bool
        var lockScreenWeather: Bool
        /// The music source is Spotify or Apple Music, which Kannu controls with Apple Events.
        var controlsMusicApp: Bool
        var warpInstalled: Bool
        /// Notes are on and sync with Apple Notes, which Kannu drives with Apple Events.
        var appleNotesSync: Bool = false
    }

    /// The Permissions step's rows, in order: only what the chosen features use. Bluetooth is
    /// always one: the device watcher behind headphone battery, the connect HUD and AirPods modes
    /// runs whatever the settings say.
    static func rows(for features: Features) -> [LaunchPermission] {
        var rows: [LaunchPermission] = []
        if features.systemHUD { rows.append(.accessibility) }
        rows.append(.bluetooth)
        if features.downloads { rows.append(.downloads) }
        if features.lockScreenWeather { rows.append(.location) }
        if features.controlsMusicApp { rows.append(.musicAutomation) }
        if features.appleNotesSync { rows.append(.notesAutomation) }
        if features.warpInstalled { rows.append(.warp) }
        return rows
    }
}

enum OnboardingProgress {
    /// Bumped when onboarding changes enough that everyone should see it again.
    static let currentVersion = 1
    /// The version an install from before versioning counts as having finished.
    static let firstVersion = 1

    static func isComplete(completedVersion: Int) -> Bool {
        completedVersion >= currentVersion
    }
}

extension Notification.Name {
    /// A permission was asked or deferred: features gated on it re-check whether they may start.
    static let launchPermissionsChanged = Notification.Name("launchPermissionsChanged")
}
