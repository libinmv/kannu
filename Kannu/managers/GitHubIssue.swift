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

/// Builds the prefilled-issue link a user is offered after a freeze or a crash.
///
/// Kannu never posts anything itself: this opens the browser with the fields filled in, and the user
/// reads it and presses Submit. Shared by `HangReport` and `CrashReport` so the two encodings cannot
/// drift — they did, and the `+` below is why.
enum GitHubIssue {

    /// Comfortably inside what GitHub accepts, and inside what Safari and Chrome will open.
    static let urlLengthLimit = 7500

    /// `https://github.com/<owner>/<repo>/issues/new?title=…&body=…`, or nil when the result would
    /// be too long to open.
    ///
    /// `URLComponents` follows RFC 3986, where `+` is a legal query character, so it leaves it
    /// alone. GitHub — like every form-urlencoded reader — decodes `+` as a space, which turns every
    /// `symbol + 124` stack frame into `symbol   124` and every `+0530` timestamp into ` 0530`. The
    /// substitution is safe because the setter has already encoded real spaces as `%20`, so any `+`
    /// left in the query came from a value.
    ///
    /// The length check is against the *encoded* URL: percent-encoding inflates a stack by roughly a
    /// third, so a body budgeted on its raw length can still produce a link that will not open.
    static func url(repository: String, title: String, body: String, label: String) -> URL? {
        var components = URLComponents(string: "https://github.com/\(repository)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "labels", value: label)
        ]
        let encoded = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encoded
        guard let url = components?.url, url.absoluteString.count <= urlLengthLimit else { return nil }
        return url
    }
}
