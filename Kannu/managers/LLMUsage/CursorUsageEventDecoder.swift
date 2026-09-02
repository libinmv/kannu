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

/// Decodes per-event token counts from Cursor's `get-filtered-usage-events`
/// response. Foundation-only on purpose: the test target compiles app sources
/// file-by-file, and this file must not drag URLSession/SQLite/pricing along.
///
/// Events without a `tokenUsage` container are valid — Cursor omits it for
/// non-token-based entries (e.g. `USAGE_EVENT_KIND_INCLUDED_IN_PRO`), which
/// decode to all-zero counts.
enum CursorUsageEventDecoder {
    struct TokenCounts: Equatable {
        var input = 0
        var output = 0
        var cacheWrite = 0
        var cacheRead = 0

        /// Prompt-side total the way Cursor's dashboard counts it.
        var totalInput: Int { input + cacheWrite + cacheRead }
        var isEmpty: Bool { totalInput + output == 0 }
    }

    static func tokenUsageDict(in event: [String: Any]) -> [String: Any]? {
        event["tokenUsage"] as? [String: Any]
    }

    static func tokenCounts(in event: [String: Any]) -> TokenCounts {
        let usage = tokenUsageDict(in: event) ?? [:]
        return TokenCounts(
            input: intValue(usage["inputTokens"]),
            output: intValue(usage["outputTokens"]),
            cacheWrite: intValue(usage["cacheWriteTokens"]),
            cacheRead: intValue(usage["cacheReadTokens"])
        )
    }

    /// Accepts numbers or numeric strings (Cursor sends both across fields),
    /// mirroring CursorAPIHelpers.parseDouble without depending on it.
    static func intValue(_ value: Any?) -> Int {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(Double(string.trimmingCharacters(in: .whitespaces)) ?? 0)
        default:
            return 0
        }
    }
}
