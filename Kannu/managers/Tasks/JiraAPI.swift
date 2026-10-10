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

/// The Jira Cloud sign-in: the site it belongs to, the Atlassian account email and an API token.
/// Stored as one JSON item in the Keychain, never in Defaults, so the token and the host it may be
/// sent to cannot be separated: a plist edit cannot point the token at another host.
///
/// It never prints its email or token: not in `print`, string interpolation, `dump` or the
/// debugger's summary, so a stray log line cannot leak it.
struct JiraCredential: Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var site: String
    var email: String
    var token: String

    var description: String { "JiraCredential(site: \(site), email: <redacted>, token: <redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["site": site]) }

    /// The Keychain form: compact JSON with sorted keys.
    func encoded() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decoded(_ text: String) -> JiraCredential? {
        try? JSONDecoder().decode(JiraCredential.self, from: Data(text.utf8))
    }
}

/// `GET /rest/api/3/myself`: who the token belongs to. Only what Kannu shows.
struct JiraMyself: Decodable, Equatable {
    let accountId: String
    let displayName: String?
}

/// One page of `POST /rest/api/3/search/jql`.
struct JiraSearchPage: Decodable, Equatable {
    let issues: [JiraIssue]
    let nextPageToken: String?
    let isLast: Bool?
}

struct JiraIssue: Decodable, Equatable {
    let id: String
    let key: String
    let fields: Fields

    struct Fields: Decodable, Equatable {
        let summary: String?
        let status: Status?
        /// Absent when time tracking is off for the project; `{}` when it is on but empty.
        let timetracking: TimeTracking?
    }

    struct Status: Decodable, Equatable {
        let name: String?
        let statusCategory: StatusCategory?
    }

    struct StatusCategory: Decodable, Equatable {
        /// "new", "indeterminate" or "done".
        let key: String?
    }

    struct TimeTracking: Decodable, Equatable {
        let originalEstimateSeconds: Int?
        let remainingEstimateSeconds: Int?
        let timeSpentSeconds: Int?
    }
}

/// Building Jira Cloud requests and reading their answers. Pure: nothing here sends anything, so
/// the logic target checks every header, URL and body byte for byte.
///
/// The token travels only in the `Authorization` header, as HTTP Basic, and only to the host in
/// the credential (`JiraSite.apiURL` refuses any other). It is never put in a URL, so it cannot end
/// up in a log, a cache key or a proxy's access log.
enum JiraAPI {
    /// The issues shown when the user has not set a filter: theirs, not finished, newest first.
    static let defaultJQL = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
    static let pageSize = 100
    /// At most two pages (200 issues) per sync: far below Jira's rate limits, and more than a task
    /// list can usefully hold. A bigger result is reported as incomplete, never silently cut.
    static let maxPages = 2
    static let requestTimeout: TimeInterval = 20
    static let fields = ["summary", "status", "timetracking"]
    /// Where an Atlassian account makes an API token.
    static let createTokenURL = URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!

    /// The stored filter, or the default when it is empty.
    static func effectiveJQL(_ stored: String) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultJQL : trimmed
    }

    /// "my open issues" for the default filter, "a custom filter" otherwise. The filter itself is
    /// never shown in a status line or logged.
    static func filterSummary(jql: String) -> String {
        effectiveJQL(jql) == defaultJQL ? String(localized: "my open issues") : String(localized: "a custom filter")
    }

    static func basicAuthorization(email: String, token: String) -> String {
        "Basic " + Data("\(email):\(token)".utf8).base64EncodedString()
    }

    // MARK: - Requests

    static func myselfRequest(_ credential: JiraCredential) -> URLRequest? {
        guard let url = JiraSite.apiURL(host: credential.site, path: "/rest/api/3/myself") else { return nil }
        return request(url: url, method: "GET", body: nil, credential: credential)
    }

    static func searchRequest(_ credential: JiraCredential, jql: String, nextPageToken: String?) -> URLRequest? {
        guard let url = JiraSite.apiURL(host: credential.site, path: "/rest/api/3/search/jql"),
              let body = searchBody(jql: jql, nextPageToken: nextPageToken) else { return nil }
        return request(url: url, method: "POST", body: body, credential: credential)
    }

    /// `{"fields":[…],"jql":…,"maxResults":100,"nextPageToken":…}`, keys sorted, the token only
    /// from the second page on.
    static func searchBody(jql: String, nextPageToken: String?) -> Data? {
        struct Body: Encodable {
            let fields: [String]
            let jql: String
            let maxResults: Int
            let nextPageToken: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(Body(fields: fields, jql: effectiveJQL(jql), maxResults: pageSize, nextPageToken: nextPageToken))
    }

    private static func request(url: URL, method: String, body: Data?, credential: JiraCredential) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(basicAuthorization(email: credential.email, token: credential.token), forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    // MARK: - Answers

    static func decodeMyself(_ data: Data) -> JiraMyself? {
        try? JSONDecoder().decode(JiraMyself.self, from: data)
    }

    static func decodeSearchPage(_ data: Data) -> JiraSearchPage? {
        try? JSONDecoder().decode(JiraSearchPage.self, from: data)
    }

    enum PageStep: Equatable {
        /// Fetch the page this token names.
        case next(String)
        /// No more pages. `complete` is false when Jira said there were more but gave no token.
        case done(complete: Bool)
        /// There are more pages, but Kannu has fetched all it will.
        case capped
    }

    static func nextStep(after page: JiraSearchPage, pagesFetched: Int) -> PageStep {
        if page.isLast == true { return .done(complete: true) }
        if let token = page.nextPageToken, !token.isEmpty {
            return pagesFetched >= maxPages ? .capped : .next(token)
        }
        return .done(complete: page.isLast != false)
    }

    /// An issue as a task keeps it. An issue with no summary is titled by its key.
    static func remoteIssue(from issue: JiraIssue) -> RemoteIssue {
        let fields = issue.fields
        return RemoteIssue(
            remoteID: issue.id,
            key: issue.key,
            title: TaskItem.cleanedTitle(fields.summary ?? "") ?? issue.key,
            status: fields.status?.name ?? "",
            isDoneRemotely: fields.status?.statusCategory?.key == "done",
            estimateSeconds: fields.timetracking?.originalEstimateSeconds,
            spentSeconds: fields.timetracking?.timeSpentSeconds
        )
    }
}
