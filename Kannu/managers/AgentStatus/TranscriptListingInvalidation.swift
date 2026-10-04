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

/// Which FSEvents batches make the cached lists of recent transcripts stale.
///
/// The monitor used to drop both lists on every event — an append to a running chat's transcript,
/// a hook writing its status file — so each rescan walked `~/.claude/projects` and
/// `~/.cursor/projects` (hundreds to thousands of files) on the main actor, several times a second
/// while agents worked. Only a transcript appearing, disappearing or moving changes a list; an
/// append changes a file the list already holds, whose tail and head readers key on (mtime, size),
/// and an old chat coming back to life is picked up when the list's two-second lifetime runs out.
enum TranscriptListingInvalidation {
    // FSEventStreamEventFlags bits, named as in CoreServices (pinned against the SDK in the tests).
    static let mustScanSubDirs: UInt32 = 0x0000_0001
    static let userDropped: UInt32 = 0x0000_0002
    static let kernelDropped: UInt32 = 0x0000_0004
    static let rootChanged: UInt32 = 0x0000_0020
    static let itemCreated: UInt32 = 0x0000_0100
    static let itemRemoved: UInt32 = 0x0000_0200
    static let itemRenamed: UInt32 = 0x0000_0800

    /// Events whose details were lost: something may have changed anywhere.
    static let lostEventFlags = mustScanSubDirs | userDropped | kernelDropped | rootChanged
    /// Events that add, remove or move an item.
    static let listingEventFlags = itemCreated | itemRemoved | itemRenamed

    /// True when the batch may have added, removed or moved a transcript under one of the roots.
    static func shouldInvalidate(events: [(path: String, flags: UInt32)], transcriptRoots: [String]) -> Bool {
        let roots = transcriptRoots.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        return events.contains { event in
            if event.flags & lostEventFlags != 0 { return true }
            guard event.flags & listingEventFlags != 0 else { return false }
            return roots.contains { root in event.path == root || event.path.hasPrefix(root + "/") }
        }
    }
}

/// Which watched-file events are worth a rescan at all (docs/REGRESSIONS.md entry 11, 2026-10-04
/// addendum). A rescan runs on the main actor and reads every hook file, session record and live
/// transcript tail, and while agents work two kinds of event used to cost one each, several times a
/// second:
/// - **Files inside a Claude session's own folder** (`<project>/<session>/subagents/…`,
///   `tool-results/…`, `workflows/…`). Every subagent message, tool-output spill and workflow
///   script lands there. Kannu reads none of them; the main transcript is `<project>/<session>.jsonl`.
/// - **Per-file writes in the hook status folder.** The kqueue watcher on that folder already runs
///   a rescan for each, so the same write through FSEvents was a second one.
/// Lost-event flags (`TranscriptListingInvalidation.lostEventFlags`) always count: they say
/// nothing about where the change was.
enum AgentWatchEvents {
    static func worthARescan(_ events: [(path: String, flags: UInt32)], claudeProjectsRoot: String,
                             statusDirectory: String) -> [(path: String, flags: UInt32)] {
        let claudeRoot = trimmed(claudeProjectsRoot)
        let statusRoot = trimmed(statusDirectory)
        return events.filter { event in
            if event.flags & TranscriptListingInvalidation.lostEventFlags != 0 { return true }
            if event.path.hasPrefix(statusRoot + "/") { return false }
            guard event.path.hasPrefix(claudeRoot + "/") else { return true }
            let relative = event.path.dropFirst(claudeRoot.count + 1)
            return relative.split(separator: "/", omittingEmptySubsequences: true).count < 3
        }
    }

    private static func trimmed(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// When a requested rescan may start. Every rescan is at least a floor apart from the last one, a
/// full rescan's floor longer than a hook-only one's, and a request never postpones one already
/// pending: the pending rescan reads the files when it runs, so it covers the request, and
/// re-arming it on every event starved the light during a storm of writes.
enum AgentRescanPacing {
    static let hookOnlyFloor: TimeInterval = 0.3
    static let fullFloor: TimeInterval = 0.5

    static func startDate(requestedAt now: Date, delay: TimeInterval, lastStart: Date?, floor: TimeInterval) -> Date {
        let wanted = now.addingTimeInterval(max(0, delay))
        guard let lastStart else { return wanted }
        return max(wanted, lastStart.addingTimeInterval(floor))
    }

    /// Whether a request starting at `start` needs a new rescan scheduled, given the one pending.
    static func needsScheduling(start: Date, pending: Date?) -> Bool {
        guard let pending else { return true }
        return start < pending
    }
}
