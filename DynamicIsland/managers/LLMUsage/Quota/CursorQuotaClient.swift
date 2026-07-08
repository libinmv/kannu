import Foundation
import os

struct CursorQuotaClient {
    private static let log = os.Logger(subsystem: "com.kannu.app", category: "CursorQuota")
    let session: URLSession
    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    private struct PlanUsage: Decodable {
        let totalPercentUsed: Double
    }

    private struct UsageResponse: Decodable {
        let planUsage: PlanUsage?
        let billingCycleEnd: Double?
    }

    func fetchLimits() async -> QuotaFetchResult {
        guard let token = CursorTokenStore.accessToken() else {
            Self.log.notice("no Cursor access token in Keychain or state.vscdb")
            return QuotaFetchResult(errorMessage: "Cursor not signed in")
        }
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                Self.log.error("GetCurrentPeriodUsage HTTP \(code)")
                return QuotaFetchResult(errorMessage: "Cursor quota API HTTP \(code)")
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let decoded = try decoder.decode(UsageResponse.self, from: data)
            guard let percent = decoded.planUsage?.totalPercentUsed else {
                Self.log.error("GetCurrentPeriodUsage missing planUsage (\(data.count) bytes)")
                return QuotaFetchResult(errorMessage: "Cursor quota response missing usage data")
            }
            let resets = decoded.billingCycleEnd.map { Date(timeIntervalSince1970: $0 / 1000) }
            return QuotaFetchResult(week: UsageLimit(used: percent, limit: 100, resetsAt: resets))
        } catch {
            Self.log.error("GetCurrentPeriodUsage failed: \(error.localizedDescription, privacy: .public)")
            return QuotaFetchResult(errorMessage: error.localizedDescription)
        }
    }
}
