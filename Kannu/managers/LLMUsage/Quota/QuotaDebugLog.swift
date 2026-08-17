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

/// Append-only debug trail for the LLM quota path, written where `os.Logger` can't help:
/// a plain text file that survives the session and can be read after an error.
///
/// Debug builds only — in Release every call compiles to a no-op, so shipping builds never
/// write to disk. Lives at `~/Library/Logs/Kannu/quota-debug.log` (the standard macOS app-log
/// location, visible in Console.app). Rotates once at ~512 KB to `.old`.
///
/// Never log secrets: token *lengths* and expiry deltas are fine, token values never are.
enum QuotaDebugLog {
#if DEBUG
    private actor Writer {
        static let shared = Writer()

        private let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Kannu", isDirectory: true)
        private var fileURL: URL { directory.appendingPathComponent("quota-debug.log") }
        private let maxBytes: UInt64 = 512 * 1024
        private lazy var stamp: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            f.timeZone = .current
            return f
        }()

        func append(at date: Date, _ category: String, _ message: String) {
            let line = "\(stamp.string(from: date)) [\(category)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            rotateIfNeeded()

            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }

        private func rotateIfNeeded() {
            guard let size = try? FileManager.default
                .attributesOfItem(atPath: fileURL.path)[.size] as? UInt64,
                size > maxBytes else { return }
            let old = directory.appendingPathComponent("quota-debug.log.old")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: fileURL, to: old)
        }
    }

    static func log(_ category: String, _ message: String) {
        // Timestamp captured here, not inside the actor: the unstructured Tasks below carry no
        // ordering guarantee, and stamping at write time produced a log whose times could
        // disagree with call order — poison for a trail meant to debug races.
        let at = Date()
        Task { await Writer.shared.append(at: at, category, message) }
    }
#else
    @inline(__always)
    static func log(_ category: String, _ message: String) {}
#endif
}
