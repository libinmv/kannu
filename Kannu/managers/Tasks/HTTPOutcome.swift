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

/// What an answer from Jira (and later GitLab) means for Kannu, from its status code or the error
/// the request failed with. Pure, so the logic target tests every mapping.
///
/// The split that matters most is between "it never left this Mac" (`offline`, `failedBeforeSend`)
/// and "it may have arrived" (`ambiguous`): a read can simply be tried again either way, but a write
/// that may have arrived must be checked before it is sent again.
enum HTTPOutcome: Equatable {
    /// 2xx.
    case ok(Int)
    /// 3xx. Kannu follows no redirect, so this is where one ends.
    case redirected(Int)
    /// 401: the credential was refused.
    case auth(Int)
    /// 403, 404 and every other 4xx except 401 and 429.
    case rejected(Int)
    /// 429, or a 503 that says when to come back. Seconds to wait, already clamped.
    case rateLimited(retryAfter: TimeInterval)
    /// This Mac is not connected.
    case offline
    /// The request never reached the server: DNS, connecting, TLS, App Transport Security.
    case failedBeforeSend
    /// It may have reached the server: a timeout, a dropped connection, a 5xx.
    case ambiguous(Int?)

    /// Used when a 429 says nothing usable about when to come back.
    static let defaultRetryAfter: TimeInterval = 60
    static let retryAfterRange: ClosedRange<TimeInterval> = 1...3600

    static func classify(status: Int, retryAfter: String?, now: Date) -> HTTPOutcome {
        switch status {
        case 200..<300:
            return .ok(status)
        case 300..<400:
            return .redirected(status)
        case 401:
            return .auth(status)
        case 429:
            return .rateLimited(retryAfter: retryAfterSeconds(retryAfter, now: now))
        case 503 where retryAfter != nil:
            return .rateLimited(retryAfter: retryAfterSeconds(retryAfter, now: now))
        case 400..<500:
            return .rejected(status)
        default:
            return .ambiguous(status)
        }
    }

    static func classify(_ error: URLError) -> HTTPOutcome {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return .offline
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .badURL, .unsupportedURL,
             .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired,
             .appTransportSecurityRequiresSecureConnection:
            return .failedBeforeSend
        default:
            // Timed out, connection lost, cancelled, a bad response: it may have arrived.
            return .ambiguous(nil)
        }
    }

    /// A `Retry-After` value in seconds: delta-seconds or an HTTP-date. Missing or unreadable is
    /// `defaultRetryAfter`; the result is always within `retryAfterRange`, so a hostile header can
    /// neither lock Refresh out for a day nor turn it into a busy loop.
    static func retryAfterSeconds(_ value: String?, now: Date) -> TimeInterval {
        let raw: TimeInterval
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let seconds = Double(trimmed), seconds.isFinite {
            raw = seconds
        } else if let date = httpDate(trimmed) {
            raw = date.timeIntervalSince(now)
        } else {
            raw = defaultRetryAfter
        }
        return min(max(raw, retryAfterRange.lowerBound), retryAfterRange.upperBound)
    }

    /// RFC 9110's preferred date form: `Sun, 06 Nov 1994 08:49:37 GMT`.
    private static func httpDate(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}
