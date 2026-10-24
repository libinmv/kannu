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
import Defaults
import os

#if canImport(AppKit)
import AppKit
#endif

enum AppleNotesSyncError: LocalizedError {
    case automationDenied
    case automationPostponed
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .automationDenied:
            return String(localized: "Allow Kannu to control Notes in System Settings → Privacy & Security → Automation.")
        case .automationPostponed:
            return String(localized: "Allow Kannu to control Notes in Brain › General › Permissions.")
        case .scriptFailed(let message):
            return message
        }
    }
}

struct RemoteAppleNote: Sendable {
    let id: String
    let title: String
    let content: String
    let creationDate: Date
    let modificationDate: Date
    let kannuId: UUID?
    /// In Notes' Kannu folder, where the notes Kannu makes go.
    let inKannuFolder: Bool
}

@MainActor
final class AppleNotesSyncManager: ObservableObject {
    static let shared = AppleNotesSyncManager()

    @Published private(set) var isSyncing = false
    @Published private(set) var lastError: String?
    /// Counts only, never a title, a folder name or note text.
    private let logger = os.Logger(subsystem: "com.kannu.app", category: "AppleNotesSync")

    private static let syncFolderName = "Kannu"
    private static let fieldSeparator = "\u{241F}"
    private static let recordSeparator = "\u{241E}"
    private static let kannuTagPattern = #"<!--(?:kannu|atoll):id=([0-9A-Fa-f-]{36})-->"#

    /// The last queued AppleScript operation. Every sync, push and delete waits for the one before
    /// it: autosave pushes every 1.5 s, and a second push that started before the first one's create
    /// returned made a second Apple note for the same Kannu note.
    private var queueTail: Task<Void, Never>?
    /// Apple Notes ids by Kannu note id, filled the moment a create returns, so a push or delete
    /// queued behind it finds the note it made before the id has reached `savedNotes`.
    private var remoteIdByNoteId: [UUID: String] = [:]

    private init() {}

    /// Every AppleScript here raises Notes' Automation dialog the first time. Before onboarding's
    /// Permissions step, or after its Not now, nothing runs (AGENTS.md: no dialog before the
    /// Permissions step, none after a Not now).
    private var mayTouchNotes: Bool {
        guard LaunchPermissionManager.mayTouch(.notesAutomation) else {
            lastError = AppleNotesSyncError.automationPostponed.localizedDescription
            return false
        }
        return true
    }

    @discardableResult
    func sync(localNotes: [NoteItem]) async -> [NoteItem]? {
        guard Defaults[.enableAppleNotesSync] else { return nil }
        guard !isSyncing, mayTouchNotes else { return nil }
        let scope = Defaults[.appleNotesSyncScope]

        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        return await enqueue { [self] in
            do {
                let remoteNotes = try await fetchRemoteNotes(scope: scope)
                logger.info("Apple Notes fetched \(remoteNotes.count, privacy: .public): in the Kannu folder \(remoteNotes.filter(\.inKannuFolder).count, privacy: .public), tagged \(remoteNotes.filter { $0.kannuId != nil }.count, privacy: .public)")
                var merged = try await merge(localNotes: localNotes, remoteNotes: remoteNotes, scope: scope)
                merged = try await pushUnlinkedLocalNotes(merged)
                Defaults[.appleNotesLastSyncDate] = Date()
                return merged
            } catch {
                lastError = error.localizedDescription
                return nil
            }
        }
    }

    /// Creates or updates `note` in Notes. Returns it with its Apple Notes id and the modification
    /// date Notes reported, or nil when the push failed.
    func pushNote(_ note: NoteItem) async -> NoteItem? {
        guard Defaults[.enableAppleNotesSync], mayTouchNotes else { return nil }
        guard !note.isReadOnlyMirror(syncEnabled: true, scope: Defaults[.appleNotesSyncScope]) else { return nil }

        return await enqueue { [self] in
            do {
                var updated = note
                if let appleNotesId = note.appleNotesId ?? remoteIdByNoteId[note.id] {
                    updated.appleNotesId = appleNotesId
                    updated.appleNotesSyncedAt = try await updateRemoteNote(id: appleNotesId, note: note)
                } else {
                    let created = try await createRemoteNote(note)
                    updated.appleNotesId = created.id
                    updated.appleNotesSyncedAt = created.modificationDate
                }
                return updated
            } catch {
                lastError = error.localizedDescription
                return nil
            }
        }
    }

    /// Deletes the Apple note linked to `noteId`, including one whose create is still queued.
    func deleteRemoteNote(noteId: UUID, appleNotesId: String?) async {
        guard Defaults[.enableAppleNotesSync], mayTouchNotes else { return }

        await enqueue { [self] in
            guard let id = appleNotesId ?? remoteIdByNoteId[noteId] else { return }
            remoteIdByNoteId[noteId] = nil
            do {
                try await deleteRemoteNote(id: id)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Shows the note in Notes, for a note the notch shows read-only.
    func openInNotes(appleNotesId: String) async {
        guard mayTouchNotes else { return }
        let escapedId = appleScriptEscape(appleNotesId)
        await enqueue { [self] in
            do {
                try await runScriptVoid("""
                tell application "Notes"
                    show note id "\(escapedId)"
                    activate
                end tell
                """)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Runs `operation` after every operation queued before it.
    private func enqueue<T: Sendable>(_ operation: @escaping @MainActor () async -> T) async -> T {
        let previous = queueTail
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        queueTail = Task { _ = await task.value }
        return await task.value
    }

    // MARK: - Merge

    private func merge(localNotes: [NoteItem], remoteNotes: [RemoteAppleNote], scope: AppleNotesSyncScope) async throws -> [NoteItem] {
        var notes = localNotes
        let remoteById = Dictionary(remoteNotes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var linkedRemoteIds = Set<String>()
        let now = Date()

        for index in notes.indices {
            guard let appleNotesId = notes[index].appleNotesId,
                  let remote = remoteById[appleNotesId] else { continue }

            linkedRemoteIds.insert(appleNotesId)
            // Before 2026-10-23 Notes' dates were read shifted by the time zone's offset (east of
            // UTC, into the future), and a pulled note kept the shifted date. A date still ahead of
            // now is one of those: Notes' own, read correctly, replaces it.
            if notes[index].modificationDate > now { notes[index].modificationDate = remote.modificationDate }
            if notes[index].creationDate > now { notes[index].creationDate = remote.creationDate }

            notes[index].madeInAppleNotes = AppleNotesMergePolicy.madeInAppleNotes(
                stored: notes[index].madeInAppleNotes,
                hasKannuId: remote.kannuId != nil,
                inKannuFolder: remote.inKannuFolder
            )
            let mirror = notes[index].isReadOnlyMirror(syncEnabled: true, scope: scope)

            switch AppleNotesMergePolicy.decide(
                localModified: notes[index].modificationDate,
                remoteModified: remote.modificationDate,
                syncedAt: notes[index].appleNotesSyncedAt
            ) {
            case .takeRemote:
                applyRemote(remote, to: &notes[index])
            case .pushLocal where mirror:
                // Only its colour or pin can have changed here, and those live in Kannu alone.
                notes[index].appleNotesSyncedAt = remote.modificationDate
            case .pushLocal:
                notes[index].appleNotesSyncedAt = try await updateRemoteNote(id: appleNotesId, note: notes[index])
            case .unchanged:
                if notes[index].appleNotesSyncedAt == nil { notes[index].appleNotesSyncedAt = remote.modificationDate }
            }
        }

        for remote in remoteNotes where !linkedRemoteIds.contains(remote.id) {
            if let kannuId = remote.kannuId,
               let index = notes.firstIndex(where: { $0.id == kannuId }) {
                linkedRemoteIds.insert(remote.id)
                notes[index].appleNotesId = remote.id
                notes[index].madeInAppleNotes = false
                remoteIdByNoteId[kannuId] = remote.id
                if AppleNotesMergePolicy.decide(
                    localModified: notes[index].modificationDate,
                    remoteModified: remote.modificationDate,
                    syncedAt: nil
                ) == .takeRemote {
                    applyRemote(remote, to: &notes[index])
                } else {
                    notes[index].appleNotesSyncedAt = remote.modificationDate
                }
                continue
            }

            let title = sanitizedTitle(remote.title)
            let imported = NoteItem(
                title: title,
                content: AppleNotesMergePolicy.content(fromPlaintext: remote.content, title: title),
                creationDate: remote.creationDate,
                modificationDate: remote.modificationDate,
                colorIndex: 0,
                appleNotesId: remote.id,
                appleNotesSyncedAt: remote.modificationDate,
                madeInAppleNotes: AppleNotesMergePolicy.madeInAppleNotes(
                    stored: nil,
                    hasKannuId: remote.kannuId != nil,
                    inKannuFolder: remote.inKannuFolder
                )
            )
            notes.append(imported)
            linkedRemoteIds.insert(remote.id)
        }

        notes.removeAll { note in
            guard let appleNotesId = note.appleNotesId else { return false }
            return !linkedRemoteIds.contains(appleNotesId) && remoteById[appleNotesId] == nil
        }

        return notes.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.modificationDate > rhs.modificationDate
        }
    }

    private func pushUnlinkedLocalNotes(_ notes: [NoteItem]) async throws -> [NoteItem] {
        var updated = notes
        for index in updated.indices where updated[index].appleNotesId == nil {
            if let known = remoteIdByNoteId[updated[index].id] {
                updated[index].appleNotesId = known
                continue
            }
            let created = try await createRemoteNote(updated[index])
            updated[index].appleNotesId = created.id
            updated[index].appleNotesSyncedAt = created.modificationDate
        }
        return updated
    }

    private func applyRemote(_ remote: RemoteAppleNote, to note: inout NoteItem) {
        note.title = sanitizedTitle(remote.title)
        note.content = AppleNotesMergePolicy.content(fromPlaintext: remote.content, title: note.title)
        note.creationDate = remote.creationDate
        note.modificationDate = remote.modificationDate
        note.appleNotesId = remote.id
        note.appleNotesSyncedAt = remote.modificationDate
    }

    private func sanitizedTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Untitled Note") : trimmed
    }

    // MARK: - AppleScript bridge

    /// Formats an AppleScript date as local calendar fields, `year month day hours minutes seconds`.
    /// Subtracting a "1970" date built from `current date` instead gave seconds since local
    /// midnight 1970, off by the time zone's offset, and `as string` rounded them to ten seconds.
    private static let stampHandler = """
        on kannuStamp(d)
            return ((year of d) as string) & " " & ((month of d as integer) as string) & " " & ((day of d) as string) & " " & ((hours of d) as string) & " " & ((minutes of d) as string) & " " & ((seconds of d) as string)
        end kannuStamp
        """

    /// The Kannu folder, or every note of the default account. Narrowing to the folder drops the
    /// other notes' local copies on this sync (`merge` removes a linked note Notes no longer
    /// returns); nothing in Notes is deleted.
    private func fetchRemoteNotes(scope: AppleNotesSyncScope) async throws -> [RemoteAppleNote] {
        let source: String
        // Which fetched notes are in the Kannu folder: nil when only that folder is read. Asked by
        // id, because `name of container of n` matched no note on a real Mac (2026-10-23), which
        // made every note, Kannu's own included, read-only.
        let kannuFolderIds: Set<String>?
        try await ensureSyncFolderExists()
        switch scope {
        case .kannuFolder:
            source = "notes of folder \"\(Self.syncFolderName)\" of default account"
            kannuFolderIds = nil
        case .wholeAccount:
            source = "notes of default account"
            kannuFolderIds = try await fetchKannuFolderNoteIds()
        }
        let script = """
        set fieldSep to "\(Self.fieldSeparator)"
        set recordSep to "\(Self.recordSeparator)"
        tell application "Notes"
            set chunks to {}
            repeat with n in \(source)
                if password protected of n is false then
                    set notePlain to plaintext of n
                    set notePlain to my sanitizeField(notePlain, fieldSep, recordSep)
                    set kannuId to my extractKannuId(body of n)
                    set chunk to (id of n) & fieldSep & (name of n) & fieldSep & my kannuStamp(creation date of n) & fieldSep & my kannuStamp(modification date of n) & fieldSep & notePlain & fieldSep & kannuId
                    set end of chunks to chunk
                end if
            end repeat
            set AppleScript's text item delimiters to recordSep
            return chunks as text
        end tell

        \(Self.stampHandler)

        on sanitizeField(txt, fieldSep, recordSep)
            set AppleScript's text item delimiters to fieldSep
            set parts to text items of txt
            set AppleScript's text item delimiters to " "
            set txt to parts as text
            set AppleScript's text item delimiters to recordSep
            set parts to text items of txt
            set AppleScript's text item delimiters to " "
            return parts as text
        end sanitizeField

        on extractKannuId(noteBody)
            if noteBody contains "kannu:id=" then
                set AppleScript's text item delimiters to "kannu:id="
            else if noteBody contains "atoll:id=" then
                set AppleScript's text item delimiters to "atoll:id="
            else
                return ""
            end if
            set tail to item 2 of (text items of noteBody)
            set AppleScript's text item delimiters to "-->"
            return item 1 of (text items of tail)
        end extractKannuId
        """

        let output = try await runScriptReturningString(script)
        return parseRemoteNotes(output, kannuFolderIds: kannuFolderIds)
    }

    /// The ids of the notes in the Kannu folder (no bodies, so it is quick).
    private func fetchKannuFolderNoteIds() async throws -> Set<String> {
        let script = """
        tell application "Notes"
            set noteIds to id of notes of folder "\(Self.syncFolderName)" of default account
            set AppleScript's text item delimiters to "\(Self.recordSeparator)"
            return (noteIds as text) & ""
        end tell
        """
        let output = try await executeScript(script).stringValue ?? ""
        return Set(output.split(separator: Character(Self.recordSeparator)).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })
    }

    private func parseRemoteNotes(_ payload: String, kannuFolderIds: Set<String>?) -> [RemoteAppleNote] {
        guard !payload.isEmpty else { return [] }

        return payload
            .split(separator: Character(Self.recordSeparator), omittingEmptySubsequences: true)
            .compactMap { record in
                let fields = record.split(separator: Character(Self.fieldSeparator), maxSplits: 5, omittingEmptySubsequences: false)
                guard fields.count >= 5 else { return nil }

                let id = String(fields[0])
                let title = String(fields[1])
                guard let created = AppleNotesMergePolicy.date(fromStamp: String(fields[2])),
                      let modified = AppleNotesMergePolicy.date(fromStamp: String(fields[3])) else { return nil }

                let content = String(fields[4])
                let kannuId = fields.count > 5
                    ? UUID(uuidString: String(fields[5]).trimmingCharacters(in: .whitespaces))
                    : extractKannuId(from: content)

                return RemoteAppleNote(
                    id: id,
                    title: title,
                    content: content,
                    creationDate: created,
                    modificationDate: modified,
                    kannuId: kannuId,
                    inKannuFolder: kannuFolderIds?.contains(id) ?? true
                )
            }
    }

    private func extractKannuId(from content: String) -> UUID? {
        guard let regex = try? NSRegularExpression(pattern: Self.kannuTagPattern) else { return nil }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, range: range),
              let idRange = Range(match.range(at: 1), in: content) else { return nil }
        return UUID(uuidString: String(content[idRange]))
    }

    /// Creates the note in the Kannu folder; returns its id and the modification date Notes gave it.
    private func createRemoteNote(_ note: NoteItem) async throws -> (id: String, modificationDate: Date?) {
        try await ensureSyncFolderExists()

        let title = appleScriptEscape(sanitizedTitle(note.title))
        let body = appleScriptEscape(htmlBody(for: note))
        let fieldSep = Self.fieldSeparator

        let script = """
        tell application "Notes"
            set newNote to make new note at folder "\(Self.syncFolderName)" of default account with properties {name:"\(title)", body:"\(body)"}
            return (id of newNote) & "\(fieldSep)" & my kannuStamp(modification date of newNote)
        end tell

        \(Self.stampHandler)
        """

        let output = try await runScriptReturningString(script)
        let fields = output.split(separator: Character(fieldSep), maxSplits: 1, omittingEmptySubsequences: false)
        let id = String(fields[0])
        remoteIdByNoteId[note.id] = id
        return (id, fields.count > 1 ? AppleNotesMergePolicy.date(fromStamp: String(fields[1])) : nil)
    }

    /// Returns the modification date Notes gave the note.
    private func updateRemoteNote(id: String, note: NoteItem) async throws -> Date? {
        let title = appleScriptEscape(sanitizedTitle(note.title))
        let body = appleScriptEscape(htmlBody(for: note))
        let escapedId = appleScriptEscape(id)

        let script = """
        tell application "Notes"
            set targetNote to first note whose id is "\(escapedId)"
            set name of targetNote to "\(title)"
            set body of targetNote to "\(body)"
            return my kannuStamp(modification date of targetNote)
        end tell

        \(Self.stampHandler)
        """

        return AppleNotesMergePolicy.date(fromStamp: try await runScriptReturningString(script))
    }

    private func deleteRemoteNote(id: String) async throws {
        let escapedId = appleScriptEscape(id)
        let script = """
        tell application "Notes"
            set matches to every note whose id is "\(escapedId)"
            if (count of matches) > 0 then
                delete item 1 of matches
            end if
        end tell
        """
        try await runScriptVoid(script)
    }

    private func ensureSyncFolderExists() async throws {
        let script = """
        tell application "Notes"
            try
                set _folder to folder "\(Self.syncFolderName)" of default account
            on error
                make new folder at default account with properties {name:"\(Self.syncFolderName)"}
            end try
        end tell
        """
        try await runScriptVoid(script)
    }

    private func htmlBody(for note: NoteItem) -> String {
        let escaped = note.content
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")

        let html = escaped
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                if line.isEmpty { return "<div><br></div>" }
                return "<div>\(line)</div>"
            }
            .joined()

        return html + "<!--kannu:id=\(note.id.uuidString)-->"
    }

    private func appleScriptEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
    }

    private func runScriptReturningString(_ script: String) async throws -> String {
        let descriptor = try await executeScript(script)
        guard let value = descriptor.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw AppleNotesSyncError.scriptFailed(String(localized: "Notes returned an empty response."))
        }
        return value
    }

    private func runScriptVoid(_ script: String) async throws {
        _ = try await executeScript(script)
    }

    private func executeScript(_ script: String) async throws -> NSAppleEventDescriptor {
        do {
            guard let descriptor = try await AppleScriptHelper.execute(script) else {
                throw AppleNotesSyncError.scriptFailed(String(localized: "Notes script returned no result."))
            }
            return descriptor
        } catch let error as NSError {
            if error.domain == "AppleScriptError", (error.userInfo["NSAppleScriptErrorNumber"] as? Int) == -1743 {
                throw AppleNotesSyncError.automationDenied
            }
            let message = (error.userInfo["NSAppleScriptErrorMessage"] as? String) ?? error.localizedDescription
            throw AppleNotesSyncError.scriptFailed(message)
        }
    }
}
