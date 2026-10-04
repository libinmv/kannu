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

/// Which pasteboard contents Kannu's clipboard history may record.
///
/// Password managers and other apps mark a copy as private by adding a marker type from the
/// nspasteboard.org convention: `org.nspasteboard.ConcealedType` for a secret (a password, a
/// key), `org.nspasteboard.TransientType` for something put there only briefly by automation.
/// The history persists what it records (UserDefaults, in plain text), so honouring the markers
/// is the difference between a password manager's copy vanishing on schedule and living on in
/// Kannu's preferences file. Kannu's own copies of secrets carry the concealed marker too.
///
/// A token page carries no marker: GitLab's or Atlassian's "copy token" button puts a fresh
/// access token on the pasteboard as ordinary text. So the history also skips text holding a
/// token-shaped secret, found the way the agent hook script finds one in a prompt.
enum ClipboardCapturePolicy {
    static let concealedType = "org.nspasteboard.ConcealedType"
    static let transientType = "org.nspasteboard.TransientType"

    /// `types` are the raw pasteboard type identifiers of the current contents.
    static func shouldRecord(types: [String]) -> Bool {
        !types.contains(concealedType) && !types.contains(transientType)
    }

    /// `text` is what a copy would put in the history: its plain text, its URL, or the plain text
    /// of its rich text.
    static func shouldRecord(text: String) -> Bool {
        secretKind(in: text) == nil
    }

    // MARK: - Token-shaped secrets

    /// One secret format: the hook script's name for it, the literals looked for before the
    /// pattern runs, and the pattern, which starts with its literal.
    struct SecretFormat {
        let kind: String
        let anchors: [String]
        let pattern: String
        let regex: NSRegularExpression?

        init(_ kind: String, _ anchors: [String], _ pattern: String) {
            self.kind = kind
            self.anchors = anchors
            self.pattern = pattern
            regex = try? NSRegularExpression(pattern: pattern)
        }
    }

    static let privateKeyKind = "private_key"

    /// The hook script's `SEC_PATTERNS` (in `AgentHookInstaller.swift`), character for character,
    /// plus Atlassian's API tokens (Jira, Confluence), which the hook does not look for. The
    /// minimum lengths are the vendors' own, so a word that merely starts like a token, "task-" or
    /// "risk-", is never one. `ClipboardCapturePolicyTests` fails if the two lists drift apart.
    static let secretFormats: [SecretFormat] = [
        SecretFormat(privateKeyKind, ["PRIVATE KEY"], "-----BEGIN (?:[A-Z0-9]{2,12} ){0,2}PRIVATE KEY(?: BLOCK)?-----"),
        SecretFormat("anthropic_key", ["sk-ant-"], "sk-ant-[A-Za-z0-9_-]{32,300}"),
        SecretFormat("openai_key", ["sk-"], "sk-(?!ant-)(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{32,300}"),
        SecretFormat("aws_access_key", ["AKIA", "ASIA"], "(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Za-z0-9])"),
        SecretFormat("github_token", ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"],
                     "(?:gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{50,255})(?![A-Za-z0-9_])"),
        SecretFormat("gitlab_token", ["glpat-"], "glpat-[A-Za-z0-9_-]{20,64}"),
        SecretFormat("slack_token", ["xox"], "xox[abprs]-[A-Za-z0-9-]{10,250}"),
        SecretFormat("stripe_key", ["k_live_"], "(?:sk|rk)_live_[A-Za-z0-9]{20,250}"),
        SecretFormat("google_api_key", ["AIza"], "AIza[A-Za-z0-9_-]{35}(?![A-Za-z0-9_-])"),
        SecretFormat("npm_token", ["npm_"], "npm_[A-Za-z0-9]{36}(?![A-Za-z0-9])"),
        SecretFormat("huggingface_token", ["hf_"], "hf_[A-Za-z0-9]{34,64}(?![A-Za-z0-9])"),
        // Atlassian API tokens are "ATATT" and about 190 base64url characters ending "=" and an
        // 8-hex checksum. 100 is far below the real length and far above anything in prose.
        SecretFormat("atlassian_token", ["ATATT"], "ATATT[A-Za-z0-9_=-]{100,300}"),
    ]

    /// The hook's `SEC_LITERAL_PREFIXES`, plus Atlassian's: the part of a token that says whose it
    /// is, left out of the plausibility check below.
    static let literalPrefixes = ["github_pat_", "sk-svcacct-", "sk-admin-", "sk-proj-", "sk-ant-",
                                  "sk_live_", "rk_live_", "glpat-", "npm_", "hf_", "ATATT"]

    /// The hook's `SEC_PLACEHOLDER_WORDS`: a documentation sample is not a secret.
    static let placeholderWords = ["EXAMPLE", "XXXXXXXX", "PLACEHOLDER", "REDACTED", "YOUR_", "DUMMY"]

    /// The kind of the first token-shaped secret in `text`, or nil when there is none.
    static func secretKind(in text: String) -> String? {
        let string = text as NSString
        let whole = NSRange(location: 0, length: string.length)
        for format in secretFormats {
            guard let regex = format.regex,
                  format.anchors.contains(where: { string.range(of: $0).location != NSNotFound }) else { continue }
            var found = false
            regex.enumerateMatches(in: text, range: whole) { match, _, stop in
                guard let range = match?.range, isSecret(at: range, kind: format.kind, in: string) else { return }
                found = true
                stop.pointee = true
            }
            if found { return format.kind }
        }
        return nil
    }

    /// The hook's acceptance rules for a match: a whole token (no word character just before it)
    /// that is not a placeholder and looks random; for a private key, actual key material after
    /// the header.
    ///
    /// "Looks random" is looser here than in the hook, which wants a digit in the body. A real
    /// token can have none: about 1 GitLab token in 20 to 30, 1 AWS key ID in 30, and every
    /// Hugging Face token, which is letters only. The hook trades those for fewer false alarms;
    /// here a missed token is persisted in plain text while a false alarm only drops one history
    /// entry. So a body with both cases counts too, which still turns away lower-case words
    /// ("glpat-your-token-goes-here", "sk-learn-…"), and an AWS key ID, whose format has no lower
    /// case, needs neither.
    private static func isSecret(at range: NSRange, kind: String, in string: NSString) -> Bool {
        if kind == privateKeyKind {
            return hasKeyMaterial(after: range, in: string)
        }
        if range.location > 0, isWordCharacter(string.character(at: range.location - 1)) {
            return false
        }
        let token = string.substring(with: range)
        let upper = token.uppercased()
        if placeholderWords.contains(where: { upper.contains($0) }) {
            return false
        }
        let body = token.dropFirst(prefix(of: token, kind: kind).count)
        let hasUpper = body.contains { $0.isASCII && $0.isUppercase }
        let hasLower = body.contains { $0.isASCII && $0.isLowercase }
        guard Set(body).count >= 8, hasUpper || hasLower else { return false }
        return body.contains { $0.isASCII && $0.isNumber } || (hasUpper && hasLower) || kind == "aws_access_key"
    }

    /// The hook's `sec_prefix`, for the token kinds.
    private static func prefix(of token: String, kind: String) -> String {
        if let literal = literalPrefixes.first(where: { token.hasPrefix($0) }) {
            return literal
        }
        switch kind {
        case "slack_token": return String(token.prefix(5))
        case "openai_key": return "sk-"
        default: return String(token.prefix(4))
        }
    }

    /// A base64 body of at least 64 characters between a private key's header and the next "-----"
    /// (its footer, when the copy has one). Line breaks, raw or written "\n" inside a JSON or code
    /// string, continue the body; any other character (a space, a quote, punctuation) ends it. So
    /// a sentence or a line of code that only names the header is not a key, however many letters
    /// follow it. The hook requires the footer instead; here a copy cut short of it still holds
    /// key material, so the header and a body are enough.
    private static func hasKeyMaterial(after header: NSRange, in string: NSString) -> Bool {
        let start = NSMaxRange(header)
        let limit = min(string.length, start + 20_000)
        let footer = string.range(of: "-----", range: NSRange(location: start, length: limit - start))
        let end = footer.location == NSNotFound ? limit : footer.location
        var run = 0
        var index = start
        while index < end {
            let unit = string.character(at: index)
            if isBase64Character(unit) {
                run += 1
                if run >= 64 { return true }
            } else if unit == 0x5C, index + 1 < end, [0x6E, 0x72].contains(string.character(at: index + 1)) {
                index += 1   // "\n" or "\r" written out
            } else if unit != 0x0A && unit != 0x0D {
                run = 0
            }
            index += 1
        }
        return false
    }

    /// The hook's `SEC_WORD_CHARS`: ASCII letters, digits, "_" and "-".
    private static func isWordCharacter(_ unit: unichar) -> Bool {
        isASCIIAlphanumeric(unit) || unit == 0x5F || unit == 0x2D
    }

    private static func isBase64Character(_ unit: unichar) -> Bool {
        isASCIIAlphanumeric(unit) || unit == 0x2B || unit == 0x2F || unit == 0x3D
    }

    private static func isASCIIAlphanumeric(_ unit: unichar) -> Bool {
        (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }
}
