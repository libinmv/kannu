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

/// Apple Notes sync decides what changed against the date Notes last reported, never by comparing
/// the two sides' dates with each other (which made every push look like a remote edit and moved the
/// note to the top), and a finished sync is applied to the notes as they are now.
final class AppleNotesMergePolicyTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    // MARK: - decide

    func testAPushReadBackIsNotARemoteEdit() {
        // Edited at 10.7, pushed; Notes reports 10 (whole seconds) and that is what was kept.
        XCTAssertEqual(AppleNotesMergePolicy.decide(localModified: at(10.7), remoteModified: at(10), syncedAt: at(10)), .unchanged)
        // Notes later reports a date a second past the push (it re-saved the note): still within the clock.
        XCTAssertEqual(AppleNotesMergePolicy.decide(localModified: at(10.7), remoteModified: at(11), syncedAt: at(10)), .unchanged)
    }

    func testAnEditOnOneSideGoesToTheOther() {
        XCTAssertEqual(AppleNotesMergePolicy.decide(localModified: at(10), remoteModified: at(60), syncedAt: at(10)), .takeRemote)
        XCTAssertEqual(AppleNotesMergePolicy.decide(localModified: at(60), remoteModified: at(10), syncedAt: at(10)), .pushLocal)
    }

    func testBothEditedTheNewerWins() {
        XCTAssertEqual(AppleNotesMergePolicy.decide(localModified: at(50), remoteModified: at(60), syncedAt: at(10)), .takeRemote)
        XCTAssertEqual(AppleNotesMergePolicy.decide(localModified: at(70), remoteModified: at(60), syncedAt: at(10)), .pushLocal)
    }

    func testANoteLinkedBeforeTheDateWasKeptComparesTheSides() {
        XCTAssertEqual(AppleNotesMergePolicy.decide(localModified: at(10), remoteModified: at(60), syncedAt: nil), .takeRemote)
        XCTAssertEqual(AppleNotesMergePolicy.decide(localModified: at(60), remoteModified: at(10), syncedAt: nil), .pushLocal)
        XCTAssertEqual(AppleNotesMergePolicy.decide(localModified: at(10.4), remoteModified: at(10), syncedAt: nil), .unchanged)
    }

    // MARK: - date(fromStamp:)

    func testAStampIsReadInTheMacsTimeZone() throws {
        let kolkata = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        // 15:17:06 on 2026-10-23 in +05:30 is 09:47:06 UTC.
        let date = try XCTUnwrap(AppleNotesMergePolicy.date(fromStamp: "2026 10 23 15 17 6", timeZone: kolkata))
        XCTAssertEqual(date, Date(timeIntervalSince1970: 1_792_748_826))
        XCTAssertNil(AppleNotesMergePolicy.date(fromStamp: "1.79276852E+9"), "the old seconds format is not a stamp")
        XCTAssertNil(AppleNotesMergePolicy.date(fromStamp: ""))
    }

    // MARK: - madeInAppleNotes

    func testKannusOwnEvidenceAlwaysFreesANote() {
        // Held read-only by mistake (the first folder check matched nothing): the next sync frees it.
        XCTAssertFalse(AppleNotesMergePolicy.madeInAppleNotes(stored: true, hasKannuId: false, inKannuFolder: true))
        XCTAssertFalse(AppleNotesMergePolicy.madeInAppleNotes(stored: true, hasKannuId: true, inKannuFolder: false))
        XCTAssertFalse(AppleNotesMergePolicy.madeInAppleNotes(stored: nil, hasKannuId: false, inKannuFolder: true))
    }

    func testWithoutEvidenceADecidedNoteKeepsItsAnswer() {
        // A Kannu note moved out of the folder in Notes, its tag gone, stays editable.
        XCTAssertFalse(AppleNotesMergePolicy.madeInAppleNotes(stored: false, hasKannuId: false, inKannuFolder: false))
        XCTAssertTrue(AppleNotesMergePolicy.madeInAppleNotes(stored: true, hasKannuId: false, inKannuFolder: false))
    }

    func testAnUndecidedNoteWithoutEvidenceIsReadOnly() {
        // Editing a note Kannu did not make rewrites it as plain text, so the safe guess is read-only.
        XCTAssertTrue(AppleNotesMergePolicy.madeInAppleNotes(stored: nil, hasKannuId: false, inKannuFolder: false))
    }

    // MARK: - content(fromPlaintext:)

    func testTheNameLineIsNotContent() {
        XCTAssertEqual(AppleNotesMergePolicy.content(fromPlaintext: "Groceries\nmilk\neggs", title: "Groceries"), "milk\neggs")
        XCTAssertEqual(AppleNotesMergePolicy.content(fromPlaintext: "Groceries", title: "Groceries"), "")
        XCTAssertEqual(AppleNotesMergePolicy.content(fromPlaintext: "milk\neggs", title: "Groceries"), "milk\neggs")
        XCTAssertEqual(AppleNotesMergePolicy.content(fromPlaintext: "milk", title: ""), "milk")
    }

    // MARK: - reconcile

    private struct Note: Equatable {
        var id: UUID
        var text: String
        var modified: Date
        var remoteId: String?
    }

    private func reconcile(current: [Note], merged: [Note], snapshot: [Note],
                           dropMissing: @escaping (Note) -> Bool = { _ in false }) -> [Note] {
        AppleNotesMergePolicy.reconcile(
            current: current,
            merged: merged,
            snapshot: Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0.modified) }),
            id: \.id,
            modified: \.modified,
            keep: { now, synced in
                var kept = now
                kept.remoteId = kept.remoteId ?? synced.remoteId
                return kept
            },
            dropMissing: dropMissing
        )
    }

    func testAnEditDuringTheSyncSurvivesIt() {
        let id = UUID()
        let before = Note(id: id, text: "a", modified: at(0), remoteId: nil)
        let edited = Note(id: id, text: "ab", modified: at(5), remoteId: nil)
        let synced = Note(id: id, text: "a", modified: at(0), remoteId: "x-coredata://1")
        let result = reconcile(current: [edited], merged: [synced], snapshot: [before])
        XCTAssertEqual(result, [Note(id: id, text: "ab", modified: at(5), remoteId: "x-coredata://1")],
                       "the edit wins, and keeps the remote id the sync gave it, so the next push updates")
    }

    func testAnUntouchedNoteTakesTheSyncedVersion() {
        let id = UUID()
        let before = Note(id: id, text: "a", modified: at(0))
        let synced = Note(id: id, text: "from Notes", modified: at(9), remoteId: "r")
        XCTAssertEqual(reconcile(current: [before], merged: [synced], snapshot: [before]), [synced])
    }

    func testDeletesAndCreatesDuringTheSyncStand() {
        let gone = Note(id: UUID(), text: "deleted meanwhile", modified: at(0))
        let created = Note(id: UUID(), text: "new meanwhile", modified: at(5))
        let imported = Note(id: UUID(), text: "from Notes", modified: at(1), remoteId: "r")
        let result = reconcile(current: [created], merged: [gone, imported], snapshot: [gone])
        XCTAssertEqual(result, [imported, created])
    }

    func testADroppedNoteStaysDroppedUnlessEditedMeanwhile() {
        let dropped = Note(id: UUID(), text: "gone from Notes", modified: at(0), remoteId: "r")
        XCTAssertEqual(reconcile(current: [dropped], merged: [], snapshot: [dropped]), [])
        var edited = dropped
        edited.text = "edited meanwhile"
        edited.modified = at(5)
        XCTAssertEqual(reconcile(current: [edited], merged: [], snapshot: [dropped]), [edited])
    }

    /// Folder-only sync: a note made in Notes outside the folder leaves even when edited during the
    /// sync (`dropMissing`); every other note keeps the edit-survives rule, and a note the sync
    /// returned is never dropped.
    func testDropMissingOverridesTheEditOnlyForTheNotesItNames() {
        var outside = Note(id: UUID(), text: "made in Notes", modified: at(0), remoteId: "r")
        let before = outside
        outside.modified = at(5)
        var mine = Note(id: UUID(), text: "made in Kannu", modified: at(0), remoteId: "k")
        let mineBefore = mine
        mine.modified = at(5)
        let returned = Note(id: UUID(), text: "in the folder", modified: at(0), remoteId: "f")
        let result = reconcile(current: [outside, mine, returned], merged: [returned],
                               snapshot: [before, mineBefore, returned],
                               dropMissing: { $0.remoteId == "r" || $0.remoteId == "f" })
        XCTAssertEqual(result, [returned, mine])
    }
}
