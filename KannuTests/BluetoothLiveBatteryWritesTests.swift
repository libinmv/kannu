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

/// The rule that keeps a forced battery scan from reverting a live Bluetooth LE read that landed
/// while it was out fetching — and, just as important, keeps it able to lower a value as the battery
/// drains. Both directions matter: a "higher wins" merge would pin a stale peak forever, and a plain
/// wholesale replace is what introduced the bug this pins.
final class BluetoothLiveBatteryWritesTests: XCTestCase {
    private func write(_ level: Int, _ sequence: UInt64) -> BluetoothLiveBatteryWrite {
        BluetoothLiveBatteryWrite(level: level, sequence: sequence)
    }

    func testALiveWriteDuringTheScanSurvivesTheSnapshot() {
        let merged = BluetoothLiveBatteryWrites.overlaying(
            ["pods": 62],
            with: ["pods": write(81, 7)],
            newerThan: 5
        )
        XCTAssertEqual(merged["pods"], 81)
    }

    func testAScanStillLowersAValueWrittenBeforeItStarted() {
        // The drain case. The live read at sequence 5 predates the scan, so the scan is the newer
        // fact even though its number is smaller.
        let merged = BluetoothLiveBatteryWrites.overlaying(
            ["pods": 62],
            with: ["pods": write(81, 5)],
            newerThan: 5
        )
        XCTAssertEqual(merged["pods"], 62)
    }

    func testAWriteAtTheBaselineIsNotConsideredNewer() {
        let merged = BluetoothLiveBatteryWrites.overlaying(
            ["pods": 30],
            with: ["pods": write(90, 4)],
            newerThan: 4
        )
        XCTAssertEqual(merged["pods"], 30)
    }

    func testOnlyTheKeysThatMovedAreOverlaid() {
        let merged = BluetoothLiveBatteryWrites.overlaying(
            ["pods": 62, "beats": 40, "gone": 10],
            with: ["pods": write(81, 9), "beats": write(99, 2)],
            newerThan: 5
        )
        XCTAssertEqual(merged, ["pods": 81, "beats": 40, "gone": 10])
    }

    func testALiveWriteForAKeyTheScanNeverSawIsStillApplied() {
        // The scan can miss a device entirely — `system_profiler` reports battery only for devices
        // it managed to interrogate — and dropping the live value would blank a level that is known.
        let merged = BluetoothLiveBatteryWrites.overlaying(
            [:],
            with: ["pods": write(55, 1)],
            newerThan: 0
        )
        XCTAssertEqual(merged["pods"], 55)
    }

    func testAnEmptyKeyIsNeverIntroduced() {
        let merged = BluetoothLiveBatteryWrites.overlaying(
            ["pods": 62],
            with: ["": write(81, 9)],
            newerThan: 5
        )
        XCTAssertEqual(merged, ["pods": 62])
    }

    func testNoLiveWritesLeavesTheSnapshotExactlyAsCollected() {
        let collected = ["pods": 62, "beats": 41]
        XCTAssertEqual(
            BluetoothLiveBatteryWrites.overlaying(collected, with: [:], newerThan: 0),
            collected
        )
    }
}
