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

/// The user's agent policy: `~/.kannu/agent-policy.json`, commands and tools an agent may not
/// use. Kannu never writes rules of its own; the only write is `importPolicy`, which copies a
/// file the user chose, byte for byte, after checking it. The hook is the only matcher; this
/// type reads and checks the file so Settings can say what it holds, or why the hook is ignoring it. The two agree on what is
/// *valid* — the caps and the shape below mirror the hook's `load_policy` — and never on what
/// *matches*, so matching lives in one place and cannot drift (docs/REGRESSIONS.md entry 1).
struct AgentPolicy: Equatable {
    struct Rule: Equatable {
        var command: String?
        var tool: String?
        var reason: String?

        /// What the rule matches, for display: the command phrase or the tool name.
        var displayTitle: String { command ?? tool ?? "" }
        /// `terminal` for a command rule, a wrench for a tool rule — the View-rules list's icon.
        var displayIconName: String { command != nil ? "terminal" : "wrench.and.screwdriver" }
    }

    static var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kannu/agent-policy.json")
    }
    /// Marker file in the status directory the hook reads: present means "block, don't only report".
    static let enforceMarker = ".kannu-policy-enforce"
    static let maxBytes = 65_536
    static let maxRules = 200
    static let maxLength = 200

    let rules: [Rule]

    enum LoadError: Error, Equatable {
        case notFound
        case unreadable
        case notJSON
        case tooLarge(Int)
        case notAnObject
        case version
        case tooManyRules(Int)
        case rule(Int, String)
        /// Import only: the picked file was valid but could not be written into place.
        case notWritten

        /// Plain words for Settings; the hook ignores the file for the same reason.
        var message: String {
            switch self {
            case .notFound: return String(localized: "No policy file yet.")
            case .unreadable: return String(localized: "The policy file could not be read.")
            case .notJSON: return String(localized: "The policy file is not valid JSON.")
            case .tooLarge(let bytes): return String(localized: "The policy file is \(bytes) bytes; the limit is \(maxBytes).")
            case .notAnObject: return String(localized: "The policy file must be a JSON object with \"version\" and \"block\".")
            case .version: return String(localized: "\"version\" must be 1.")
            case .tooManyRules(let count): return String(localized: "\(count) rules; the limit is \(maxRules).")
            case .rule(let index, let why): return String(localized: "Rule \(index + 1): \(why)")
            case .notWritten: return String(localized: "The file is valid, but ~/.kannu/agent-policy.json could not be written.")
            }
        }
    }

    static func load(at url: URL = fileURL) -> Result<AgentPolicy, LoadError> {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .failure(.notFound) }
        guard !isDirectory.boolValue else { return .failure(.unreadable) }
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        return parse(data)
    }

    static func parse(_ data: Data) -> Result<AgentPolicy, LoadError> {
        guard data.count <= maxBytes else { return .failure(.tooLarge(data.count)) }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return .failure(.notJSON) }
        guard let object = json as? [String: Any] else { return .failure(.notAnObject) }
        // JSON `true` bridges to NSNumber too, and `is Bool` is true for the number 1: ask CoreFoundation.
        guard let version = object["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.intValue == 1 else { return .failure(.version) }
        guard let block = object["block"] as? [Any] else { return .failure(.notAnObject) }
        guard block.count <= maxRules else { return .failure(.tooManyRules(block.count)) }
        var rules: [Rule] = []
        for (index, item) in block.enumerated() {
            guard let rule = item as? [String: Any] else { return .failure(.rule(index, String(localized: "each rule is an object"))) }
            let reason = rule["reason"]
            if let reason, !(reason is NSNull) {
                guard let text = reason as? String, isText(text) else {
                    return .failure(.rule(index, String(localized: "\"reason\" must be text of at most \(maxLength) characters")))
                }
            }
            let command = rule["command"], tool = rule["tool"]
            if let command, !(command is NSNull) {
                guard tool == nil || tool is NSNull else { return .failure(.rule(index, String(localized: "use \"command\" or \"tool\", not both"))) }
                guard let text = command as? String, isText(text), !text.split(separator: " ").isEmpty else {
                    return .failure(.rule(index, String(localized: "\"command\" must be a word or phrase of at most \(maxLength) characters")))
                }
                rules.append(Rule(command: text, tool: nil, reason: reason as? String))
            } else if let tool, !(tool is NSNull) {
                guard let text = tool as? String, isText(text), !text.contains(" "), text.trimmingCharacters(in: .whitespaces) == text else {
                    return .failure(.rule(index, String(localized: "\"tool\" must be one name of at most \(maxLength) characters")))
                }
                rules.append(Rule(command: nil, tool: text, reason: reason as? String))
            } else {
                return .failure(.rule(index, String(localized: "needs \"command\" or \"tool\"")))
            }
        }
        return .success(AgentPolicy(rules: rules))
    }

    /// Copies a policy file the user picked into place — the "Import…" button. The source is
    /// validated with the same parser the status row uses; a file that would not count as a
    /// policy is never written, so Import cannot break a working policy. The write is the copied
    /// bytes verbatim (no re-serialisation), atomic, after creating `~/.kannu` if needed.
    /// This is the one place Kannu writes the policy file, and only a user's click reaches it.
    static func importPolicy(from source: URL, to destination: URL = fileURL) -> Result<AgentPolicy, LoadError> {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return .failure(.unreadable) }
        // Size first, so a huge pick is refused without reading it whole.
        if let size = (try? FileManager.default.attributesOfItem(atPath: source.path))?[.size] as? Int,
           size > maxBytes {
            return .failure(.tooLarge(size))
        }
        guard let data = try? Data(contentsOf: source) else { return .failure(.unreadable) }
        switch parse(data) {
        case .failure(let error):
            return .failure(error)
        case .success(let policy):
            let directory = destination.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                try data.write(to: destination, options: .atomic)
            } catch {
                // Not `.unreadable`: the pick was fine, the destination was not — say which.
                return .failure(.notWritten)
            }
            return .success(policy)
        }
    }

    /// Non-empty, capped, no control characters — the hook's `policy_text`.
    static func isText(_ text: String) -> Bool {
        !text.isEmpty && text.count <= maxLength && text.unicodeScalars.allSatisfy { $0.value >= 32 }
    }

    /// What "Copy a prompt that drafts a policy" puts on the pasteboard, for the user's own agent.
    static let draftingPrompt = """
        Write ~/.kannu/agent-policy.json for Kannu, the notch app that watches AI coding agents on this Mac. \
        Format: {"version": 1, "block": [ {"command": "<word or phrase>", "reason": "<optional>"}, \
        {"tool": "<tool name>", "reason": "<optional>"} ]}. A "command" rule matches a shell command whose first \
        word (after sudo, env or nohup) is that word or its basename, in any segment joined by ;, &&, || or |; \
        a multi-word rule matches a segment that starts with it; there is no regex. A "tool" rule matches a \
        tool by its exact name (for example WebFetch). At most 200 rules, 200 characters each, 64 KB in all. \
        Ask me which commands and tools to block and why, propose sensible defaults (ssh, scp, sftp, "rm -rf /", \
        "curl | sh"), then write the file and show it to me. Do not put anything else in the file.
        """
}
