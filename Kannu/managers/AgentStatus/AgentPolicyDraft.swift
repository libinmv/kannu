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

/// The agent policy as the rule editor holds it: rows the user can edit, and whatever else the
/// file on disk carried, kept so a Save never drops what someone wrote by hand (a top-level
/// "note", a rule's own extra key). There is no second rule set here: whether a draft may be
/// saved is `AgentPolicy.parse` of the bytes it would write, the same check the hook agrees with
/// (`HookScriptTests.testSettingsAndTheHookAgreeOnWhatIsAPolicy`).
///
/// `@unchecked Sendable`: the kept extras are JSON values (strings, numbers, arrays,
/// dictionaries, null) that are never mutated after they are read, so handing a draft from the
/// policy queue to the main actor is safe.
struct AgentPolicyDraft: Identifiable, @unchecked Sendable {
    enum Kind: String, CaseIterable, Identifiable {
        case command, tool
        var id: String { rawValue }
    }

    struct Row: Identifiable, @unchecked Sendable {
        let id = UUID()
        var kind: Kind
        var text: String
        var reason: String
        /// A rule's keys other than command, tool and reason, as the file had them.
        fileprivate var extras: [String: Any] = [:]

        init(kind: Kind = .command, text: String = "", reason: String = "") {
            self.kind = kind
            self.text = text
            self.reason = reason
        }

        /// Nothing typed at all: left out of the file rather than refused, so an unused "+" does
        /// not block Save.
        var isBlank: Bool {
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    let id = UUID()
    var rows: [Row]
    /// The file as it was when the editor opened (nil: there was none), for Save's changed-on-disk check.
    let original: Data?
    /// Top-level keys other than version and block, kept as found.
    private let otherKeys: [String: Any]

    /// A draft of the file's bytes, or of no file at all. Nil when the bytes are there but are not
    /// a policy: editing a file it cannot read would mean saving over it blind.
    init?(fileBytes: Data?) {
        original = fileBytes
        guard let fileBytes else {
            rows = []
            otherKeys = [:]
            return
        }
        guard case .success = AgentPolicy.parse(fileBytes),
              let object = (try? JSONSerialization.jsonObject(with: fileBytes)) as? [String: Any] else { return nil }
        otherKeys = object.filter { $0.key != "version" && $0.key != "block" }
        rows = (object["block"] as? [[String: Any]] ?? []).map { rule in
            let command = rule["command"] as? String
            var row = Row(kind: command != nil ? .command : .tool,
                          text: command ?? rule["tool"] as? String ?? "",
                          reason: rule["reason"] as? String ?? "")
            row.extras = rule.filter { !["command", "tool", "reason"].contains($0.key) }
            return row
        }
    }

    /// For previews and snapshots only: rows from rules already in memory, with no file behind
    /// them, so a Save from it would be checked against "no file".
    init(previewing policy: AgentPolicy) {
        original = nil
        otherKeys = [:]
        rows = policy.rules.map { rule in
            Row(kind: rule.command != nil ? .command : .tool, text: rule.displayTitle, reason: rule.reason ?? "")
        }
    }

    mutating func addRow() { rows.append(Row()) }

    mutating func removeRow(_ id: Row.ID) { rows.removeAll { $0.id == id } }

    /// What Save writes: version 1, the non-blank rows, an empty reason left out, everything else
    /// kept. Sorted keys, so the same rules always make the same file.
    func fileBytes() -> Data {
        var object = otherKeys
        object["version"] = 1
        object["block"] = savedRows.map { row -> [String: Any] in
            var rule = row.extras
            rule[row.kind.rawValue] = row.text
            if !row.reason.isEmpty { rule["reason"] = row.reason }
            return rule
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// Why Save is not allowed yet, in the parser's own words, or nil when it is. A rule number
    /// counts the rows as the user sees them, blank ones included, not as they will be saved.
    var problem: String? {
        guard case .failure(let error) = AgentPolicy.parse(fileBytes()) else { return nil }
        if case .rule(let savedIndex, let why) = error, savedIndex < savedRows.count,
           let shown = rows.firstIndex(where: { $0.id == savedRows[savedIndex].id }) {
            return AgentPolicy.LoadError.rule(shown, why).message
        }
        return error.message
    }

    private var savedRows: [Row] { rows.filter { !$0.isBlank } }
}
