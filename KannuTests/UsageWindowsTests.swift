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

/// The file cutoff that lets the usage aggregator skip transcripts, and the ordering that keeps it
/// safe.
///
/// The dangerous failure here is silent: a cutoff narrower than any reported window truncates that
/// window's total with no error, no log line, and no symptom beyond a number that is quietly too
/// small. The ordering assertions below are the whole point — they fail the build if a wider window is
/// ever added without widening the cutoff.
final class UsageWindowsTests: XCTestCase {
    func testTheFileCutoffCoversEveryReportedWindow() {
        XCTAssertGreaterThanOrEqual(UsageWindows.fileScanLookback, UsageWindows.week)
        XCTAssertGreaterThanOrEqual(UsageWindows.fileScanLookback, UsageWindows.session)
        // The block history is appended behind the week guard, so it cannot reach further back — but
        // assert it directly, because that is a property of the aggregator, not of this file.
        XCTAssertGreaterThanOrEqual(UsageWindows.fileScanLookback, ClaudeSessionBlocks.blockLength)
    }

    func testTheCutoffIsWiderThanTheWidestWindow() {
        // Slack for DST, a corrected clock, and files written by another machine. If these are ever
        // equal, an mtime a second stale drops a file that still holds in-window records.
        XCTAssertGreaterThan(UsageWindows.fileScanLookback, UsageWindows.week)
    }

    func testARecentFileIsScanned() {
        let now = Date(timeIntervalSince1970: 1_757_000_000)
        XCTAssertTrue(UsageWindows.shouldScan(modifiedAt: now, now: now))
        XCTAssertTrue(UsageWindows.shouldScan(modifiedAt: now.addingTimeInterval(-3600), now: now))
    }

    func testAFileJustInsideTheCutoffIsScanned() {
        let now = Date(timeIntervalSince1970: 1_757_000_000)
        let edge = now.addingTimeInterval(-UsageWindows.fileScanLookback)
        XCTAssertTrue(UsageWindows.shouldScan(modifiedAt: edge, now: now))
        XCTAssertTrue(UsageWindows.shouldScan(modifiedAt: edge.addingTimeInterval(1), now: now))
    }

    func testAFileOutsideTheCutoffIsSkipped() {
        let now = Date(timeIntervalSince1970: 1_757_000_000)
        let stale = now.addingTimeInterval(-UsageWindows.fileScanLookback - 1)
        XCTAssertFalse(UsageWindows.shouldScan(modifiedAt: stale, now: now))
        XCTAssertFalse(UsageWindows.shouldScan(modifiedAt: now.addingTimeInterval(-90 * 86400), now: now))
    }

    func testAnUnknownModificationTimeIsScanned() {
        // A failed `stat` proves nothing, and the point is to skip only what can be proven irrelevant.
        XCTAssertTrue(UsageWindows.shouldScan(modifiedAt: nil, now: Date(timeIntervalSince1970: 1_757_000_000)))
    }

    func testAFutureModificationTimeIsScanned() {
        // Clock skew, or a file copied from a machine running ahead of this one.
        let now = Date(timeIntervalSince1970: 1_757_000_000)
        XCTAssertTrue(UsageWindows.shouldScan(modifiedAt: now.addingTimeInterval(86400), now: now))
    }
}
