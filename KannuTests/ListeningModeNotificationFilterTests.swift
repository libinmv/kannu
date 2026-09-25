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

/// Which distributed notifications are worth a listening-mode refresh.
///
/// The point of these is the pair of properties that pull in opposite directions: the payload arm has
/// to stay broad, because it is how Kannu finds notifications Apple has not documented, and the
/// common case — a system notification with no payload — has to cost nothing.
final class ListeningModeNotificationFilterTests: XCTestCase {
    private func matches(_ name: String, _ userInfo: [AnyHashable: Any]? = nil) -> Bool {
        ListeningModeNotificationFilter.isPotentialListeningModeChange(name: name, userInfo: userInfo)
    }

    func testAPayloadlessSystemNotificationIsRejected() {
        // The overwhelming majority. Every distributed notification on the system arrives here.
        XCTAssertFalse(matches("com.apple.screenIsUnlocked"))
        XCTAssertFalse(matches("com.apple.iTunes.playerInfo", [:]))
    }

    func testAControlCenterAirPodsNameMatchesWithoutAPayload() {
        XCTAssertTrue(matches("com.apple.controlcenter.airpodspro.settingschanged"))
        // Broader than the explicit observer on purpose, so a sibling name still lands.
        XCTAssertTrue(matches("com.apple.controlcenter.airpods.somethingNew"))
    }

    func testTheNameArmIsCaseInsensitive() {
        XCTAssertTrue(matches("com.apple.ControlCenter.AirPods.Changed"))
    }

    func testAnUnknownNameStillMatchesOnItsPayload() {
        // This is the discovery mechanism: the name is undocumented and release-dependent, so a
        // fixed name list would silently stop detecting listening mode on a future macOS.
        XCTAssertTrue(matches("com.apple.some.undocumented.event", ["LSNM": 2]))
        XCTAssertTrue(matches("com.apple.some.undocumented.event", ["mode": "NoiseControl"]))
        XCTAssertTrue(matches("com.apple.some.undocumented.event", ["listeningMode": 1]))
    }

    func testAPayloadFragmentIsMatchedInEitherKeyOrValue() {
        XCTAssertTrue(matches("x", ["transparency": 1]))
        XCTAssertTrue(matches("x", ["setting": "adaptive"]))
    }

    func testAPayloadFragmentMatchIsCaseInsensitive() {
        XCTAssertTrue(matches("x", ["ConversationAwareness": true]))
        XCTAssertTrue(matches("x", ["k": "ANC"]))
    }

    func testAnUnrelatedPayloadIsRejected() {
        XCTAssertFalse(matches("com.apple.something", ["volume": 0.4, "device": "Speakers"]))
    }

    func testTheTwoRedundantNameFragmentsAreGone() {
        // `airpodspro.settingschanged` and `audioaccessory.prefschanged` are already registered as
        // explicit observers with their own handler, so matching them here only ever produced a
        // second refresh for a notification already handled. `com.apple.AudioAccessory.prefsChanged`
        // must therefore not match on its name alone.
        XCTAssertFalse(matches("com.apple.AudioAccessory.prefsChanged"))
        // ...but it still matches when it actually carries a mode, which is the case that matters.
        XCTAssertTrue(matches("com.apple.AudioAccessory.prefsChanged", ["lsnm": 1]))
    }
}
