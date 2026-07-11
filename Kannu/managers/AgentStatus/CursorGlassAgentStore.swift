import Foundation
import SQLite3

/// Reads Cursor Glass per-agent UI state for chat titles on agent-mode sessions.
enum CursorGlassAgentStore {
    private static let globalDBPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path
    }()

    private static let cacheTTL: TimeInterval = 3.0
    private static var cachedTitles: [String: String] = [:]
    private static var cachedTitlesAt: Date?

    static func loadAgentTitles(forIDs ids: Set<String>) -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let all = loadAllAgentTitlesCached()
        return all.filter { ids.contains($0.key) }
    }

    private static func loadAllAgentTitlesCached() -> [String: String] {
        let now = Date()
        if let cachedTitlesAt, now.timeIntervalSince(cachedTitlesAt) < cacheTTL {
            return cachedTitles
        }
        let fresh = loadFromDatabase(path: globalDBPath)
        cachedTitles = fresh
        cachedTitlesAt = now
        return fresh
    }

    private static func loadFromDatabase(path: String) -> [String: String] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [:] }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT key, value FROM ItemTable WHERE key LIKE 'cursor/glass.tabs.v2/%/state.json'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var results: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let keyText = sqlite3_column_text(stmt, 0),
                  let valueText = sqlite3_column_text(stmt, 1) else { continue }

            let key = String(cString: keyText)
            let components = key.split(separator: "/")
            // Only per-agent keys: cursor/glass.tabs.v2/{workspaceId}/{agentId}/state.json
            guard components.count == 5,
                  components[0] == "cursor",
                  components[1] == "glass.tabs.v2",
                  components[4] == "state.json" else { continue }
            let agentID = String(components[3])

            let jsonString = String(cString: valueText)
            guard let data = jsonString.data(using: .utf8),
                  let stateJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = extractTitle(from: stateJSON) else {
                continue
            }
            results[agentID] = title
        }

        return results
    }

    private static func extractTitle(from stateJSON: [String: Any]) -> String? {
        guard let planTabs = stateJSON["planTabs"] as? [[String: Any]], !planTabs.isEmpty else {
            return nil
        }

        var tabsByID: [String: [String: Any]] = [:]
        for tab in planTabs {
            guard let id = tab["id"] as? String else { continue }
            tabsByID[id] = tab
        }

        if let tabOrder = stateJSON["tabOrder"] as? [String] {
            for tabID in tabOrder {
                if let tab = tabsByID[tabID], let label = tabLabel(from: tab) {
                    return label
                }
            }
        }

        for tab in planTabs {
            if let label = tabLabel(from: tab) {
                return label
            }
        }

        return nil
    }

    private static func tabLabel(from tab: [String: Any]) -> String? {
        if let kind = tab["kind"] as? String, kind.lowercased() == "plan" {
            return nil
        }
        if let label = tab["label"] as? String {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let props = tab["props"] as? [String: Any],
           let title = props["planTitle"] as? String {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
