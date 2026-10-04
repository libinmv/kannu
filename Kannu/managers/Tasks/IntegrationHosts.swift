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

/// Why a typed Jira site was refused.
enum JiraSiteError: Error, Equatable {
    case empty
    /// A scheme other than https.
    case notHTTPS
    /// A user name or password before the host (`a@evil.com`): the classic way to make a URL read
    /// as one host and connect to another.
    case userInfo
    /// A port other than 443.
    case port
    /// Not `<site>.atlassian.net`: an IP address, a look-alike, a nested or bare domain.
    case notAtlassianCloud
    /// Not a URL or host at all: whitespace inside, a control or non-ASCII character, a backslash.
    case malformed
}

/// The one host a Jira credential may be sent to. Pure, so the logic target tests every rule.
///
/// Kannu talks to Jira Cloud only: `https://<site>.atlassian.net`, where `<site>` is one DNS label.
/// The user can type `acme`, `acme.atlassian.net` or paste any URL from their site (a board, an
/// issue); all of them become the host `acme.atlassian.net`. Everything else is refused, because
/// the API token goes to whatever host this returns.
enum JiraSite {
    static let cloudSuffix = ".atlassian.net"

    /// The site's host, lowercased, or why it was refused.
    static func normalize(_ input: String) -> Result<String, JiraSiteError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        // Printable ASCII only, with no space and no backslash: a homoglyph, a control character
        // or a backslash is how a look-alike gets past one parser and not another.
        guard trimmed.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }),
              !trimmed.contains("\\") else { return .failure(.malformed) }

        let text: String
        if let schemeEnd = trimmed.range(of: "://") {
            guard trimmed[..<schemeEnd.lowerBound].lowercased() == "https" else { return .failure(.notHTTPS) }
            text = trimmed
        } else {
            // Without "://", a colon can only start a port. Anything else is a scheme typed without
            // its slashes ("https:/acme…", "javascript:…"), which would otherwise read as a host.
            if let colon = trimmed.firstIndex(of: ":") {
                let afterColon = trimmed[trimmed.index(after: colon)...].prefix { $0 != "/" }
                guard !afterColon.isEmpty, afterColon.allSatisfy(\.isASCIIDigit) else { return .failure(.malformed) }
            }
            text = "https://" + trimmed
        }
        // Any "@" in the authority, even an empty user name: parsers disagree about these, and a
        // site never needs one.
        let afterScheme = text.range(of: "://").map { text[$0.upperBound...] } ?? Substring(text)
        let authority = afterScheme.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.contains("@") else { return .failure(.userInfo) }
        guard let components = URLComponents(string: text) else { return .failure(.malformed) }
        guard components.user == nil, components.password == nil else { return .failure(.userInfo) }
        if let port = components.port, port != 443 { return .failure(.port) }
        guard var host = components.host?.lowercased(), !host.isEmpty else { return .failure(.malformed) }
        // "acme" on its own is the site name.
        if !host.contains("."), !host.contains(":") { host += cloudSuffix }
        guard isValidHost(host) else { return .failure(.notAtlassianCloud) }
        return .success(host)
    }

    /// Exactly `<label>.atlassian.net`, lowercase, where the label is 1–63 letters, digits and
    /// hyphens, not starting or ending with a hyphen. Checked again before every URL is built, so
    /// a host that reached the Keychain some other way still cannot be used.
    static func isValidHost(_ host: String) -> Bool {
        guard host.hasSuffix(cloudSuffix) else { return false }
        let label = host.dropLast(cloudSuffix.count)
        guard (1...63).contains(label.count), label.first != "-", label.last != "-" else { return false }
        return label.unicodeScalars.allSatisfy { scalar in
            (97...122).contains(scalar.value) || (48...57).contains(scalar.value) || scalar.value == 45
        }
    }

    /// `https://<host><path>?<query>`, or nil when the host is not a Jira Cloud site or the path is
    /// not a plain absolute path. The query is built here, from Kannu's own values.
    static func apiURL(host: String, path: String, query: [URLQueryItem] = []) -> URL? {
        guard isValidHost(host), path.hasPrefix("/"), !path.contains("?"), !path.contains("#"),
              !path.contains(".."), !path.contains("//"), !path.contains("\\") else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }

    /// The issue's page on its site, or nil when the host or the key is not one Kannu would build.
    static func browseURL(host: String, key: String) -> URL? {
        guard isIssueKey(key) else { return nil }
        return apiURL(host: host, path: "/browse/\(key)")
    }

    /// `PROJ-123`: a project key (an upper-case letter, then upper-case letters, digits or
    /// underscores), a hyphen, and the issue number.
    static func isIssueKey(_ key: String) -> Bool {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let project = parts.first, let number = parts.last,
              let first = project.unicodeScalars.first, (65...90).contains(first.value),
              !number.isEmpty, number.count <= 12 else { return false }
        let projectOK = project.unicodeScalars.allSatisfy { scalar in
            (65...90).contains(scalar.value) || (48...57).contains(scalar.value) || scalar.value == 95
        }
        let numberOK = number.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
        return projectOK && numberOK
    }
}

/// Why a typed GitLab server was refused.
enum GitLabHostError: Error, Equatable {
    case empty
    /// A scheme other than https.
    case notHTTPS
    /// A user name or password before the host (`a@evil.com`).
    case userInfo
    /// A `?query` or `#fragment`: a server's address has neither.
    case queryOrFragment
    /// A path that is a page on the server (`/-/…`, `/group/app/-/issues/4`), or one with `..`, a
    /// percent escape or a character a path prefix never has.
    case badPath
    /// A port outside 1–65535.
    case port
    /// Not a host name or an IPv4 address: an IPv6 literal, a bad label, a backslash, whitespace,
    /// a control or non-ASCII character.
    case malformed
}

/// The one server a GitLab token may be sent to. Pure, so the logic target tests every rule.
///
/// Unlike Jira Cloud, GitLab may be any server: gitlab.com, or a self-managed one on the company
/// network, at a private or LAN address, on its own port, under a path prefix
/// (`https://example.com/gitlab`). What is fixed is the shape: HTTPS only, no user name or password,
/// no query, no fragment, and a path prefix of plain segments. TLS is the system's: a self-signed
/// certificate macOS does not trust fails the request, and nothing here relaxes that.
///
/// The normalized form is the server's base URL, `https://host[:port][/prefix]`, lowercase host,
/// no trailing slash, no default port. It is what the Keychain item stores and what every API URL
/// is built from.
enum GitLabHost {
    static let defaultServer = "https://gitlab.com"

    /// The base URL, or why it was refused. A pasted `…/api/v4` is the server too. On gitlab.com,
    /// which has no path prefix, a pasted page (`https://gitlab.com/dana/app`) means gitlab.com.
    static func normalize(_ input: String) -> Result<String, GitLabHostError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }),
              !trimmed.contains("\\") else { return .failure(.malformed) }

        let text: String
        if let schemeEnd = trimmed.range(of: "://") {
            guard trimmed[..<schemeEnd.lowerBound].lowercased() == "https" else { return .failure(.notHTTPS) }
            text = trimmed
        } else {
            // Without "://", a colon can only start a port ("gitlab.lan:8443"). Anything else is a
            // scheme typed without its slashes ("http:/gitlab…"), which would otherwise read as a host.
            if let colon = trimmed.firstIndex(of: ":") {
                let afterColon = trimmed[trimmed.index(after: colon)...].prefix { $0 != "/" }
                guard !afterColon.isEmpty, afterColon.allSatisfy(\.isASCIIDigit) else { return .failure(.malformed) }
            }
            text = "https://" + trimmed
        }
        guard !text.contains("?"), !text.contains("#") else { return .failure(.queryOrFragment) }
        let afterScheme = text.range(of: "://").map { text[$0.upperBound...] } ?? Substring(text)
        let authority = afterScheme.prefix { $0 != "/" }
        guard !authority.contains("@") else { return .failure(.userInfo) }
        guard !authority.contains("["), !authority.contains("]") else { return .failure(.malformed) }
        guard let components = URLComponents(string: text) else { return .failure(.malformed) }
        guard components.user == nil, components.password == nil else { return .failure(.userInfo) }
        guard let host = components.host?.lowercased(), isValidHostName(host) else { return .failure(.malformed) }
        var port: Int?
        if let typed = components.port {
            guard (1...65535).contains(typed) else { return .failure(.port) }
            port = typed == 443 ? nil : typed
        }

        var segments: [Substring] = []
        if host != "gitlab.com" {
            let path = components.percentEncodedPath
            guard !path.contains("%") else { return .failure(.badPath) }
            segments = path.split(separator: "/", omittingEmptySubsequences: false)
            // "https://host/" and "https://host/gitlab/": the slashes around the path carry nothing.
            if segments.first == "" { segments.removeFirst() }
            while segments.last == "" { segments.removeLast() }
            if segments.count >= 2, segments[segments.count - 2].lowercased() == "api", segments.last?.lowercased() == "v4" {
                segments.removeLast(2)
            }
            guard segments.allSatisfy(isPathSegment) else { return .failure(.badPath) }
        }

        var base = "https://" + host
        if let port { base += ":\(port)" }
        if !segments.isEmpty { base += "/" + segments.joined(separator: "/") }
        return .success(base)
    }

    /// Exactly a base URL `normalize` returns. Checked again before every URL is built, so a value
    /// that reached the Keychain some other way still cannot be used.
    static func isValidBase(_ base: String) -> Bool {
        normalize(base) == .success(base)
    }

    /// `<base>/api/v4<path>?<query>`, or nil when the base is not one `normalize` returns or the path
    /// is not a plain absolute path. The query is built here, from Kannu's own values, never copied
    /// from an answer.
    static func apiURL(base: String, path: String, query: [URLQueryItem] = []) -> URL? {
        guard isValidBase(base), path.hasPrefix("/"), !path.contains("?"), !path.contains("#"),
              !path.contains(".."), !path.contains("//"), !path.contains("\\"), !path.contains("%"),
              var components = URLComponents(string: base + "/api/v4" + path) else { return nil }
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }

    /// The server as the Sources row names it: `gitlab.com`, `git.acme.lan:8443/gitlab`.
    static func displayName(_ base: String) -> String {
        base.hasPrefix("https://") ? String(base.dropFirst("https://".count)) : base
    }

    /// Where the user makes a personal access token on this server.
    static func createTokenURL(base: String) -> URL? {
        guard isValidBase(base) else { return nil }
        return URL(string: base + "/-/user_settings/personal_access_tokens")
    }

    /// Whether a link from an answer (an item's `web_url`) points at this server: https, the same
    /// host and port, under the same path prefix, no user name or password. Anything else is never
    /// opened, so an answer cannot send the user somewhere else.
    static func isWebURL(_ text: String, onServer base: String) -> Bool {
        guard isValidBase(base), let server = URLComponents(string: base),
              text.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }), !text.contains("\\"),
              let link = URLComponents(string: text), link.scheme?.lowercased() == "https",
              link.user == nil, link.password == nil,
              let host = link.host?.lowercased(), host == server.host,
              (link.port == 443 ? nil : link.port) == server.port else { return false }
        let prefix = server.percentEncodedPath
        return link.percentEncodedPath.hasPrefix(prefix + "/") && !link.percentEncodedPath.contains("/../")
    }

    /// A DNS name or a dotted IPv4 address: labels of 1–63 lowercase letters, digits and hyphens,
    /// not starting or ending with a hyphen, at most 253 characters in all. A single label
    /// (`gitlab`) is allowed: a self-managed server on the local network may have no domain.
    static func isValidHostName(_ host: String) -> Bool {
        guard (1...253).contains(host.count) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            guard (1...63).contains(label.count), label.first != "-", label.last != "-" else { return false }
            return label.unicodeScalars.allSatisfy { scalar in
                (97...122).contains(scalar.value) || (48...57).contains(scalar.value) || scalar.value == 45
            }
        }
    }

    /// One segment of a path prefix: letters, digits, `.`, `_`, `~` and `-`, and never `.`, `..` or
    /// `-` on its own (`/-/` starts a page on a GitLab server, not a prefix).
    private static func isPathSegment(_ segment: Substring) -> Bool {
        guard !segment.isEmpty, segment != ".", segment != "..", segment != "-" else { return false }
        return segment.unicodeScalars.allSatisfy { scalar in
            (65...90).contains(scalar.value) || (97...122).contains(scalar.value) || (48...57).contains(scalar.value)
                || scalar == "." || scalar == "_" || scalar == "~" || scalar == "-"
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
