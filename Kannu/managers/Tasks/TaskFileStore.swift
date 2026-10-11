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

/// Reads and writes `tasks.json`, off the main actor (docs/REGRESSIONS.md entries 11 and 14).
///
/// - **Atomic.** Each save writes a temporary file beside the real one and renames it over, so a
///   crash mid-write leaves the previous file whole.
/// - **Private.** The file is created mode 0600 and its folder 0700: task titles are the user's.
/// - **Ordered.** Every snapshot carries a revision number. Saves are fired from the main actor as
///   unstructured tasks and can arrive out of order; one older than the last written is dropped.
/// - **Never lost.** A file that does not decode is moved aside as `tasks.corrupt-<date>.json` and
///   the list starts empty, so a bad file never blocks Kannu and is never overwritten.
///
/// The folder comes from the app (`AppSupportPaths`), resolved here on first use, so this file
/// needs nothing beyond Foundation and the logic target can test it in a temporary folder.
actor TaskFileStore {
    enum LoadResult: Equatable {
        /// No file yet.
        case empty
        case loaded(TasksFile)
        /// The file did not decode. It was moved to this name, beside where it was.
        case movedAside(String)
        /// The file is there but could not be read, or could not be moved aside. Nothing may be
        /// saved over it.
        case failed(String)
    }

    enum SaveOutcome: Equatable {
        case written
        /// A newer revision was already written; this one was dropped.
        case stale
        case failed(String)
    }

    nonisolated let fileName: String
    private let writer: Writer

    init(fileName: String = "tasks.json", directory: @escaping @Sendable () -> URL) {
        self.fileName = fileName
        writer = Writer(fileName: fileName, directory: directory)
    }

    func load() -> LoadResult {
        let url = writer.fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failed(error.localizedDescription)
        }
        do {
            let file = try TasksFile.makeDecoder().decode(TasksFile.self, from: data)
            // A file written by hand or restored from a backup may have lost its mode.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return .loaded(file)
        } catch {
            return writer.moveAside(url)
        }
    }

    func save(_ file: TasksFile, revision: Int) -> SaveOutcome {
        writer.write(file, revision: revision)
    }

    /// For the quit path only: the app is about to exit and an awaited save would never run. Same
    /// lock and revision rule as `save`, so a slower save already in flight cannot land over it.
    nonisolated func saveImmediately(_ file: TasksFile, revision: Int) -> SaveOutcome {
        writer.write(file, revision: revision)
    }
}

/// The part both the actor and the quit path use, behind one lock.
private final class Writer: @unchecked Sendable {
    private let lock = NSLock()
    private let fileName: String
    private let directoryProvider: @Sendable () -> URL
    private var directory: URL?
    private var lastWrittenRevision = Int.min

    init(fileName: String, directory: @escaping @Sendable () -> URL) {
        self.fileName = fileName
        directoryProvider = directory
    }

    func fileURL() -> URL {
        lock.lock()
        defer { lock.unlock() }
        return resolvedDirectory().appendingPathComponent(fileName)
    }

    func write(_ file: TasksFile, revision: Int) -> TaskFileStore.SaveOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard revision > lastWrittenRevision else { return .stale }
        let data: Data
        do {
            data = try TasksFile.makeEncoder().encode(file)
        } catch {
            return .failed(error.localizedDescription)
        }
        let target = resolvedDirectory().appendingPathComponent(fileName)
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp")
        // Created 0600 from the start: a file made and then chmod-ed is readable in between.
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return .failed(String(cString: strerror(errno))) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            unlink(temporary.path)
            return .failed(error.localizedDescription)
        }
        guard rename(temporary.path, target.path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary.path)
            return .failed(reason)
        }
        lastWrittenRevision = revision
        return .written
    }

    func moveAside(_ url: URL) -> TaskFileStore.LoadResult {
        lock.lock()
        defer { lock.unlock() }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = url.deletingPathExtension().lastPathComponent
        var name = "\(stem).corrupt-\(formatter.string(from: Date())).json"
        let folder = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(stem).corrupt-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).json"
        }
        do {
            try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(name))
            return .movedAside(name)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Called with the lock held.
    private func resolvedDirectory() -> URL {
        if let directory { return directory }
        let resolved = directoryProvider()
        try? FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: resolved.path)
        directory = resolved
        return resolved
    }
}
