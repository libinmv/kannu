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

/// One worklog on an issue, from `GET /rest/api/3/issue/{id}/worklog?expand=properties`: only what
/// finding Kannu's own entry needs. Read leniently: another app's property, or a field in a shape
/// this version does not expect, never costs the whole page.
struct JiraWorklog: Decodable, Equatable {
    let id: String
    let accountID: String?
    /// `2026-10-04T14:02:00.000+0530`, as Jira sends it.
    let started: String?
    let timeSpentSeconds: Int?
    /// The `entry` of the `kannu` property, when the worklog carries one.
    let kannuEntry: String?

    init(id: String, accountID: String?, started: String?, timeSpentSeconds: Int?, kannuEntry: String?) {
        self.id = id
        self.accountID = accountID
        self.started = started
        self.timeSpentSeconds = timeSpentSeconds
        self.kannuEntry = kannuEntry
    }

    private enum CodingKeys: String, CodingKey {
        case id, author, started, timeSpentSeconds, properties
    }

    private struct Author: Decodable {
        let accountId: String?
    }

    private struct Property: Decodable {
        let key: String?
        let entry: String?

        private enum CodingKeys: String, CodingKey { case key, value }
        private struct Marker: Decodable { let entry: String? }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try? container.decodeIfPresent(String.self, forKey: .key)
            entry = (try? container.decodeIfPresent(Marker.self, forKey: .value))?.entry
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .id) {
            id = text
        } else if let number = try? container.decode(Int.self, forKey: .id) {
            id = String(number)
        } else {
            id = ""
        }
        accountID = (try? container.decodeIfPresent(Author.self, forKey: .author))?.accountId
        started = try? container.decodeIfPresent(String.self, forKey: .started)
        timeSpentSeconds = try? container.decodeIfPresent(Int.self, forKey: .timeSpentSeconds)
        let properties = (try? container.decodeIfPresent([Property].self, forKey: .properties)) ?? []
        kannuEntry = properties.first { $0.key == JiraAPI.worklogPropertyKey }?.entry
    }
}

/// `GET /rest/api/3/issue/{id}/worklog`: the worklogs in the window asked for.
struct JiraWorklogPage: Decodable, Equatable {
    let worklogs: [JiraWorklog]
}

/// A worklog comment in Atlassian Document Format, which API v3 requires: a `doc` of plain-text
/// paragraphs, one per line. No marks, links or mentions: the user's text is sent as text.
struct JiraADFDocument: Encodable, Equatable {
    var type = "doc"
    var version = 1
    var content: [Paragraph]

    struct Paragraph: Encodable, Equatable {
        var type = "paragraph"
        var content: [TextNode]
    }

    struct TextNode: Encodable, Equatable {
        var type = "text"
        var text: String
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

    // MARK: - Worklogs

    /// The issue property every Kannu worklog carries: `{"key":"kannu","value":{"entry":"<draft
    /// id>"}}`, so an entry whose answer was lost can be found again.
    static let worklogPropertyKey = "kannu"
    /// How far either side of an entry's start the check looks, and how close a worklog without the
    /// marker must start to count as the same entry: Jira may keep the start only to the minute.
    static let reconcileWindow: TimeInterval = 60
    /// The longest comment sent; the rest is cut.
    static let maxCommentLength = 2_000

    /// A Jira issue id: digits only. Worklog paths are built from the id, never the key, which
    /// changes when an issue moves.
    static func isIssueID(_ id: String) -> Bool {
        (1...18).contains(id.count) && id.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
    }

    /// The `started` Jira wants: `yyyy-MM-dd'T'HH:mm:ss.SSSZ` in the Mac's time zone, with the
    /// `en_US_POSIX` locale so a Thai or Arabic calendar never changes the digits.
    /// `2026-10-04T14:02:00.000+0530`.
    static func worklogStarted(_ date: Date, timeZone: TimeZone = .current) -> String {
        startedFormatter(timeZone).string(from: date)
    }

    /// A `started` as Jira sends it back, or nil.
    static func parseWorklogStarted(_ text: String) -> Date? {
        startedFormatter(TimeZone(identifier: "UTC") ?? .current).date(from: text)
    }

    private static func startedFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter
    }

    /// A typed comment as it is sent: other control characters (a tab) become spaces, line ends
    /// are normalized, blank lines dropped, each line trimmed, at most `maxCommentLength`
    /// characters. Nil when nothing is left.
    static func cleanedComment(_ text: String?) -> String? {
        guard let text else { return nil }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line -> String in
                let scalars = line.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " as Unicode.Scalar : $0 }
                return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let joined = lines.joined(separator: "\n")
        return joined.count > maxCommentLength ? String(joined.prefix(maxCommentLength)) : joined
    }

    /// The comment as an ADF document, one paragraph per line; nil when there is no comment.
    static func commentDocument(_ comment: String?) -> JiraADFDocument? {
        guard let cleaned = cleanedComment(comment) else { return nil }
        let paragraphs = cleaned.split(separator: "\n").map {
            JiraADFDocument.Paragraph(content: [JiraADFDocument.TextNode(text: String($0))])
        }
        return JiraADFDocument(content: paragraphs)
    }

    /// `{"comment":…,"properties":[{"key":"kannu","value":{"entry":…}}],"started":…,
    /// "timeSpentSeconds":…}`, keys sorted, the comment only when one was typed.
    static func worklogBody(entry: UUID, seconds: Int, started: Date, comment: String?, timeZone: TimeZone = .current) -> Data? {
        struct Marker: Encodable { let entry: String }
        struct Property: Encodable {
            let key: String
            let value: Marker
        }
        struct Body: Encodable {
            let comment: JiraADFDocument?
            let properties: [Property]
            let started: String
            let timeSpentSeconds: Int
        }
        let body = Body(
            comment: commentDocument(comment),
            properties: [Property(key: worklogPropertyKey, value: Marker(entry: entry.uuidString))],
            started: worklogStarted(started, timeZone: timeZone),
            timeSpentSeconds: seconds
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(body)
    }

    /// `POST /rest/api/3/issue/{id}/worklog?adjustEstimate=auto&notifyUsers=false`: the one write
    /// to Jira. `adjustEstimate=auto` takes the time off the remaining estimate, as Jira's own Log
    /// work does; `notifyUsers=false` keeps the issue's watchers from an email per entry. Nil for
    /// an id that is not one, a length under a minute or over `WorkDuration.maxSeconds`, or a host
    /// that is not a Jira Cloud site.
    ///
    /// Called from `TasksManager.confirmWorklog` only (`WorklogConsentRulesTests`).
    static func addWorklogRequest(
        _ credential: JiraCredential,
        issueID: String,
        entry: UUID,
        seconds: Int,
        started: Date,
        comment: String?,
        timeZone: TimeZone = .current
    ) -> URLRequest? {
        guard isIssueID(issueID), (60...WorkDuration.maxSeconds).contains(seconds),
              let url = JiraSite.apiURL(
                host: credential.site,
                path: "/rest/api/3/issue/\(issueID)/worklog",
                query: [URLQueryItem(name: "adjustEstimate", value: "auto"), URLQueryItem(name: "notifyUsers", value: "false")]
              ),
              let body = worklogBody(entry: entry, seconds: seconds, started: started, comment: comment, timeZone: timeZone)
        else { return nil }
        return request(url: url, method: "POST", body: body, credential: credential)
    }

    /// `GET /rest/api/3/issue/{id}/worklog?startedAfter=…&startedBefore=…&expand=properties`: the
    /// read-only check for an entry whose answer was lost, `reconcileWindow` either side of its
    /// start, in milliseconds since 1970.
    static func worklogsRequest(_ credential: JiraCredential, issueID: String, around started: Date) -> URLRequest? {
        guard isIssueID(issueID) else { return nil }
        let milliseconds = Int64((started.timeIntervalSince1970 * 1000).rounded())
        let window = Int64(reconcileWindow * 1000)
        guard let url = JiraSite.apiURL(
            host: credential.site,
            path: "/rest/api/3/issue/\(issueID)/worklog",
            query: [
                URLQueryItem(name: "startedAfter", value: String(milliseconds - window)),
                URLQueryItem(name: "startedBefore", value: String(milliseconds + window)),
                URLQueryItem(name: "expand", value: "properties"),
            ]
        ) else { return nil }
        return request(url: url, method: "GET", body: nil, credential: credential)
    }

    static func decodeWorklog(_ data: Data) -> JiraWorklog? {
        try? JSONDecoder().decode(JiraWorklog.self, from: data)
    }

    static func decodeWorklogPage(_ data: Data) -> JiraWorklogPage? {
        try? JSONDecoder().decode(JiraWorklogPage.self, from: data)
    }

    /// Kannu's entry among `worklogs`: the one whose `kannu` marker is `entry`, or else one with no
    /// marker by the same author, of the same length, starting within `reconcileWindow`. A worklog
    /// marked for another entry is never taken for this one.
    static func matchingWorklog(in worklogs: [JiraWorklog], entry: UUID, accountID: String, started: Date, seconds: Int) -> JiraWorklog? {
        if let marked = worklogs.first(where: { $0.kannuEntry?.caseInsensitiveCompare(entry.uuidString) == .orderedSame }) {
            return marked
        }
        guard !accountID.isEmpty else { return nil }
        return worklogs.first { worklog in
            guard worklog.kannuEntry == nil, worklog.accountID == accountID, worklog.timeSpentSeconds == seconds,
                  let text = worklog.started, let date = parseWorklogStarted(text) else { return false }
            return abs(date.timeIntervalSince(started)) < reconcileWindow
        }
    }

    /// Jira's own reason for refusing a request: its `errorMessages`, then its `errors`, as one
    /// cleaned line (`WorklogDrafts.displayReason`). Nil when the body says nothing readable.
    static func refusalReason(_ data: Data?) -> String? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var parts = (object["errorMessages"] as? [Any])?.compactMap { $0 as? String } ?? []
        if let errors = object["errors"] as? [String: Any] {
            parts += errors.keys.sorted().compactMap { errors[$0] as? String }
        }
        return WorklogDrafts.displayReason(parts.joined(separator: " "))
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
            spentSeconds: fields.timetracking?.timeSpentSeconds,
            statusCategory: fields.status?.statusCategory?.key.flatMap(TaskItem.cleanedTitle)
        )
    }
}
