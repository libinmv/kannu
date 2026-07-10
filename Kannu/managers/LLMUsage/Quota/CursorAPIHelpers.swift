import Foundation

enum CursorAPIHelpers {
    static func sessionCookieHeaderValue() -> String? {
        guard let cookie = CursorTokenStore.sessionCookie() else { return nil }
        return "WorkosCursorSessionToken=\(cookie.cookieToken)"
    }

    static func restRequest(
        url: URL,
        method: String = "GET",
        body: Data? = nil,
        session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        guard let cookie = sessionCookieHeaderValue() else {
            throw UsageError.notConfigured("Cursor not signed in")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.notConfigured("Cursor usage request failed")
        }
        return (data, http)
    }

    static func connectRequest(
        path: String,
        session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        guard let token = CursorTokenStore.accessToken() else {
            throw UsageError.notConfigured("Cursor not signed in")
        }
        guard let url = URL(string: "https://api2.cursor.sh\(path)") else {
            throw UsageError.notConfigured("Invalid Cursor API URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.notConfigured("Cursor quota request failed")
        }
        return (data, http)
    }

    static func parseTimestamp(_ value: Any?) -> Date? {
        switch value {
        case let string as String:
            if let ms = Double(string) {
                return Date(timeIntervalSince1970: ms / 1000)
            }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: string)
        case let number as Double:
            return Date(timeIntervalSince1970: number / 1000)
        case let number as Int:
            return Date(timeIntervalSince1970: Double(number) / 1000)
        default:
            return nil
        }
    }

    static func parseDouble(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let string as String: return Double(string)
        default: return nil
        }
    }

    static func parsePercent(from planUsage: [String: Any]) -> Double? {
        if let percent = parseDouble(planUsage["totalPercentUsed"]), percent.isFinite {
            return percent
        }
        if let limit = parseDouble(planUsage["limit"]), limit > 0 {
            let included = parseDouble(planUsage["includedSpend"])
                ?? parseDouble(planUsage["totalSpend"])
                ?? parseDouble(planUsage["used"])
            if let included {
                return min((included / limit) * 100, 100)
            }
            if let remaining = parseDouble(planUsage["remaining"]) {
                return min(((limit - remaining) / limit) * 100, 100)
            }
        }
        if let used = parseDouble(planUsage["used"]),
           let limit = parseDouble(planUsage["limit"]),
           limit > 0 {
            return min((used / limit) * 100, 100)
        }
        return nil
    }

    static func parseJSONObject(_ data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}
