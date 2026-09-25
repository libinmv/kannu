//
//  TranscriptListingInvalidationTests.swift
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

import CoreServices
import XCTest

/// Which FSEvents drop the cached transcript lists. An append to a running chat or a hook status
/// write must not (that re-walked both project trees on the main actor on every event); a
/// transcript appearing, disappearing or moving, or lost events, must.
final class TranscriptListingInvalidationTests: XCTestCase {
    typealias R = TranscriptListingInvalidation

    private let roots = ["/Users/me/.claude/projects", "/Users/me/.cursor/projects/"]
    private let modified = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)

    func testFlagValuesMatchCoreServices() {
        XCTAssertEqual(R.mustScanSubDirs, UInt32(kFSEventStreamEventFlagMustScanSubDirs))
        XCTAssertEqual(R.userDropped, UInt32(kFSEventStreamEventFlagUserDropped))
        XCTAssertEqual(R.kernelDropped, UInt32(kFSEventStreamEventFlagKernelDropped))
        XCTAssertEqual(R.rootChanged, UInt32(kFSEventStreamEventFlagRootChanged))
        XCTAssertEqual(R.itemCreated, UInt32(kFSEventStreamEventFlagItemCreated))
        XCTAssertEqual(R.itemRemoved, UInt32(kFSEventStreamEventFlagItemRemoved))
        XCTAssertEqual(R.itemRenamed, UInt32(kFSEventStreamEventFlagItemRenamed))
    }

    func testAnAppendToATranscriptKeepsTheLists() {
        let events = [(path: "/Users/me/.claude/projects/-Users-me-app/abc.jsonl", flags: modified)]
        XCTAssertFalse(R.shouldInvalidate(events: events, transcriptRoots: roots))
    }

    func testANewTranscriptDropsTheLists() {
        let created = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
        XCTAssertTrue(R.shouldInvalidate(events: [(path: "/Users/me/.claude/projects/-Users-me-app/new.jsonl", flags: created)],
                                         transcriptRoots: roots))
        // A root given with a trailing slash still matches.
        XCTAssertTrue(R.shouldInvalidate(events: [(path: "/Users/me/.cursor/projects/x/agent-transcripts/a.jsonl", flags: created)],
                                         transcriptRoots: roots))
    }

    func testRemovedAndRenamedTranscriptsDropTheLists() {
        let path = "/Users/me/.cursor/projects/x/agent-transcripts/a.jsonl"
        XCTAssertTrue(R.shouldInvalidate(events: [(path: path, flags: UInt32(kFSEventStreamEventFlagItemRemoved))], transcriptRoots: roots))
        XCTAssertTrue(R.shouldInvalidate(events: [(path: path, flags: UInt32(kFSEventStreamEventFlagItemRenamed))], transcriptRoots: roots))
    }

    func testHookStatusWritesKeepTheLists() {
        // The hook writes a temporary file and renames it over the status file.
        let events = [
            (path: "/Users/me/.kannu/agent-status/.claude-abc.json.tmp", flags: UInt32(kFSEventStreamEventFlagItemCreated)),
            (path: "/Users/me/.kannu/agent-status/claude-abc.json", flags: UInt32(kFSEventStreamEventFlagItemRenamed)),
        ]
        XCTAssertFalse(R.shouldInvalidate(events: events, transcriptRoots: roots))
    }

    func testASiblingDirectoryWithTheSamePrefixIsNotARoot() {
        let created = UInt32(kFSEventStreamEventFlagItemCreated)
        XCTAssertFalse(R.shouldInvalidate(events: [(path: "/Users/me/.claude/projects-old/a.jsonl", flags: created)],
                                          transcriptRoots: roots))
    }

    func testLostEventsDropTheListsWhereverTheyArePointed() {
        for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped,
                     kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagRootChanged] {
            XCTAssertTrue(R.shouldInvalidate(events: [(path: "/Users/me/.kannu/agent-status", flags: UInt32(flag))],
                                             transcriptRoots: roots))
        }
    }

    func testOneListingEventInABatchIsEnough() {
        let events = [
            (path: "/Users/me/.claude/projects/p/a.jsonl", flags: modified),
            (path: "/Users/me/.claude/projects/p/b.jsonl", flags: UInt32(kFSEventStreamEventFlagItemCreated)),
        ]
        XCTAssertTrue(R.shouldInvalidate(events: events, transcriptRoots: roots))
        XCTAssertFalse(R.shouldInvalidate(events: [], transcriptRoots: roots))
    }
}
