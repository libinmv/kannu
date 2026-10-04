//
//  RescanStormTests.swift
//  KannuTests
//
//  Copyright (C) 2026 Kannu contributors
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import XCTest

/// While agents work, the watched folders change several times a second. Kannu rescans only for
/// changes it reads, and never more often than a floor (docs/REGRESSIONS.md entry 11, 2026-10-04
/// addendum): it measured 4–13 main-actor rescans a second during a parallel workflow.
final class RescanStormTests: XCTestCase {
    typealias W = AgentWatchEvents
    typealias P = AgentRescanPacing
    private let claude = "/Users/u/.claude/projects"
    private let status = "/Users/u/.kannu/agent-status"
    private let modified: UInt32 = 0x0000_1000
    private let created = TranscriptListingInvalidation.itemCreated

    private func worth(_ path: String, _ flags: UInt32? = nil) -> Bool {
        !W.worthARescan([(path, flags ?? modified)], claudeProjectsRoot: claude, statusDirectory: status).isEmpty
    }

    // MARK: - What is worth a rescan

    func testAMainTranscriptAndANewProjectAreWorthARescan() {
        XCTAssertTrue(worth(claude + "/-Users-u-kannu/c25f8dc0.jsonl"), "the passive tail and the title live here")
        XCTAssertTrue(worth(claude + "/-Users-u-kannu/c25f8dc0.jsonl", created))
        XCTAssertTrue(worth(claude + "/-Users-u-kannu", created))
    }

    func testFilesInsideASessionsFolderAreNot() {
        for deep in ["/-Users-u-kannu/c25f8dc0/subagents/agent-a81715c5767d62bfe.jsonl",
                     "/-Users-u-kannu/c25f8dc0/subagents/agent-a81715c5767d62bfe.meta.json",
                     "/-Users-u-kannu/c25f8dc0/subagents/workflows/wf_1/agent-a1.jsonl",
                     "/-Users-u-kannu/c25f8dc0/tool-results/toolu_01.txt",
                     "/-Users-u-kannu/c25f8dc0/workflows/scripts/review.js"] {
            XCTAssertFalse(worth(claude + deep), deep)
            XCTAssertFalse(worth(claude + deep, created), "nor their creation: " + deep)
        }
    }

    func testHookWritesAreTheKqueueWatchersNotFSEvents() {
        XCTAssertFalse(worth(status + "/claude-c25f8dc0.json"))
        XCTAssertFalse(worth(status + "/.kannu-input.Ab12Cd"))
        XCTAssertTrue(worth(status, TranscriptListingInvalidation.itemRemoved), "the folder itself going away still counts")
    }

    func testLostEventsAlwaysCountAndOtherRootsAreUntouched() {
        XCTAssertTrue(worth(claude + "/-Users-u-kannu/c25f8dc0/subagents/agent-a.jsonl", TranscriptListingInvalidation.mustScanSubDirs))
        XCTAssertTrue(worth(status + "/claude-x.json", TranscriptListingInvalidation.kernelDropped))
        XCTAssertTrue(worth("/Users/u/.cursor/projects/p/agent-transcripts/a/b/c.jsonl"))
        XCTAssertTrue(worth("/Users/u/.claude/sessions/7215.json"), "Claude's own busy and idle")
        XCTAssertTrue(worth("/Users/u/.claude/projects-old/a/b/c/d.jsonl"), "a sibling with the same prefix is not the root")
    }

    func testABatchKeepsOnlyWhatCounts() {
        let batch: [(path: String, flags: UInt32)] = [
            (claude + "/p/s/subagents/agent-a.jsonl", modified),
            (claude + "/p/s.jsonl", modified),
            (status + "/claude-s.json", modified),
        ]
        let kept = W.worthARescan(batch, claudeProjectsRoot: claude + "/", statusDirectory: status + "/")
        XCTAssertEqual(kept.map(\.path), [claude + "/p/s.jsonl"], "trailing slashes on the roots change nothing")
    }

    // MARK: - Pacing

    private let t0 = Date(timeIntervalSince1970: 1_788_000_000)

    func testTheFirstRequestRunsAfterItsOwnDelay() {
        XCTAssertEqual(P.startDate(requestedAt: t0, delay: 0.35, lastStart: nil, floor: P.fullFloor), t0.addingTimeInterval(0.35))
        XCTAssertEqual(P.startDate(requestedAt: t0, delay: -1, lastStart: nil, floor: P.fullFloor), t0)
    }

    func testARequestSoonAfterARescanWaitsForTheFloor() {
        let last = t0.addingTimeInterval(-0.1)
        XCTAssertEqual(P.startDate(requestedAt: t0, delay: 0.05, lastStart: last, floor: P.hookOnlyFloor),
                       last.addingTimeInterval(P.hookOnlyFloor))
        XCTAssertEqual(P.startDate(requestedAt: t0, delay: 0.35, lastStart: t0.addingTimeInterval(-10), floor: P.fullFloor),
                       t0.addingTimeInterval(0.35), "long after, only the request's own delay")
    }

    func testARequestNeverPostponesThePendingRescan() {
        let pending = t0.addingTimeInterval(0.2)
        XCTAssertFalse(P.needsScheduling(start: t0.addingTimeInterval(0.4), pending: pending), "the pending one covers it")
        XCTAssertFalse(P.needsScheduling(start: pending, pending: pending))
        XCTAssertTrue(P.needsScheduling(start: t0.addingTimeInterval(0.1), pending: pending), "an earlier start replaces it")
        XCTAssertTrue(P.needsScheduling(start: t0, pending: nil))
    }

    /// Hook writes every 20 ms for 10 s: the light still updates, a bounded number of times, and
    /// never starves. The old debounce re-armed on every event, so a steady storm meant no rescan.
    func testAStormOfWritesRescansBoundedlyAndNeverStarves() {
        var lastStart: Date?
        var pending: Date?
        var starts: [Date] = []
        var now = t0
        let end = t0.addingTimeInterval(10)
        while now < end {
            if let due = pending, due <= now {
                starts.append(due)
                lastStart = due
                pending = nil
            }
            let start = P.startDate(requestedAt: now, delay: 0.05, lastStart: lastStart, floor: P.hookOnlyFloor)
            if P.needsScheduling(start: start, pending: pending) { pending = start }
            now = now.addingTimeInterval(0.02)
        }
        XCTAssertGreaterThanOrEqual(starts.count, 25, "updates keep flowing through the storm")
        XCTAssertLessThanOrEqual(starts.count, Int(10 / P.hookOnlyFloor) + 1)
        for (earlier, later) in zip(starts, starts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.timeIntervalSince(earlier), P.hookOnlyFloor - 1e-6, "Date keeps about a microsecond here")
        }
    }
}
