import Foundation
import os

struct CursorQuotaClient {
    private static let log = os.Logger(subsystem: "com.kannu.app", category: "CursorQuota")
    let session: URLSession
    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    func fetchLimits() async -> QuotaFetchResult {
        guard CursorTokenStore.accessToken() != nil else {
            Self.log.notice("no Cursor access token in Keychain or state.vscdb")
            return QuotaFetchResult(errorMessage: "Cursor not signed in")
        }

        if let connect = await fetchConnectLimits() {
            return connect
        }
        if let summary = await fetchUsageSummaryLimits() {
            return summary
        }
        return QuotaFetchResult(errorMessage: "Cursor quota unavailable")
    }

    private func fetchConnectLimits() async -> QuotaFetchResult? {
        do {
            let (data, http) = try await CursorAPIHelpers.connectRequest(
                path: "/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
                session: session
            )
            guard (200..<300).contains(http.statusCode) else {
                Self.log.error("GetCurrentPeriodUsage HTTP \(http.statusCode)")
                return nil
            }
            guard let root = CursorAPIHelpers.parseJSONObject(data) else {
                Self.log.error("GetCurrentPeriodUsage invalid JSON (\(data.count) bytes)")
                return nil
            }
            guard let planUsage = root["planUsage"] as? [String: Any],
                  let percent = CursorAPIHelpers.parsePercent(from: planUsage) else {
                Self.log.error("GetCurrentPeriodUsage missing usable planUsage")
                return nil
            }
            let resets = CursorAPIHelpers.parseTimestamp(root["billingCycleEnd"])
            return QuotaFetchResult(week: UsageLimit(used: percent, limit: 100, resetsAt: resets))
        } catch {
            Self.log.error("GetCurrentPeriodUsage failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func fetchUsageSummaryLimits() async -> QuotaFetchResult? {
        guard let url = URL(string: "https://cursor.com/api/usage-summary") else { return nil }
        do {
            let (data, http) = try await CursorAPIHelpers.restRequest(url: url, session: session)
            guard (200..<300).contains(http.statusCode) else {
                Self.log.error("usage-summary HTTP \(http.statusCode)")
                return nil
            }
            guard let root = CursorAPIHelpers.parseJSONObject(data) else {
                Self.log.error("usage-summary invalid JSON")
                return nil
            }

            let individual = root["individualUsage"] as? [String: Any]
            let plan = individual?["plan"] as? [String: Any]
            if let plan, let percent = CursorAPIHelpers.parsePercent(from: plan) {
                let resets = CursorAPIHelpers.parseTimestamp(root["billingCycleEnd"])
                return QuotaFetchResult(week: UsageLimit(used: percent, limit: 100, resetsAt: resets))
            }

            if let overall = individual?["overall"] as? [String: Any],
               let percent = CursorAPIHelpers.parsePercent(from: overall) {
                let resets = CursorAPIHelpers.parseTimestamp(root["billingCycleEnd"])
                return QuotaFetchResult(week: UsageLimit(used: percent, limit: 100, resetsAt: resets))
            }

            if let team = root["teamUsage"] as? [String: Any],
               let pooled = team["pooled"] as? [String: Any],
               let percent = CursorAPIHelpers.parsePercent(from: pooled) {
                let resets = CursorAPIHelpers.parseTimestamp(root["billingCycleEnd"])
                return QuotaFetchResult(week: UsageLimit(used: percent, limit: 100, resetsAt: resets))
            }

            Self.log.error("usage-summary missing usable quota fields")
            return nil
        } catch {
            Self.log.error("usage-summary failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
