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

/// The usage aggregator reads each transcript once and then only what was appended, and still counts
/// exactly what the old whole-file, every-line parse counted.
///
/// `everyLineParse` below is the old algorithm, kept verbatim as the oracle: read the file whole, split
/// on newlines, parse every line, week guard, then first-of-each-dedup-key across files.
final class JSONLUsageCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kannu-usage-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func stamp(_ hoursAgo: Double) -> String {
        Self.iso.string(from: now.addingTimeInterval(-hoursAgo * 3600))
    }

    private func line(_ object: [String: Any]) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    /// Claude's shape: usage under `message`, key = message id + request id.
    private func claude(_ id: String, request: String = "req", hoursAgo: Double = 1, input: Int = 10,
                        cacheRead: Int = 0, output: Int = 5, model: String = "claude-opus-4") -> Data {
        line(["type": "assistant", "timestamp": stamp(hoursAgo), "requestId": request,
              "message": ["id": id, "model": model, "role": "assistant",
                          "content": [["type": "text", "text": "done"]],
                          "usage": ["input_tokens": input, "cache_read_input_tokens": cacheRead,
                                    "cache_creation_input_tokens": 0, "output_tokens": output]]])
    }

    /// The Codex shape the parser accepts: usage, model and request id at the top level.
    private func codex(request: String, hoursAgo: Double = 2, input: Int = 30, output: Int = 7) -> Data {
        line(["timestamp": stamp(hoursAgo), "model": "gpt-5-codex", "request_id": request,
              "usage": ["input_tokens": input, "output_tokens": output]])
    }

    /// A user record carrying a tool result — by far the bulk of a transcript's bytes, never a record.
    private func toolResult(_ text: String) -> Data {
        line(["type": "user", "timestamp": stamp(1),
              "message": ["role": "user", "content": [["type": "tool_result", "content": text]]]])
    }

    private func file(_ name: String, _ parts: [Data]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try parts.reduce(Data(), +).write(to: url)
        return url
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func size(_ url: URL) throws -> Int64 {
        Int64(try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int))
    }

    private func describe(_ r: UsageRecord) -> String {
        "\(r.timestamp.timeIntervalSince1970)|\(r.model)|\(r.inputTokens)|\(r.outputTokens)|\(r.dedupKey ?? "-")"
    }

    /// The pre-change algorithm, the oracle every incremental result must equal.
    private func everyLineParse(_ files: [URL], now: Date) -> [String] {
        let weekStart = now.addingTimeInterval(-UsageWindows.week)
        var seen = Set<String>()
        var out: [String] = []
        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") {
                guard let rec = ClaudeUsageLine.parse(Data(String(line).utf8)) else { continue }
                guard rec.timestamp >= weekStart else { continue }
                if let key = rec.dedupKey {
                    if seen.contains(key) { continue }
                    seen.insert(key)
                }
                out.append(describe(rec))
            }
        }
        return out
    }

    private func refresh(_ cache: JSONLUsageCache, _ files: [URL], at date: Date? = nil) -> (records: [String], stats: JSONLUsageScanStats) {
        let result = cache.refresh(files: files, now: date ?? now)
        return (result.records.map(describe), result.stats)
    }

    // MARK: - Incremental reads

    func testAnUnchangedSecondRefreshReadsNothing() throws {
        let a = try file("a.jsonl", [claude("m1"), toolResult("ls"), claude("m2", request: "r2")])
        let cache = JSONLUsageCache(label: "test")

        let first = refresh(cache, [a])
        XCTAssertEqual(first.stats.bytesRead, try size(a))
        XCTAssertEqual(first.records.count, 2)

        let second = refresh(cache, [a])
        XCTAssertEqual(second.stats.bytesRead, 0, "nothing changed, so nothing is read")
        XCTAssertEqual(second.stats.filesRead, 0)
        XCTAssertEqual(second.stats.linesParsed, 0)
        XCTAssertEqual(second.records, first.records, "the cached records still count")
    }

    func testAnAppendReadsOnlyTheDeltaAndMatchesAFullReparse() throws {
        let a = try file("a.jsonl", [claude("m1"), toolResult("output")])
        let b = try file("b.jsonl", [codex(request: "c1")])
        let cache = JSONLUsageCache(label: "test")
        _ = refresh(cache, [a, b])

        let delta = claude("m2", request: "r2", input: 100) + toolResult("more") + claude("m3", request: "r3")
        try append(delta, to: a)
        let second = refresh(cache, [a, b])

        XCTAssertEqual(second.stats.bytesRead, Int64(delta.count), "only the appended bytes")
        XCTAssertEqual(second.stats.filesRead, 1, "the untouched file is not read")
        XCTAssertEqual(second.records, everyLineParse([a, b], now: now))
        XCTAssertEqual(second.records, refresh(JSONLUsageCache(label: "fresh"), [a, b]).records)
        XCTAssertEqual(second.records.count, 4)
    }

    func testReadsCrossChunkBoundariesWithoutLosingALine() throws {
        // One tool result longer than a chunk, with records on both sides of it and one straddling the
        // boundary: every line must be reassembled exactly once.
        let huge = toolResult(String(repeating: "x", count: JSONLUsageCache.chunkSize + 1234))
        let a = try file("a.jsonl", [claude("m1"), huge, claude("m2", request: "r2"),
                                     toolResult(String(repeating: "y", count: JSONLUsageCache.chunkSize - 300)),
                                     claude("m3", request: "r3"), claude("m4", request: "r4")])
        let cache = JSONLUsageCache(label: "test")
        let result = refresh(cache, [a])
        XCTAssertEqual(result.records, everyLineParse([a], now: now))
        XCTAssertEqual(result.records.count, 4)
        XCTAssertEqual(result.stats.bytesRead, try size(a))
    }

    func testATruncatedFileIsReadAgainFromTheStartWithoutDoubleCounting() throws {
        let a = try file("a.jsonl", [claude("m1"), claude("m2", request: "r2"), claude("m3", request: "r3")])
        let cache = JSONLUsageCache(label: "test")
        XCTAssertEqual(refresh(cache, [a]).records.count, 3)

        // Same inode, rewritten shorter than what was already consumed.
        let handle = try FileHandle(forWritingTo: a)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: claude("n1", request: "q1", input: 42))
        try handle.close()

        let second = refresh(cache, [a])
        XCTAssertEqual(second.stats.bytesRead, try size(a), "read again from 0")
        XCTAssertEqual(second.records, everyLineParse([a], now: now))
        XCTAssertEqual(second.records.count, 1, "the old file's records are gone")
    }

    func testAReplacedFileIsReadAgainFromTheStartWithoutDoubleCounting() throws {
        let a = try file("a.jsonl", [claude("m1")])
        let cache = JSONLUsageCache(label: "test")
        XCTAssertEqual(refresh(cache, [a]).records.count, 1)

        // A new inode under the same path, longer than the old file, so only the identity can tell.
        let replacement = try file("replacement.tmp", [claude("n1", request: "q1"), claude("n2", request: "q2"),
                                                     claude("n3", request: "q3")])
        XCTAssertEqual(rename(replacement.path, a.path), 0)

        let second = refresh(cache, [a])
        XCTAssertEqual(second.stats.bytesRead, try size(a), "read again from 0, not from the old offset")
        XCTAssertEqual(second.records, everyLineParse([a], now: now))
        XCTAssertEqual(second.records.count, 3)
    }

    func testAPartialLastLineCountsOnlyOnceCompleteAndIsNeverCountedTwice() throws {
        let whole = claude("m2", request: "r2", input: 77)
        let cut = whole.count / 2
        let a = try file("a.jsonl", [claude("m1"), whole.prefix(cut)])
        let cache = JSONLUsageCache(label: "test")

        let first = refresh(cache, [a])
        XCTAssertEqual(first.records.count, 1, "half a line is not a record")
        XCTAssertEqual(first.records, everyLineParse([a], now: now))

        // The writer finishes the line: the read resumes at the start of the unfinished line.
        try append(whole.suffix(from: cut), to: a)
        let second = refresh(cache, [a])
        XCTAssertEqual(second.stats.bytesRead, Int64(whole.count), "the unfinished line is read again, whole")
        XCTAssertEqual(second.records.count, 2)
        XCTAssertEqual(second.records, everyLineParse([a], now: now))

        XCTAssertEqual(refresh(cache, [a]).stats.bytesRead, 0)
    }

    func testACompleteLineMissingOnlyItsNewlineCountsOnceAsBefore() throws {
        // The old split counted a final line with no newline; keep that, without counting it twice
        // when the newline lands.
        let last = claude("m2", request: "r2")
        let a = try file("a.jsonl", [claude("m1"), last.dropLast()])
        let cache = JSONLUsageCache(label: "test")

        XCTAssertEqual(refresh(cache, [a]).records, everyLineParse([a], now: now))
        XCTAssertEqual(refresh(cache, [a]).stats.bytesRead, 0, "an unchanged unterminated tail is not re-read")

        try append(Data([0x0A]) + claude("m3", request: "r3"), to: a)
        let after = refresh(cache, [a])
        XCTAssertEqual(after.records.count, 3)
        XCTAssertEqual(after.records, everyLineParse([a], now: now))
    }

    func testAFileThatLeavesTheListingIsForgotten() throws {
        let a = try file("a.jsonl", [claude("m1")])
        let b = try file("b.jsonl", [claude("m2", request: "r2")])
        let cache = JSONLUsageCache(label: "test")
        XCTAssertEqual(refresh(cache, [a, b]).records.count, 2)

        try FileManager.default.removeItem(at: b)
        XCTAssertEqual(refresh(cache, [a, b]).records.count, 1, "a deleted file contributes nothing")
        XCTAssertEqual(refresh(cache, [a]).records.count, 1)

        // Back in the listing (recreated): read from 0 like any new file.
        try claude("m2", request: "r2").write(to: b)
        let back = refresh(cache, [a, b])
        XCTAssertEqual(back.records, everyLineParse([a, b], now: now))
        XCTAssertEqual(back.stats.bytesRead, try size(b))
    }

    // MARK: - Same totals as parsing every line

    func testThePreFilterMatchesParsingEveryLineForEveryShape() throws {
        let spaced = Data("""
            {"timestamp" : "\(stamp(3))", "model" : "gpt-5", "requestId" : "spaced", "usage" : {"input_tokens" : 4, "output_tokens" : 1}}

            """.utf8)
        let messageTimestamp = line(["requestId": "mt", "message": [
            "id": "msg-mt", "model": "claude-sonnet-4", "timestamp": stamp(4),
            "usage": ["input_tokens": 1, "cache_creation_input_tokens": 9, "output_tokens": 2]]])
        let unkeyed = line(["timestamp": stamp(5), "usage": ["input_tokens": 8, "output_tokens": 3]])
        let subagentResult = line(["type": "user", "timestamp": stamp(1),
                                   "toolUseResult": ["usage": ["input_tokens": 500, "output_tokens": 50]],
                                   "message": ["role": "user", "content": "agent finished"]])
        let codexTokenCount = line(["timestamp": stamp(1), "type": "event_msg", "payload": [
            "type": "token_count", "info": ["total_token_usage": ["input_tokens": 900, "output_tokens": 90],
                                             "last_token_usage": ["input_tokens": 9, "output_tokens": 1]]]])
        let zero = claude("zero", request: "z", input: 0, cacheRead: 0, output: 0)
        let noTimestamp = line(["message": ["id": "nt", "usage": ["input_tokens": 3, "output_tokens": 3]]])
        let quotedInText = toolResult(#"the "usage" key appears in this text"#)
        let notJSON = Data(#"not json but mentions "usage" anyway"#.utf8) + Data([0x0A])
        let old = claude("old", request: "old", hoursAgo: 24 * 8)

        let a = try file("a.jsonl", [claude("m1", cacheRead: 2000), spaced, messageTimestamp, unkeyed, unkeyed,
                                     subagentResult, codexTokenCount, zero, noTimestamp, quotedInText, notJSON,
                                     Data([0x0A]), old, codex(request: "c1")])
        let b = try file("b.jsonl", [codex(request: "c2", input: 1, output: 1), claude("m1", cacheRead: 2000)])

        let result = refresh(JSONLUsageCache(label: "test"), [a, b])
        XCTAssertEqual(result.records, everyLineParse([a, b], now: now))
        // m1, spaced, message-timestamp, two unkeyed (no key, so both count), c1, c2 — m1 again in b
        // is a duplicate, and old is outside the week.
        XCTAssertEqual(result.records.count, 7)
        // 15 non-empty lines; the Codex token_count event (`"total_token_usage"`) and the quoted word
        // inside a string (`\"usage\"`) lack the key's bytes and are never parsed.
        XCTAssertEqual(result.stats.linesParsed, 13)
    }

    // MARK: - De-duplication

    func testDeduplicationAcrossFilesKeepsTheFirstInListingOrder() throws {
        let a = try file("a.jsonl", [claude("m1", request: "r1", hoursAgo: 1, input: 11)])
        let b = try file("b.jsonl", [claude("m1", request: "r1", hoursAgo: 2, input: 11), claude("m2", request: "r2")])
        let cache = JSONLUsageCache(label: "test")

        let ab = refresh(cache, [a, b]).records
        XCTAssertEqual(ab, everyLineParse([a, b], now: now))
        XCTAssertEqual(ab.count, 2)
        XCTAssertTrue(ab[0].hasPrefix("\(now.addingTimeInterval(-3600).timeIntervalSince1970)|"), "a's copy wins")

        let ba = refresh(cache, [b, a]).records
        XCTAssertEqual(ba, everyLineParse([b, a], now: now))
        XCTAssertEqual(ba.count, 2)
        XCTAssertEqual(refresh(cache, [b, a]).stats.bytesRead, 0, "order changes the winner, not the reads")
    }

    func testARecordOutsideTheWeekNeverClaimsAKey() throws {
        // A resumed history repeats an old record; the in-window copy in a later file still counts.
        let a = try file("a.jsonl", [claude("m1", request: "r1", hoursAgo: 24 * 7.5)])
        let b = try file("b.jsonl", [claude("m1", request: "r1", hoursAgo: 1)])
        let records = refresh(JSONLUsageCache(label: "test"), [a, b]).records
        XCTAssertEqual(records, everyLineParse([a, b], now: now))
        XCTAssertEqual(records.count, 1)
    }

    func testTheWindowMovesWithNowAndAClockSetBackStartsOver() throws {
        let a = try file("a.jsonl", [claude("m1", hoursAgo: 24 * 6.5), claude("m2", request: "r2", hoursAgo: 1)])
        let cache = JSONLUsageCache(label: "test")
        XCTAssertEqual(refresh(cache, [a]).records.count, 2)

        let later = now.addingTimeInterval(86400)
        let moved = refresh(cache, [a], at: later)
        XCTAssertEqual(moved.records, everyLineParse([a], now: later))
        XCTAssertEqual(moved.records.count, 1, "m1 has left the week")

        // Back to the original clock: m1 is inside the week again, so it must be read again.
        let back = refresh(cache, [a], at: now)
        XCTAssertEqual(back.records, everyLineParse([a], now: now))
        XCTAssertEqual(back.records.count, 2)
    }

    func testTheAsyncEntryPointMatchesRefresh() async throws {
        let a = try file("a.jsonl", [claude("m1"), codex(request: "c1")])
        let records = await JSONLUsageCache(label: "test").records(files: [a], now: now)
        XCTAssertEqual(records.map(describe), everyLineParse([a], now: now))
    }
}
