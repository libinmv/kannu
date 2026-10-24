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

/// The decisions behind Apple Notes sync, Foundation-only so the logic target can test them.
/// `AppleNotesSyncManager` runs the AppleScript; this decides what a fetched note means.
enum AppleNotesMergePolicy {
    enum Decision: Equatable {
        /// Neither side changed since they last agreed.
        case unchanged
        /// Notes holds an edit Kannu has not seen.
        case takeRemote
        /// Kannu holds an edit Notes has not seen.
        case pushLocal
    }

    /// AppleScript dates count whole seconds, and the date Notes reports for a push can land in the
    /// same second as the local edit before it, a fraction earlier.
    static let clockTolerance: TimeInterval = 1

    /// What to do with a linked note. `syncedAt` is Notes' modification date as last read back,
    /// after a push or a pull: a side changed only if its date moved past it. Comparing the two
    /// dates with each other instead made every push look like a remote edit on the next sync, which
    /// re-stamped the note and moved it to the top of the list.
    static func decide(localModified: Date, remoteModified: Date, syncedAt: Date?) -> Decision {
        guard let syncedAt else {
            // Linked before the date was kept: the newer side wins, as it always did.
            if remoteModified > localModified.addingTimeInterval(clockTolerance) { return .takeRemote }
            if localModified > remoteModified.addingTimeInterval(clockTolerance) { return .pushLocal }
            return .unchanged
        }
        let horizon = syncedAt.addingTimeInterval(clockTolerance)
        switch (remoteModified > horizon, localModified > horizon) {
        case (false, false): return .unchanged
        case (true, false): return .takeRemote
        case (false, true): return .pushLocal
        case (true, true): return remoteModified > localModified ? .takeRemote : .pushLocal
        }
    }

    /// Whether a note fetched from Notes was made there, not in Kannu (`NoteItem.madeInAppleNotes`).
    /// Evidence that Kannu made it — its `kannu:id` tag, or a place in Notes' Kannu folder, where
    /// Kannu puts its own notes — always wins, so a note held read-only by mistake is freed on the
    /// next sync. Without evidence a decided note keeps its answer, and an undecided one counts as
    /// made in Notes: editing a note Kannu did not make rewrites it as plain text, so read-only is
    /// the safe guess.
    static func madeInAppleNotes(stored: Bool?, hasKannuId: Bool, inKannuFolder: Bool) -> Bool {
        if hasKannuId || inKannuFolder { return false }
        return stored ?? true
    }

    /// A date from `AppleNotesSyncManager`'s AppleScript `kannuStamp`: local calendar fields,
    /// `year month day hours minutes seconds`, read in `timeZone` (the Mac's, as AppleScript's
    /// dates are). Subtracting a "1970" date built from `current date` instead, as the scripts did
    /// before 2026-10-23, gave seconds since *local* midnight 1970 — off by the zone's offset — and
    /// `as string` rounded them to ten seconds.
    static func date(fromStamp raw: String, timeZone: TimeZone = .current) -> Date? {
        let parts = raw.split(separator: " ").compactMap { Int($0) }
        guard parts.count == 6 else { return nil }
        return DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: timeZone,
            year: parts[0], month: parts[1], day: parts[2],
            hour: parts[3], minute: parts[4], second: parts[5]
        ).date
    }

    /// The note's text from Notes' `plaintext`, which can begin with the note's name on a line of its
    /// own: that line is the title, not content.
    static func content(fromPlaintext plaintext: String, title: String) -> String {
        let parts = plaintext.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first,
              !title.isEmpty,
              first.trimmingCharacters(in: .whitespaces) == title.trimmingCharacters(in: .whitespaces) else {
            return plaintext
        }
        return parts.count > 1 ? String(parts[1]) : ""
    }

    /// A finished sync, applied to the notes as they are now rather than to the snapshot it started
    /// from: the AppleScript takes seconds, and assigning the snapshot's result dropped every edit
    /// made meanwhile.
    ///
    /// - A note edited since the snapshot keeps its current version (`keep` merges in what the sync
    ///   learned about it, such as a new remote id).
    /// - A note deleted since the snapshot stays deleted.
    /// - A note the sync dropped (gone from Notes) stays dropped, unless it was edited meanwhile, or
    ///   `dropMissing` says it goes regardless (a note made in Notes, outside a folder-only sync's
    ///   folder: the setting says its copy leaves, and an edit is pushed to Notes as it is made).
    /// - Notes the sync imported, and notes created meanwhile, are kept.
    static func reconcile<Note>(
        current: [Note],
        merged: [Note],
        snapshot: [UUID: Date],
        id: (Note) -> UUID,
        modified: (Note) -> Date,
        keep: (_ current: Note, _ merged: Note) -> Note,
        dropMissing: (_ current: Note) -> Bool = { _ in false }
    ) -> [Note] {
        let currentById = Dictionary(current.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        let mergedIds = Set(merged.map(id))
        var result: [Note] = []

        for note in merged {
            let noteId = id(note)
            guard let before = snapshot[noteId] else {
                result.append(note)
                continue
            }
            guard let now = currentById[noteId] else { continue }
            result.append(modified(now) == before ? note : keep(now, note))
        }
        for note in current where !mergedIds.contains(id(note)) {
            if dropMissing(note) { continue }
            if let before = snapshot[id(note)], modified(note) == before { continue }
            result.append(note)
        }
        return result
    }
}
