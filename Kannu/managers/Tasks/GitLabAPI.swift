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

/// The GitLab sign-in: the server it belongs to and a personal access token. Stored as one JSON item
/// in the Keychain, never in Defaults, so the token and the server it may be sent to cannot be
/// separated: a plist edit cannot point the token at another server.
///
/// It never prints its token: not in `print`, string interpolation, `dump` or the debugger's
/// summary, so a stray log line cannot leak it.
struct GitLabCredential: Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// `GitLabHost.normalize`'s form: `https://gitlab.com`, `https://git.acme.lan:8443/gitlab`.
    var baseURL: String
    var token: String

    var description: String { "GitLabCredential(baseURL: \(baseURL), token: <redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["baseURL": baseURL]) }

    /// The Keychain form: compact JSON with sorted keys.
    func encoded() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decoded(_ text: String) -> GitLabCredential? {
        try? JSONDecoder().decode(GitLabCredential.self, from: Data(text.utf8))
    }
}

/// `GET /api/v4/user`: who the token belongs to. Only what Kannu shows and pages by.
struct GitLabUser: Decodable, Equatable {
    let id: Int
    let username: String
    let name: String?
}

/// `GET /api/v4/personal_access_tokens/self`: the token's scopes. Only those.
struct GitLabTokenInfo: Decodable, Equatable {
    let scopes: [String]?
}

/// One issue or merge request from a GitLab list. Both share these fields.
struct GitLabItem: Decodable, Equatable {
    /// The global id: unique on the server within its kind.
    let id: Int
    /// The number within its project (`#45`, `!12`).
    let iid: Int
    let projectID: Int
    let title: String?
    /// "opened", "closed", "merged", "locked".
    let state: String?
    let webURL: String?
    let references: References?
    /// Absent on older servers; present with zeros when nothing is estimated or spent.
    let timeStats: TimeStats?

    struct References: Decodable, Equatable {
        /// `group/app#45`, `group/app!12`.
        let full: String?
    }

    struct TimeStats: Decodable, Equatable {
        let timeEstimate: Int?
        let totalTimeSpent: Int?

        private enum CodingKeys: String, CodingKey {
            case timeEstimate = "time_estimate"
            case totalTimeSpent = "total_time_spent"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, iid, title, state, references
        case projectID = "project_id"
        case webURL = "web_url"
        case timeStats = "time_stats"
    }
}

/// What a verified token may do, from its scopes.
enum GitLabAccess: Equatable {
    /// `api`: lists, and logs time (`add_spent_time`).
    case canLogTime
    /// `read_api`, or scopes the server did not say: lists only.
    case readOnly
    /// Neither `api` nor `read_api`: it cannot list issues at all.
    case cannotList
}

/// Building GitLab requests and reading their answers. Pure: nothing here sends anything, so the
/// logic target checks every header and URL.
///
/// The token travels only in the `PRIVATE-TOKEN` header, and only to the server in the credential
/// (`GitLabHost.apiURL` refuses any other). It is never put in a URL, so it cannot end up in a log, a
/// cache key or a proxy's access log. Every query is built here from Kannu's own values; a URL from
/// an answer (a `Link` header) is never followed.
enum GitLabAPI {
    static let tokenHeader = "PRIVATE-TOKEN"
    static let pageSize = 100
    /// At most two pages per list: three lists, six requests per sync, far below gitlab.com's
    /// limits. A bigger result is reported as incomplete, never silently cut.
    static let maxPages = 2
    static let requestTimeout: TimeInterval = 20
    static let nextPageHeader = "X-Next-Page"

    /// The lists a sync reads.
    enum List: Equatable {
        /// `GET /issues?scope=assigned_to_me&state=opened`.
        case assignedIssues
        /// `GET /merge_requests?scope=assigned_to_me&state=opened`.
        case assignedMergeRequests
        /// `GET /merge_requests?reviewer_username=<me>&state=opened&scope=all`.
        case reviewRequests(username: String)
    }

    /// What a token may do: `api` can log time, `read_api` lists only, and a token whose scopes the
    /// server did not say (no `/personal_access_tokens/self` before GitLab 15.5) is taken as
    /// read-only.
    static func access(scopes: [String]?) -> GitLabAccess {
        guard let scopes else { return .readOnly }
        if scopes.contains("api") { return .canLogTime }
        if scopes.contains("read_api") { return .readOnly }
        return .cannotList
    }

    /// A GitLab user name: letters, digits, `_`, `-` and `.`. Checked before it goes in a query.
    static func isUsername(_ name: String) -> Bool {
        guard (1...255).contains(name.count) else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            (65...90).contains(scalar.value) || (97...122).contains(scalar.value) || (48...57).contains(scalar.value)
                || scalar == "_" || scalar == "-" || scalar == "."
        }
    }

    /// A personal access token as it can travel in a header: printable ASCII, no spaces.
    static func isPlausibleToken(_ token: String) -> Bool {
        !token.isEmpty && token.count <= 1024 && token.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
    }

    /// The task's match key. Issues and merge requests number their global ids separately, so an
    /// issue and a merge request may share one; the kind keeps them apart.
    static func remoteID(kind: GitLabKind, id: Int) -> String {
        switch kind {
        case .issue: return "issue:\(id)"
        case .mergeRequest: return "mr:\(id)"
        }
    }

    // MARK: - Requests

    static func userRequest(_ credential: GitLabCredential) -> URLRequest? {
        GitLabHost.apiURL(base: credential.baseURL, path: "/user").map { request(url: $0, method: "GET", credential: credential) }
    }

    static func tokenInfoRequest(_ credential: GitLabCredential) -> URLRequest? {
        GitLabHost.apiURL(base: credential.baseURL, path: "/personal_access_tokens/self").map { request(url: $0, method: "GET", credential: credential) }
    }

    /// One page of a list, or nil for a page Kannu never reads, a user name it would not send, or a
    /// server it would not send to.
    static func listRequest(_ credential: GitLabCredential, list: List, page: Int) -> URLRequest? {
        guard (1...maxPages).contains(page) else { return nil }
        let path: String
        var query: [URLQueryItem]
        switch list {
        case .assignedIssues:
            path = "/issues"
            query = [URLQueryItem(name: "scope", value: "assigned_to_me"), URLQueryItem(name: "state", value: "opened")]
        case .assignedMergeRequests:
            path = "/merge_requests"
            query = [URLQueryItem(name: "scope", value: "assigned_to_me"), URLQueryItem(name: "state", value: "opened")]
        case .reviewRequests(let username):
            guard isUsername(username) else { return nil }
            path = "/merge_requests"
            query = [
                URLQueryItem(name: "reviewer_username", value: username),
                URLQueryItem(name: "state", value: "opened"),
                URLQueryItem(name: "scope", value: "all"),
            ]
        }
        query += [URLQueryItem(name: "per_page", value: String(pageSize)), URLQueryItem(name: "page", value: String(page))]
        return GitLabHost.apiURL(base: credential.baseURL, path: path, query: query).map { request(url: $0, method: "GET", credential: credential) }
    }

    /// The length GitLab's `add_spent_time` takes: hours and minutes only, `1h15m`, `45m`, `2h`.
    /// Never days or weeks, which GitLab counts as 8 hours and 5 days. Whole minutes, rounded
    /// down; nil under a minute.
    static func spentTimeDuration(_ seconds: Int) -> String? {
        let minutes = seconds / 60
        guard minutes > 0 else { return nil }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        if rest == 0 { return "\(hours)h" }
        return "\(hours)h\(rest)m"
    }

    /// `POST /projects/:id/issues/:iid/add_spent_time?duration=1h15m`, or
    /// `/merge_requests/:iid/add_spent_time` for a merge request: the one write to GitLab. It needs
    /// a token with the `api` scope. GitLab records the time at the moment of the request; it
    /// returns no entry id, so an entry whose answer was lost cannot be found again. Nil for a
    /// project or number that is not one, a length under a minute or over
    /// `WorkDuration.maxSeconds`, or a server Kannu would not send to.
    ///
    /// Called from `TasksManager.confirmWorklog` only (`WorklogConsentRulesTests`).
    static func addSpentTimeRequest(_ credential: GitLabCredential, kind: GitLabKind, projectID: Int, iid: Int, seconds: Int) -> URLRequest? {
        guard projectID > 0, iid > 0, seconds <= WorkDuration.maxSeconds, let duration = spentTimeDuration(seconds) else { return nil }
        let collection = kind == .issue ? "issues" : "merge_requests"
        return GitLabHost.apiURL(
            base: credential.baseURL,
            path: "/projects/\(projectID)/\(collection)/\(iid)/add_spent_time",
            query: [URLQueryItem(name: "duration", value: duration)]
        ).map { request(url: $0, method: "POST", credential: credential) }
    }

    /// GitLab's own reason for refusing a request: its `message` (a string, or a field-to-errors
    /// object) or its `error`, as one cleaned line (`WorklogDrafts.displayReason`).
    static func refusalReason(_ data: Data?) -> String? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var parts: [String] = []
        switch object["message"] {
        case let text as String:
            parts.append(text)
        case let fields as [String: Any]:
            for key in fields.keys.sorted() {
                if let messages = fields[key] as? [Any] {
                    parts += messages.compactMap { $0 as? String }.map { "\(key) \($0)" }
                } else if let message = fields[key] as? String {
                    parts.append("\(key) \(message)")
                }
            }
        default:
            break
        }
        if let error = object["error"] as? String { parts.append(error) }
        return WorklogDrafts.displayReason(parts.joined(separator: " "))
    }

    private static func request(url: URL, method: String, credential: GitLabCredential) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(credential.token, forHTTPHeaderField: tokenHeader)
        return request
    }

    // MARK: - Answers

    static func decodeUser(_ data: Data) -> GitLabUser? {
        try? JSONDecoder().decode(GitLabUser.self, from: data)
    }

    static func decodeTokenInfo(_ data: Data) -> GitLabTokenInfo? {
        try? JSONDecoder().decode(GitLabTokenInfo.self, from: data)
    }

    static func decodeItems(_ data: Data) -> [GitLabItem]? {
        try? JSONDecoder().decode([GitLabItem].self, from: data)
    }

    enum PageStep: Equatable {
        /// Fetch this page.
        case next(Int)
        /// No more pages. `complete` is false when GitLab did not say so plainly.
        case done(complete: Bool)
        /// There are more pages, but Kannu has fetched all it will.
        case capped
    }

    /// What `X-Next-Page` says after page `page`. Empty is the last page. Missing (a server that
    /// does not page this way) is the last page only when it was not full. Anything but the very
    /// next page number is not trusted: the list is incomplete, so nothing is marked gone.
    static func nextStep(nextPageHeader header: String?, page: Int, itemCount: Int, pagesFetched: Int) -> PageStep {
        guard let header else { return .done(complete: itemCount < pageSize) }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .done(complete: true) }
        guard let next = Int(trimmed), next == page + 1 else { return .done(complete: false) }
        return pagesFetched >= maxPages ? .capped : .next(next)
    }

    /// An item as a task keeps it. The key is `references.full`, or `#45` / `!12` on a server too
    /// old to send it; an item with no title is titled by its key. Its page is kept only when it is
    /// on `base`.
    static func remoteIssue(from item: GitLabItem, kind: GitLabKind, base: String, reviewRequested: Bool) -> RemoteIssue {
        let fallbackKey = (kind == .issue ? "#" : "!") + String(item.iid)
        let key = item.references?.full.flatMap(TaskItem.cleanedTitle) ?? fallbackKey
        let status: String
        switch kind {
        case .issue:
            status = item.state.flatMap(TaskItem.cleanedTitle) ?? ""
        case .mergeRequest:
            status = reviewRequested ? String(localized: "review requested") : String(localized: "assigned to you")
        }
        let webURL = item.webURL.flatMap { GitLabHost.isWebURL($0, onServer: base) ? $0 : nil }
        return RemoteIssue(
            remoteID: remoteID(kind: kind, id: item.id),
            key: key,
            title: TaskItem.cleanedTitle(item.title ?? "") ?? key,
            status: status,
            isDoneRemotely: item.state == "closed" || item.state == "merged",
            estimateSeconds: item.timeStats?.timeEstimate.flatMap { $0 > 0 ? $0 : nil },
            spentSeconds: item.timeStats?.totalTimeSpent.flatMap { $0 > 0 ? $0 : nil },
            gitlab: RemoteIssue.GitLabRef(kind: kind, projectID: item.projectID, iid: item.iid, webURL: webURL)
        )
    }
}

/// Reading from GitLab over `IntegrationHTTP`: ephemeral, 20 s, no redirects. Read-only: nothing
/// here writes to GitLab. Foundation only, so the logic target runs it against a `URLProtocol` stub;
/// `GitLabClient` wraps it for the app with logging.
struct GitLabReader {
    enum Failure: Error, Equatable {
        /// The credential's server is not one Kannu would send a request to.
        case badServer
        /// The saved user name is not one Kannu would put in a query.
        case badUsername
        case http(HTTPOutcome)
        /// A 2xx whose body was not what GitLab sends.
        case decode
    }

    enum VerifyResult: Equatable {
        /// `scopes` is nil when the server will not say (an older GitLab); never for a failure that
        /// asking again could change.
        case verified(GitLabUser, scopes: [String]?)
        case failed(Failure)
    }

    /// What a sync read: the items, and how many of each kind, for the log line and the caption.
    struct Fetch: Equatable {
        var outcome: SyncOutcome
        var failure: Failure?
        var issueCount = 0
        var mergeRequestCount = 0
    }

    let session: URLSession

    init(session: URLSession = IntegrationHTTP.shared) {
        self.session = session
    }

    /// `GET /user`: whether the server accepts this token, and whose it is. Then the token's scopes,
    /// which decide whether time can be logged and whether the token can list at all.
    ///
    /// The scopes are nil only when the server will not say: it answers the request with a refusal
    /// or a redirect (a 404 before GitLab 15.5), or with no scopes in the body. A failure that asking
    /// again could change (429, 5xx, timeout, offline, TLS) fails the whole check instead: nothing
    /// reads the scopes again after Connect, so taking it as "cannot say" would save an `api` token
    /// as read-only for good, and let a token that cannot list through.
    func verify(_ credential: GitLabCredential) async -> VerifyResult {
        guard let request = GitLabAPI.userRequest(credential) else { return .failed(.badServer) }
        let exchange = await IntegrationHTTP.send(request, session: session)
        guard case .ok = exchange.outcome else { return .failed(.http(exchange.outcome)) }
        guard let data = exchange.data, let user = GitLabAPI.decodeUser(data) else { return .failed(.decode) }
        guard let scopesRequest = GitLabAPI.tokenInfoRequest(credential) else { return .failed(.badServer) }
        let scopes = await IntegrationHTTP.send(scopesRequest, session: session)
        switch scopes.outcome {
        case .ok:
            return .verified(user, scopes: scopes.data.flatMap(GitLabAPI.decodeTokenInfo)?.scopes)
        case .rejected, .auth, .redirected:
            return .verified(user, scopes: nil)
        case .rateLimited, .ambiguous, .offline, .failedBeforeSend:
            return .failed(.http(scopes.outcome))
        }
    }

    /// The user's open issues, and with `includeMergeRequests` the open merge requests assigned to
    /// them or waiting for their review: up to `GitLabAPI.maxPages` pages of each list. Any page that
    /// fails fails the whole sync, so a half-read list never marks the other half gone. A merge
    /// request in both lists counts once, as assigned.
    func fetchItems(_ credential: GitLabCredential, username: String, includeMergeRequests: Bool) async -> Fetch {
        let base = credential.baseURL
        var complete = true
        var items: [RemoteIssue] = []

        switch await fetchList(credential, .assignedIssues) {
        case .failure(let failure):
            return Fetch(outcome: .failed, failure: failure)
        case .success(let list):
            complete = complete && list.complete
            items += list.items.map { GitLabAPI.remoteIssue(from: $0, kind: .issue, base: base, reviewRequested: false) }
        }
        let issueCount = items.count

        if includeMergeRequests {
            guard GitLabAPI.isUsername(username) else { return Fetch(outcome: .failed, failure: .badUsername) }
            var seen = Set<Int>()
            let lists: [(GitLabAPI.List, reviewRequested: Bool)] = [
                (.assignedMergeRequests, reviewRequested: false),
                (.reviewRequests(username: username), reviewRequested: true),
            ]
            for (list, reviewRequested) in lists {
                switch await fetchList(credential, list) {
                case .failure(let failure):
                    return Fetch(outcome: .failed, failure: failure)
                case .success(let read):
                    complete = complete && read.complete
                    for item in read.items where seen.insert(item.id).inserted {
                        items.append(GitLabAPI.remoteIssue(from: item, kind: .mergeRequest, base: base, reviewRequested: reviewRequested))
                    }
                }
            }
        }
        return Fetch(
            outcome: .fetched(RemoteFetch(issues: items, complete: complete)),
            failure: nil,
            issueCount: issueCount,
            mergeRequestCount: items.count - issueCount
        )
    }

    private func fetchList(_ credential: GitLabCredential, _ list: GitLabAPI.List) async -> Result<(items: [GitLabItem], complete: Bool), Failure> {
        var items: [GitLabItem] = []
        var page = 1
        var pages = 0
        while true {
            guard let request = GitLabAPI.listRequest(credential, list: list, page: page) else {
                return .failure(.badServer)
            }
            let exchange = await IntegrationHTTP.send(request, session: session)
            guard case .ok = exchange.outcome else { return .failure(.http(exchange.outcome)) }
            guard let data = exchange.data, let read = GitLabAPI.decodeItems(data) else {
                return .failure(.decode)
            }
            pages += 1
            items += read
            let header = exchange.response?.value(forHTTPHeaderField: GitLabAPI.nextPageHeader)
            switch GitLabAPI.nextStep(nextPageHeader: header, page: page, itemCount: read.count, pagesFetched: pages) {
            case .next(let next):
                page = next
            case .done(let complete):
                return .success((items, complete))
            case .capped:
                return .success((items, false))
            }
        }
    }
}
