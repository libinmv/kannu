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

struct UsageRecord {
    let timestamp: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let dedupKey: String?
}

/// One transcript line's token usage — Claude's and Codex's JSONL share this shape. "Input" counts
/// everything the model read: fresh input plus cache creation plus cache reads. Claude splits one
/// assistant message across several records that repeat the same usage; `dedupKey`
/// (message id + request id) is what makes them count once. Lifted out of `JSONLUsageParser` so the
/// logic test target (and the turn-token reader) can use it.
enum ClaudeUsageLine {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ s: String) -> Date? {
        if let d = iso.date(from: s) { return d }
        return isoPlain.date(from: s)
    }

    static func parse(_ data: Data) -> UsageRecord? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(obj)
    }

    static func parse(_ obj: [String: Any]) -> UsageRecord? {
        let message = obj["message"] as? [String: Any]
        let usage = (message?["usage"] as? [String: Any]) ?? (obj["usage"] as? [String: Any])
        guard let usage else { return nil }
        let input = (usage["input_tokens"] as? Int ?? 0)
            + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            + (usage["cache_read_input_tokens"] as? Int ?? 0)
        let output = usage["output_tokens"] as? Int ?? 0
        guard input + output > 0 else { return nil }
        let model = (message?["model"] as? String) ?? (obj["model"] as? String) ?? "unknown"
        let tsString = (obj["timestamp"] as? String) ?? (message?["timestamp"] as? String) ?? ""
        guard let ts = parseDate(tsString) else { return nil }
        let messageId = message?["id"] as? String
        let requestId = (obj["requestId"] as? String) ?? (obj["request_id"] as? String)
        let dedupKey = (messageId != nil || requestId != nil) ? "\(messageId ?? "")-\(requestId ?? "")" : nil
        return UsageRecord(timestamp: ts, model: model, inputTokens: input, outputTokens: output, dedupKey: dedupKey)
    }
}
