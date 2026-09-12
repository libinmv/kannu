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

/// Finds the browser tab that is playing what the media card shows, so a click can land on that
/// tab instead of just the browser. Pure: the AppleScript text and the matching live here; the
/// running happens in `BrowserTabLocator`.
///
/// What the browsers expose: Safari and every Chromium-based browser that kept Chrome's
/// scripting dictionary (Chrome, Brave, Edge, Vivaldi, Chromium) list their tabs' titles and let
/// a script make one current. Firefox exposes nothing; Arc speaks a different dictionary — both
/// fall back to plain app activation.
enum BrowserTabMatcher {
    struct Tab: Equatable {
        let windowIndex: Int
        let tabIndex: Int
        let title: String
    }

    enum Family: Equatable {
        case safari
        case chromium
    }

    static func family(forBundleIdentifier bundleIdentifier: String) -> Family? {
        switch bundleIdentifier {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return .safari
        case "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta", "com.google.Chrome.dev",
             "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
             "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
             "com.vivaldi.Vivaldi", "org.chromium.Chromium":
            return .chromium
        default:
            return nil
        }
    }

    // MARK: - Scripts

    /// One line per tab: `<window>\t<tab>\t<title>`. Indices are 1-based, as AppleScript's are.
    static func listingScript(family: Family, bundleIdentifier: String) -> String {
        let titleProperty = family == .safari ? "name" : "title"
        return """
        tell application id "\(bundleIdentifier)"
            set out to ""
            set wi to 0
            repeat with w in windows
                set wi to wi + 1
                set ti to 0
                repeat with t in tabs of w
                    set ti to ti + 1
                    try
                        set out to out & (wi as text) & tab & (ti as text) & tab & (\(titleProperty) of t) & linefeed
                    end try
                end repeat
            end repeat
            return out
        end tell
        """
    }

    /// Makes the tab current, brings its window to the front, activates the browser.
    static func selectScript(family: Family, bundleIdentifier: String, tab: Tab) -> String {
        let select = family == .safari
            ? "set current tab of window \(tab.windowIndex) to tab \(tab.tabIndex) of window \(tab.windowIndex)"
            : "set active tab index of window \(tab.windowIndex) to \(tab.tabIndex)"
        return """
        tell application id "\(bundleIdentifier)"
            \(select)
            set index of window \(tab.windowIndex) to 1
            activate
        end tell
        """
    }

    static func parseListing(_ text: String) -> [Tab] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let window = Int(parts[0]), let index = Int(parts[1]) else { return nil }
            return Tab(windowIndex: window, tabIndex: index, title: String(parts[2]))
        }
    }

    // MARK: - Matching

    /// Lowercased, diacritics folded, the site's own decorations dropped: a YouTube tab is
    /// "(2) Song Name - YouTube", Spotify's web player "Song • Artist | Spotify".
    static func normalize(_ title: String) -> String {
        var text = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        // Unread/notification counters browsers prepend.
        while let range = text.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { text.removeSubrange(range) }
        for suffix in [" - youtube music", " - youtube", " | spotify", " - spotify", " | soundcloud", " - soundcloud",
                       " | apple music", " - apple music", " | bandcamp", " - twitch", " | twitch", " - vimeo", " | netflix",
                       " - netflix", " | prime video", " - prime video"] {
            if text.hasSuffix(suffix) { text.removeLast(suffix.count) }
        }
        text = text.replacingOccurrences(of: "[\u{2022}\u{00B7}|]", with: " ", options: .regularExpression)
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
    }

    /// "lyric" counts against "lyrics": a word of four letters or more matches by prefix either
    /// way, so the sites' small rewordings do not cost the match.
    private static func matches(_ wanted: String, in candidates: Set<String>) -> Bool {
        if candidates.contains(wanted) { return true }
        guard wanted.count >= 4 else { return false }
        return candidates.contains { $0.count >= 4 && ($0.hasPrefix(wanted) || wanted.hasPrefix($0)) }
    }

    /// The tab whose title carries the track: a title substring match first, else most of the
    /// title's words; the artist breaks ties, then the frontmost window. Nil when nothing is
    /// convincing — better the plain app than the wrong tab.
    static func bestMatch(tabs: [Tab], title: String, artist: String?) -> Tab? {
        let wanted = normalize(title)
        guard wanted.count >= 3 else { return nil }
        let wantedTokens = tokens(wanted)
        let wantedArtist = artist.map(normalize).flatMap { $0.count >= 2 ? $0 : nil }
        var best: (score: Double, tab: Tab)?
        for tab in tabs {
            let candidate = normalize(tab.title)
            guard !candidate.isEmpty else { continue }
            var score = 0.0
            if candidate.contains(wanted) {
                score = 3
            } else if wantedTokens.count >= 2 {
                let candidateTokens = Set(tokens(candidate))
                let hits = wantedTokens.filter { matches($0, in: candidateTokens) }.count
                let ratio = Double(hits) / Double(wantedTokens.count)
                if ratio >= 0.6 { score = 2 + ratio }
            }
            guard score >= 2 else { continue }
            if let wantedArtist, candidate.contains(wantedArtist) { score += 0.5 }
            // Earlier windows are frontmost; earlier tabs are a stable tie-break.
            score -= Double(tab.windowIndex) * 0.001 + Double(tab.tabIndex) * 0.00001
            if best == nil || score > best!.score { best = (score, tab) }
        }
        return best?.tab
    }
}
