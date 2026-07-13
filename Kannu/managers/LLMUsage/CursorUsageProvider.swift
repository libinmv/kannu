import Foundation

struct CursorUsageProvider: UsageProvider {
    let id: ProviderID = .cursor
    let session: URLSession
    let quotaClient: CursorQuotaClient
    let eventsClient: CursorUsageEventsClient

    init(
        session: URLSession = URLSession(configuration: .ephemeral),
        quotaClient: CursorQuotaClient? = nil,
        eventsClient: CursorUsageEventsClient? = nil
    ) {
        self.session = session
        self.quotaClient = quotaClient ?? CursorQuotaClient(session: session)
        self.eventsClient = eventsClient ?? CursorUsageEventsClient(session: session)
    }

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        let quota = await quotaClient.fetchLimits()

        if var eventsSnapshot = await eventsClient.fetchSnapshot(now: now) {
            eventsSnapshot.sessionLimit = eventsSnapshot.sessionLimit ?? quota.session
            eventsSnapshot.weekLimit = eventsSnapshot.weekLimit ?? quota.week
            eventsSnapshot.onDemandSpendUSD = quota.onDemandSpendUSD
            eventsSnapshot.quotaError = quota.errorMessage
            return eventsSnapshot
        }

        if let cookie = CursorTokenStore.sessionCookie(),
           let legacy = try? await fetchLegacyUsage(cookie: cookie, now: now),
           legacy.week.totalTokens > 0 || !legacy.models.isEmpty {
            var snapshot = legacy
            snapshot.sessionLimit = quota.session
            snapshot.weekLimit = quota.week
            snapshot.onDemandSpendUSD = quota.onDemandSpendUSD
            snapshot.quotaError = quota.errorMessage
            return snapshot
        }

        if quota.hasLimits || quota.onDemandSpendUSD != nil {
            var snapshot = UsageSnapshot()
            snapshot.sessionLimit = quota.session
            snapshot.weekLimit = quota.week
            snapshot.onDemandSpendUSD = quota.onDemandSpendUSD
            snapshot.quotaError = quota.errorMessage
            snapshot.logsUnavailable = true
            snapshot.lastUpdated = now
            return snapshot
        }

        throw UsageError.notConfigured(quota.errorMessage ?? "Cursor not signed in")
    }

    private func fetchLegacyUsage(
        cookie: (userId: String, cookieToken: String),
        now: Date
    ) async throws -> UsageSnapshot {
        var components = URLComponents(string: "https://cursor.com/api/usage")!
        components.queryItems = [URLQueryItem(name: "user", value: cookie.userId)]
        var request = URLRequest(url: components.url!)
        request.setValue("WorkosCursorSessionToken=\(cookie.cookieToken)", forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UsageError.notConfigured("Cursor usage request failed (HTTP \(code))")
        }
        return try decodeLegacy(data, now: now)
    }

    private func decodeLegacy(_ data: Data, now: Date) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.notConfigured("Cursor usage response malformed")
        }
        var snapshot = UsageSnapshot()
        snapshot.lastUpdated = now
        var week = UsageTotals()
        var models: [ModelUsage] = []
        for (model, value) in root {
            guard model != "startOfMonth", let entry = value as? [String: Any] else { continue }
            let tokens = Int(CursorAPIHelpers.parseDouble(entry["numTokens"]) ?? 0)
            let requests = Int(CursorAPIHelpers.parseDouble(entry["numRequests"]) ?? 0)
            guard tokens > 0 || requests > 0 else { continue }
            let cost = ModelPricing.cost(model: model, inputTokens: tokens, outputTokens: 0)
            var modelTotals = UsageTotals(inputTokens: tokens)
            if let cost {
                modelTotals.costUSD = cost
            } else {
                modelTotals.hasUnpricedModel = true
            }
            models.append(ModelUsage(model: model, totals: modelTotals))
            week.inputTokens += tokens
            if let cost {
                week.costUSD += cost
            } else {
                week.hasUnpricedModel = true
            }
        }
        snapshot.models = models.sorted { $0.model < $1.model }
        snapshot.week = week
        snapshot.today = week
        snapshot.session = week
        return snapshot
    }
}
