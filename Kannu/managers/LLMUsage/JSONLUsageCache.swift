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
import os

/// What one refresh did, in counts only: never a path, a prompt or any transcript content.
struct JSONLUsageScanStats: Equatable {
    /// Files in the listing the refresh was handed.
    var filesScanned = 0
    /// Files that had bytes the cache had not read yet.
    var filesRead = 0
    var bytesRead: Int64 = 0
    /// Lines that passed the `"usage"` pre-filter and were JSON-parsed.
    var linesParsed = 0
}

/// Keeps each transcript's usage records between refreshes and reads only the bytes appended since.
///
/// The aggregator used to load every transcript whole into a `String` and JSON-parse every line, on
/// every refresh. Subagent transcripts make that 650+ MB across ~130 files on a busy machine, the
/// largest over 230 MB, and Kannu's footprint peaked at 1.6 GB with the parsed objects of a whole pass
/// alive at once. Now, per file (keyed by path):
///
/// - the file's identity (device + inode), the byte offset just past the last newline consumed, and
///   the records those lines produced — only records inside the week when read, because the window
///   only moves forward (a clock set back drops every entry, see `refresh`);
/// - reads continue from that offset in `chunkSize` pieces through `pread` into one reused buffer,
///   each chunk inside its own `autoreleasepool`, and never hold a whole file;
/// - an unterminated last line leaves the offset at the newline before it, so it is read again once
///   the writer finishes it. If it already parses as a complete record it counts meanwhile, exactly as
///   the old whole-file split counted it, but it is never committed — so it cannot count twice;
/// - a replaced file (new inode) or one shorter than the offset drops what was read and starts again
///   from 0; a file that leaves the listing (deleted, or past the scan cutoff) is forgotten.
///
/// Only lines containing the bytes `"usage"` are parsed. `ClaudeUsageLine.parse` reads tokens only
/// from a `usage` object (under `message` for Claude, top level for the Codex shape), so a line
/// without that key can never produce a record, and the filter changes nothing but the work done.
///
/// Cross-file de-duplication is unchanged: files in listing order, lines in file order, the week
/// guard first, then the first record of each `dedupKey` (message id + request id) wins.
///
/// Not thread-safe. `records(files:now:)` confines it to its own serial utility queue (hence
/// `@unchecked Sendable`); tests call `refresh` directly from one thread.
final class JSONLUsageCache: @unchecked Sendable {
    static let chunkSize = 4 << 20
    private static let usageMarker = Array(#""usage""#.utf8)
    // Qualified: the app module has its own `Logger` struct.
    private static let logger = os.Logger(subsystem: "com.kannu.app", category: "UsageAggregator")

    struct Refresh {
        /// The records that count, in listing then line order: inside the week, first of each key.
        let records: [UsageRecord]
        let stats: JSONLUsageScanStats
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private struct Entry {
        let identity: FileIdentity
        /// Just past the last newline consumed; everything before it is in `records`.
        var offset: Int64 = 0
        /// The size the file had when last read. Equal on the next refresh means nothing to read.
        var scannedSize: Int64 = 0
        var records: [UsageRecord] = []
        /// The unterminated last line's record, when it already parses. Recomputed on every read.
        var tail: UsageRecord?

        init(identity: FileIdentity) { self.identity = identity }
    }

    private let label: String
    private let queue: DispatchQueue
    private var entries: [String: Entry] = [:]
    private var lastNow: Date?

    /// `label` names the provider in the log line ("claude", "codex").
    init(label: String) {
        self.label = label
        queue = DispatchQueue(label: "com.kannu.app.usage-aggregator.\(label)", qos: .utility)
    }

    /// `refresh` on the cache's serial utility queue, never on the caller's thread or actor.
    func records(files: [URL], now: Date) async -> [UsageRecord] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.refresh(files: files, now: now).records)
            }
        }
    }

    /// Brings every listed file up to date and returns the records that count at `now`.
    func refresh(files: [URL], now: Date) -> Refresh {
        let started = DispatchTime.now().uptimeNanoseconds
        let weekStart = now.addingTimeInterval(-UsageWindows.week)
        // Records older than the week are not kept. A clock set back would bring some of them inside
        // the window again, so start over rather than undercount.
        if let lastNow, now < lastNow { entries.removeAll() }
        lastNow = now

        var stats = JSONLUsageScanStats()
        var listed = Set<String>()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.chunkSize, alignment: 1)
        defer { buffer.deallocate() }
        for file in files {
            stats.filesScanned += 1
            let path = file.path
            guard listed.insert(path).inserted else { continue }
            update(path: path, weekStart: weekStart, buffer: buffer, stats: &stats)
        }
        entries = entries.filter { listed.contains($0.key) }

        var seen = Set<String>()
        var counted: [UsageRecord] = []
        func admit(_ record: UsageRecord) {
            // Window guard before the dedup claim, as before: a record outside the week must not
            // claim a key that an in-window duplicate of the same request still needs.
            guard record.timestamp >= weekStart else { return }
            if let key = record.dedupKey, !seen.insert(key).inserted { return }
            counted.append(record)
        }
        for file in files {
            guard let entry = entries[file.path] else { continue }
            entry.records.forEach(admit)
            if let tail = entry.tail { admit(tail) }
        }

        let elapsedMs = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        Self.logger.notice("""
            \(self.label, privacy: .public) refresh: files=\(stats.filesScanned, privacy: .public) \
            read=\(stats.filesRead, privacy: .public) bytes=\(stats.bytesRead, privacy: .public) \
            parsed=\(stats.linesParsed, privacy: .public) records=\(counted.count, privacy: .public) \
            ms=\(elapsedMs, privacy: .public)
            """)
        return Refresh(records: counted, stats: stats)
    }

    private func update(path: String, weekStart: Date, buffer: UnsafeMutableRawPointer,
                        stats: inout JSONLUsageScanStats) {
        // O_NONBLOCK so a FIFO named *.jsonl cannot hang the queue; it is then refused below.
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            entries[path] = nil
            return
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            entries[path] = nil
            return
        }
        let identity = FileIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
        let size = Int64(info.st_size)

        var entry = entries[path] ?? Entry(identity: identity)
        if entry.identity != identity || size < entry.offset {
            entry = Entry(identity: identity)
        }
        guard size != entry.scannedSize else {
            entries[path] = entry
            return
        }
        stats.filesRead += 1
        entry.tail = nil

        var position = entry.offset
        var carry = Data()
        while position < size {
            let want = Int(min(size - position, Int64(Self.chunkSize)))
            let got = pread(fd, buffer, want, off_t(position))
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { break }
            stats.bytesRead += Int64(got)
            autoreleasepool {
                var lineStart = 0
                while lineStart < got, let newline = memchr(buffer + lineStart, 0x0A, got - lineStart) {
                    let lineEnd = buffer.distance(to: newline)
                    if carry.isEmpty {
                        consume(UnsafeRawBufferPointer(start: buffer + lineStart, count: lineEnd - lineStart),
                                into: &entry.records, weekStart: weekStart, stats: &stats)
                    } else {
                        carry.append(buffer.assumingMemoryBound(to: UInt8.self) + lineStart, count: lineEnd - lineStart)
                        carry.withUnsafeBytes {
                            consume($0, into: &entry.records, weekStart: weekStart, stats: &stats)
                        }
                        carry = Data()
                    }
                    lineStart = lineEnd + 1
                    entry.offset = position + Int64(lineStart)
                }
                if lineStart < got {
                    carry.append(buffer.assumingMemoryBound(to: UInt8.self) + lineStart, count: got - lineStart)
                }
            }
            position += Int64(got)
        }
        if !carry.isEmpty {
            var tail: [UsageRecord] = []
            autoreleasepool {
                carry.withUnsafeBytes { consume($0, into: &tail, weekStart: weekStart, stats: &stats) }
            }
            entry.tail = tail.first
        }
        entry.scannedSize = position
        entries[path] = entry
    }

    private func consume(_ line: UnsafeRawBufferPointer, into records: inout [UsageRecord], weekStart: Date,
                         stats: inout JSONLUsageScanStats) {
        guard let base = line.baseAddress, !line.isEmpty else { return }
        let hasMarker = Self.usageMarker.withUnsafeBytes { marker in
            memmem(base, line.count, marker.baseAddress, marker.count) != nil
        }
        guard hasMarker else { return }
        stats.linesParsed += 1
        guard let record = ClaudeUsageLine.parse(Data(bytes: base, count: line.count)),
              record.timestamp >= weekStart else { return }
        records.append(record)
    }
}
