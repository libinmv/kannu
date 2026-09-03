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

/// Reconstructs Claude's 5-hour usage blocks from local transcript records, the way community
/// tooling (ccusage) does: a block is anchored at the first request after the previous block
/// ended, floored to the hour, and spans exactly five hours. This yields the tokens spent in
/// the CURRENT block and when it resets — a local, auth-free glance value.
///
/// Honest boundary: the plan's budget (the denominator) and Anthropic's model/cache-weighted
/// `utilization` exist only server-side, so this can never be a percentage — local token sums
/// are known to diverge from the server's accounting. It is a fuel gauge without a tank size.
///
/// Foundation-only on purpose: compiled into the logic test target.
enum ClaudeSessionBlocks {
    struct CurrentBlock: Equatable {
        let startedAt: Date
        let resetsAt: Date
        let totalTokens: Int
        /// Tokens per minute over the block so far; 0 while the block is under a minute old.
        let burnRatePerMinute: Double
    }

    static let blockLength: TimeInterval = 5 * 3600

    /// `records` are (timestamp, tokens) pairs in ANY order; only the block containing `now`
    /// is returned, nil when the latest activity predates it (no active block).
    static func currentBlock(records: [(timestamp: Date, tokens: Int)], now: Date) -> CurrentBlock? {
        let sorted = records.sorted { $0.timestamp < $1.timestamp }
        guard !sorted.isEmpty else { return nil }

        var blockStart: Date?
        var blockTokens = 0
        var lastRecordAt: Date?

        for record in sorted where record.timestamp <= now {
            if let start = blockStart, record.timestamp < start.addingTimeInterval(blockLength) {
                blockTokens += record.tokens
            } else {
                blockStart = floorToHour(record.timestamp)
                blockTokens = record.tokens
            }
            lastRecordAt = record.timestamp
        }

        guard let start = blockStart, lastRecordAt != nil else { return nil }
        let resetsAt = start.addingTimeInterval(blockLength)
        guard now < resetsAt else { return nil } // latest block already expired — idle

        let elapsedMinutes = now.timeIntervalSince(start) / 60
        let burnRate = elapsedMinutes >= 1 ? Double(blockTokens) / elapsedMinutes : 0
        return CurrentBlock(
            startedAt: start,
            resetsAt: resetsAt,
            totalTokens: blockTokens,
            burnRatePerMinute: burnRate
        )
    }

    static func floorToHour(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }
}
