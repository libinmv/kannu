import Foundation

struct JSONLUsageParser {
    /// Reads `files` through `cache` (only what was appended since the last refresh, on the cache's
    /// own utility queue) and folds the records that count into the card's totals.
    static func aggregate(files: [URL], now: Date, cache: JSONLUsageCache) async -> UsageSnapshot {
        snapshot(counting: await cache.records(files: files, now: now), now: now)
    }

    /// `records` arrive already decided by `JSONLUsageCache`: inside the week and the first of each
    /// dedup key, in listing then line order — the checks this function used to make inline while it
    /// read every file whole.
    static func snapshot(counting records: [UsageRecord], now: Date) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        var perModel: [String: UsageTotals] = [:]
        var blockRecords: [(timestamp: Date, tokens: Int)] = []
        let cal = Calendar.current
        let sessionStart = now.addingTimeInterval(-UsageWindows.session)

        for rec in records {
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
        snapshot.models = perModel
            .map { ModelUsage(model: $0.key, totals: $0.value) }
            .sorted { $0.totals.costUSD > $1.totals.costUSD }
        snapshot.localSessionBlock = ClaudeSessionBlocks.currentBlock(records: blockRecords, now: now)
        snapshot.lastUpdated = now
        return snapshot
    }
}
