import Foundation
import os

struct CursorUsageEventsClient {
    private static let log = os.Logger(subsystem: "com.kannu.app", category: "CursorUsage")
    private static let cacheReadPromptDiscount = 0.10
    let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func fetchSnapshot(now: Date) async -> UsageSnapshot? {
        guard CursorTokenStore.sessionCookie() != nil else { return nil }
        guard let url = URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events") else {
            return nil
        }

        let weekStart = now.addingTimeInterval(-7 * 86400)
        let startMs = Int64(weekStart.timeIntervalSince1970 * 1000)
        let endMs = Int64(now.timeIntervalSince1970 * 1000)
        let sessionStart = now.addingTimeInterval(-5 * 3600)
        let calendar = Calendar.current

        var snapshot = UsageSnapshot()
        snapshot.lastUpdated = now
        var perModel: [String: UsageTotals] = [:]
        var page = 1
        let pageSize = 500
        let maxPages = 8

        while page <= maxPages {
            let body: [String: Any] = [
                "startDate": "\(startMs)",
                "endDate": "\(endMs)",
                "page": page,
                "pageSize": pageSize,
            ]
            guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }

            let data: Data
            let http: HTTPURLResponse
            do {
                (data, http) = try await CursorAPIHelpers.restRequest(
                    url: url,
                    method: "POST",
                    body: payload,
                    session: session
                )
            } catch {
                Self.log.error("usage-events request failed: \(error.localizedDescription, privacy: .public)")
                return page == 1 ? nil : snapshot
            }

            guard (200..<300).contains(http.statusCode) else {
                Self.log.error("usage-events HTTP \(http.statusCode)")
                return page == 1 ? nil : snapshot
            }

            guard let root = CursorAPIHelpers.parseJSONObject(data),
                  let events = root["usageEventsDisplay"] as? [[String: Any]] else {
                Self.log.error("usage-events invalid JSON")
                return page == 1 ? nil : snapshot
            }

            if events.isEmpty { break }

            for event in events {
                guard let timestamp = parseEventTimestamp(event["timestamp"]) else { continue }
                guard timestamp >= weekStart else { continue }

                let model = (event["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty ?? "unknown"
                let tokenUsage = event["tokenUsage"] as? [String: Any] ?? [:]
                let input = Int(CursorAPIHelpers.parseDouble(tokenUsage["inputTokens"]) ?? 0)
                let output = Int(CursorAPIHelpers.parseDouble(tokenUsage["outputTokens"]) ?? 0)
                let cacheWrite = Int(CursorAPIHelpers.parseDouble(tokenUsage["cacheWriteTokens"]) ?? 0)
                let cacheRead = Int(CursorAPIHelpers.parseDouble(tokenUsage["cacheReadTokens"]) ?? 0)
                let totalInput = input + cacheWrite + cacheRead
                guard totalInput + output > 0 else { continue }

                let costUSD = eventCostUSD(event: event, model: model, tokenUsage: tokenUsage)

                func addTokens(_ totals: inout UsageTotals) {
                    totals.inputTokens += totalInput
                    totals.outputTokens += output
                }

                func addCost(_ totals: inout UsageTotals) {
                    if let costUSD {
                        totals.costUSD += costUSD
                    } else if Self.isUsageBasedEvent(event) {
                        totals.hasUnpricedModel = true
                    }
                }

                addTokens(&snapshot.week)
                addCost(&snapshot.week)
                if calendar.isDate(timestamp, inSameDayAs: now) {
                    addTokens(&snapshot.today)
                    addCost(&snapshot.today)
                }
                if timestamp >= sessionStart {
                    addTokens(&snapshot.session)
                    addCost(&snapshot.session)
                }

                var modelTotals = perModel[model] ?? UsageTotals()
                addTokens(&modelTotals)
                addCost(&modelTotals)
                perModel[model] = modelTotals
            }

            if events.count < pageSize { break }
            page += 1
        }

        guard snapshot.week.totalTokens > 0 || snapshot.week.costUSD > 0 else {
            return nil
        }

        snapshot.models = perModel
            .map { ModelUsage(model: $0.key, totals: $0.value) }
            .sorted { $0.totals.costUSD > $1.totals.costUSD }
        return snapshot
    }

    private func eventCostUSD(
        event: [String: Any],
        model: String,
        tokenUsage: [String: Any]
    ) -> Double? {
        guard Self.isUsageBasedEvent(event) else { return nil }

        if let dollars = CursorAPIHelpers.parseMoneyUSD(event["usageBasedCosts"]) {
            return dollars
        }
        if let cents = CursorAPIHelpers.parseDouble(event["chargedCents"]) {
            return cents / 100
        }
        if let cents = CursorAPIHelpers.parseDouble(tokenUsage["totalCents"]) {
            return cents / 100
        }

        let input = Int(CursorAPIHelpers.parseDouble(tokenUsage["inputTokens"]) ?? 0)
        let output = Int(CursorAPIHelpers.parseDouble(tokenUsage["outputTokens"]) ?? 0)
        let cacheWrite = Int(CursorAPIHelpers.parseDouble(tokenUsage["cacheWriteTokens"]) ?? 0)
        let cacheRead = Int(CursorAPIHelpers.parseDouble(tokenUsage["cacheReadTokens"]) ?? 0)
        guard let rates = ModelPricingManager.shared.getPricing(for: model) else {
            return nil
        }
        let billablePromptTokens = Double(input + cacheWrite)
            + (Double(cacheRead) * Self.cacheReadPromptDiscount)
        return (billablePromptTokens * rates.prompt) + (Double(output) * rates.completion)
    }

    private static func isUsageBasedEvent(_ event: [String: Any]) -> Bool {
        let kind = (event["kind"] as? String) ?? ""
        return kind.contains("USAGE_BASED")
    }

    private func parseEventTimestamp(_ value: Any?) -> Date? {
        CursorAPIHelpers.parseTimestamp(value)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
