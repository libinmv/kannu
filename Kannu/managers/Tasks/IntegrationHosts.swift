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

    /// `https://<host><path>`, or nil when the host is not a Jira Cloud site or the path is not a
    /// plain absolute path.
    static func apiURL(host: String, path: String) -> URL? {
        guard isValidHost(host), path.hasPrefix("/"), !path.contains("?"), !path.contains("#"),
              !path.contains(".."), !path.contains("//"), !path.contains("\\") else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
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

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
