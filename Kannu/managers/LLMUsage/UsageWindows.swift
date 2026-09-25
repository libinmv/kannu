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

/// The time windows the token-usage aggregator reports, and the file cutoff derived from them.
///
/// `JSONLUsageParser` reads and JSON-parses every transcript a provider has ever written in order to
/// compute totals that are all a week old at most. Measured on the development machine: **228 files,
/// 648 MB**, the largest single file **167 MB**, re-read every few minutes while the Usage card is
/// open. A file's modification time is never earlier than its newest record, so a file untouched for
/// longer than the widest window cannot contribute to any of them and does not need opening.
///
/// The cutoff must therefore be **derived from** the windows rather than picked, because a cutoff
/// narrower than a window silently truncates that window's total — a failure with no error and no
/// visible symptom beyond a number that is quietly too small. `UsageWindowsTests` asserts the ordering
/// so adding a wider window without widening the cutoff fails the build rather than the totals.
enum UsageWindows {
    /// The rolling session window the card shows.
    static let session: TimeInterval = 5 * 3600

    /// The widest window any total covers. `localSessionBlock`'s records are appended behind this
    /// guard, so the block history cannot reach further back than this either.
    static let week: TimeInterval = 7 * 86400

    /// How far back a file's modification time may be before it is skipped.
    ///
    /// A day wider than `week` on purpose: mtimes come from the filesystem and are compared against a
    /// wall clock, so DST shifts, a corrected clock and a file written by another machine all have to
    /// fit inside the slack. The extra day costs one `stat`.
    static let fileScanLookback: TimeInterval = 8 * 86400

    /// Whether a transcript is recent enough to be worth reading.
    ///
    /// An unknown modification time reads as "worth reading": the point is to skip files that can be
    /// *proven* irrelevant, and a failed `stat` proves nothing. A future mtime — clock skew, or a
    /// file copied from a machine ahead of this one — is likewise kept.
    static func shouldScan(modifiedAt: Date?, now: Date) -> Bool {
        guard let modifiedAt else { return true }
        return modifiedAt >= now.addingTimeInterval(-fileScanLookback)
    }

    /// Filters a file listing down to what `shouldScan` accepts, one `stat` per file.
    ///
    /// Callers must keep any "are there logs at all?" decision on the **unfiltered** listing. Keying it
    /// on the filtered one would tell somebody who simply has not used the tool for eight days that
    /// their logs are unavailable, and offer them a fix for a problem they do not have.
    static func recentlyModified(_ files: [URL], now: Date) -> [URL] {
        files.filter { file in
            let modifiedAt = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            return shouldScan(modifiedAt: modifiedAt, now: now)
        }
    }
}
