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

/// Refuses every redirect. A request carrying a credential goes to the host it was built for and
/// nowhere else: a 3xx from that host ends the request as `.redirected` instead of carrying the
/// `Authorization` header to wherever the `Location` points.
final class RedirectRefusal: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// An answer: what it means, and its body when there is one small enough to read.
struct HTTPExchange {
    let outcome: HTTPOutcome
    let data: Data?
}

/// The one way Kannu's task integrations talk to a server. Foundation only, so the logic target
/// runs the real redirect guard against a stubbed `URLProtocol`.
///
/// - **Ephemeral.** No cookies stored or sent, no URL cache, no credential storage: nothing about
///   the user's Jira session outlives the request.
/// - **Bounded.** 20 s per request and per resource; bodies over 5 MB are dropped.
/// - **No redirects** (`RedirectRefusal`, on the session and on each task).
/// - **Off the main actor.** `send` is a nonisolated async function, so awaiting it from the main
///   actor runs the request elsewhere and resumes on main with the result.
/// - **Nothing at launch.** `shared` is a static, so it is created on first use.
enum IntegrationHTTP {
    static let timeout: TimeInterval = 20
    static let maxBodyBytes = 5 * 1024 * 1024

    static let shared: URLSession = makeSession()

    static func makeConfiguration(base: URLSessionConfiguration = .ephemeral) -> URLSessionConfiguration {
        let configuration = base
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        return configuration
    }

    static func makeSession(configuration: URLSessionConfiguration = makeConfiguration()) -> URLSession {
        URLSession(configuration: configuration, delegate: RedirectRefusal(), delegateQueue: nil)
    }

    static func send(_ request: URLRequest, session: URLSession, now: Date = Date()) async -> HTTPExchange {
        do {
            let (data, response) = try await session.data(for: request, delegate: RedirectRefusal())
            guard let http = response as? HTTPURLResponse else {
                return HTTPExchange(outcome: .ambiguous(nil), data: nil)
            }
            let outcome = HTTPOutcome.classify(
                status: http.statusCode,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                now: now
            )
            return HTTPExchange(outcome: outcome, data: data.count <= maxBodyBytes ? data : nil)
        } catch let error as URLError {
            return HTTPExchange(outcome: HTTPOutcome.classify(error), data: nil)
        } catch {
            return HTTPExchange(outcome: .ambiguous(nil), data: nil)
        }
    }
}
