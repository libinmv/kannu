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

import XCTest

/// Which permissions a feature may touch on its own, and which rows the Permissions step shows.
final class LaunchPermissionPolicyTests: XCTestCase {
    func testNothingUnansweredIsTouchedBeforeOnboardingIsDone() {
        XCTAssertFalse(LaunchPermissionPolicy.mayTouch(onboardingComplete: false, answer: .notAsked))
        XCTAssertFalse(LaunchPermissionPolicy.mayTouch(onboardingComplete: false, answer: .deferred))
        XCTAssertTrue(LaunchPermissionPolicy.mayTouch(onboardingComplete: false, answer: .asked),
                      "an answered permission raises no dialog")
    }

    func testAfterOnboardingANotNowStillWaits() {
        XCTAssertFalse(LaunchPermissionPolicy.mayTouch(onboardingComplete: true, answer: .deferred))
        XCTAssertTrue(LaunchPermissionPolicy.mayTouch(onboardingComplete: true, answer: .asked))
        XCTAssertTrue(LaunchPermissionPolicy.mayTouch(onboardingComplete: true, answer: .notAsked),
                      "a feature turned on later asks in context")
    }

    func testRowsFollowTheChosenFeatures() {
        let everything = LaunchPermissionPolicy.Features(systemHUD: true, downloads: true, lockScreenWeather: true,
                                                         controlsMusicApp: true, warpInstalled: true, appleNotesSync: true)
        XCTAssertEqual(LaunchPermissionPolicy.rows(for: everything),
                       [.accessibility, .bluetooth, .downloads, .location, .musicAutomation, .notesAutomation, .warp])

        let nothing = LaunchPermissionPolicy.Features(systemHUD: false, downloads: false, lockScreenWeather: false,
                                                      controlsMusicApp: false, warpInstalled: false)
        XCTAssertEqual(LaunchPermissionPolicy.rows(for: nothing), [.bluetooth],
                       "the Bluetooth device watcher runs whatever the settings say")

        var nowPlayingDefaults = everything
        nowPlayingDefaults.controlsMusicApp = false
        nowPlayingDefaults.warpInstalled = false
        nowPlayingDefaults.appleNotesSync = false
        XCTAssertEqual(LaunchPermissionPolicy.rows(for: nowPlayingDefaults),
                       [.accessibility, .bluetooth, .downloads, .location])
    }

    /// Notes sync is off unless the Notes step (or Brain) turns it on, and only then is "Control
    /// Notes" a row: a feature that is off never touches its permission.
    func testTheNotesRowFollowsTheNotesChoice() {
        var features = LaunchPermissionPolicy.Features(systemHUD: false, downloads: false, lockScreenWeather: false,
                                                       controlsMusicApp: false, warpInstalled: false)
        XCTAssertEqual(LaunchPermissionPolicy.rows(for: features), [.bluetooth], "off by default")
        features.appleNotesSync = true
        XCTAssertEqual(LaunchPermissionPolicy.rows(for: features), [.bluetooth, .notesAutomation])
    }

    func testOnboardingProgress() {
        XCTAssertFalse(OnboardingProgress.isComplete(completedVersion: 0))
        XCTAssertTrue(OnboardingProgress.isComplete(completedVersion: OnboardingProgress.currentVersion))
    }
}
