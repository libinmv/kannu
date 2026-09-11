import Foundation

struct JSONLUsageParser {
    static func parseLine(_ line: String) -> UsageRecord? {
        ClaudeUsageLine.parse(Data(line.utf8))
    }

    static func aggregate(files: [URL], now: Date) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        var perModel: [String: UsageTotals] = [:]
        var seen = Set<String>()
        var blockRecords: [(timestamp: Date, tokens: Int)] = []
        let cal = Calendar.current
        let sessionStart = now.addingTimeInterval(-5 * 3600)
        let weekStart = now.addingTimeInterval(-7 * 86400)

        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") {
                guard let rec = parseLine(String(line)) else { continue }
                if let key = rec.dedupKey {
                    if seen.contains(key) { continue }
                    seen.insert(key)
                }
                guard rec.timestamp >= weekStart else { continue }
                let cost = ModelPricing.cost(model: rec.model, inputTokens: rec.inputTokens, outputTokens: rec.outputTokens)
                func add(_ t: inout UsageTotals) {
                    t.inputTokens += rec.inputTokens
                    t.outputTokens += rec.outputTokens
                    if let cost { t.costUSD += cost } else { t.hasUnpricedModel = true }
                }
                add(&snapshot.week)
                if cal.isDate(rec.timestamp, inSameDayAs: now) { add(&snapshot.today) }
                if rec.timestamp >= sessionStart { add(&snapshot.session) }
                var mt = perModel[rec.model] ?? UsageTotals()
                add(&mt)
                perModel[rec.model] = mt
                blockRecords.append((rec.timestamp, rec.inputTokens + rec.outputTokens))
            }
        }
        snapshot.models = perModel
            .map { ModelUsage(model: $0.key, totals: $0.value) }
            .sorted { $0.totals.costUSD > $1.totals.costUSD }
        snapshot.localSessionBlock = ClaudeSessionBlocks.currentBlock(records: blockRecords, now: now)
        snapshot.lastUpdated = now
        return snapshot
    }
}
