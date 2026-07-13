import Foundation
import SQLite3

struct ComposerMeta: Equatable {
    let composerID: String
    let status: String?
    let updatedMs: Int64
    let checkpointMs: Int64
    let createdMs: Int64
    let name: String?
}

enum CursorComposerStore {
    private static let globalDBPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path
    }()

    private static let workspaceStorageRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage", isDirectory: true)
    }()

    private static let headersCacheTTL: TimeInterval = 3.0
    private static var cachedHeaders: [String: ComposerMeta] = [:]
    private static var cachedHeadersAt: Date?

    private static let planRegistryCacheTTL: TimeInterval = 10.0
    private static var cachedPlanNames: Set<String> = []
    private static var cachedPlanNamesAt: Date?

    static func loadPlanRegistryNames() -> Set<String> {
        let now = Date()
        if let cachedPlanNamesAt, now.timeIntervalSince(cachedPlanNamesAt) < planRegistryCacheTTL {
            return cachedPlanNames
        }
        let fresh = loadPlanRegistryNamesFromDB()
        cachedPlanNames = fresh
        cachedPlanNamesAt = now
        return fresh
    }

    static func loadComposerMeta(
        forIDs ids: Set<String>,
        includeWorkspaceDatabases: Bool = false
    ) -> [String: ComposerMeta] {
        guard !ids.isEmpty else { return [:] }

        var merged = loadComposerHeadersCached()

        for meta in loadComposerDataFromDiskKV(forIDs: ids) {
            mergeMeta(&merged, meta)
        }

        if includeWorkspaceDatabases {
            for meta in loadFromDatabase(path: globalDBPath) where ids.contains(meta.composerID) {
                mergeMeta(&merged, meta)
            }

            if let workspaceDirs = try? FileManager.default.contentsOfDirectory(
                at: workspaceStorageRoot,
                includingPropertiesForKeys: nil
            ) {
                for dir in workspaceDirs where dir.hasDirectoryPath {
                    let dbPath = dir.appendingPathComponent("state.vscdb").path
                    for meta in loadFromDatabase(path: dbPath) where ids.contains(meta.composerID) {
                        mergeMeta(&merged, meta)
                    }
                }
            }
        }

        return filter(merged, ids: ids)
    }

    private static func loadComposerHeadersCached() -> [String: ComposerMeta] {
        let now = Date()
        if let cachedHeadersAt, now.timeIntervalSince(cachedHeadersAt) < headersCacheTTL {
            return cachedHeaders
        }
        let fresh = loadComposerHeaders(from: globalDBPath)
        cachedHeaders = fresh
        cachedHeadersAt = now
        return fresh
    }

    private static func filter(_ merged: [String: ComposerMeta], ids: Set<String>) -> [String: ComposerMeta] {
        merged.filter { ids.contains($0.key) }
    }

    private static func mergeMeta(_ merged: inout [String: ComposerMeta], _ meta: ComposerMeta) {
        if let existing = merged[meta.composerID] {
            if meta.updatedMs >= existing.updatedMs {
                merged[meta.composerID] = meta
            }
        } else {
            merged[meta.composerID] = meta
        }
    }

    private static func loadComposerDataFromDiskKV(forIDs ids: Set<String>) -> [ComposerMeta] {
        guard !ids.isEmpty, FileManager.default.fileExists(atPath: globalDBPath) else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(globalDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }

        var results: [ComposerMeta] = []
        for id in ids {
            let key = "composerData:\(id)"
            var stmt: OpaquePointer?
            let sql = "SELECT value FROM cursorDiskKV WHERE key = ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { continue }
            defer { sqlite3_finalize(stmt) }

            _ = key.withCString { cKey in
                sqlite3_bind_text(stmt, 1, cKey, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }

            guard sqlite3_step(stmt) == SQLITE_ROW, let valueText = sqlite3_column_text(stmt, 0) else { continue }
            let jsonString = String(cString: valueText)
            if let meta = parseDiskKVComposerData(composerID: id, jsonString: jsonString) {
                results.append(meta)
            }
        }
        return results
    }

    private static func parseDiskKVComposerData(composerID: String, jsonString: String) -> ComposerMeta? {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let checkpoint = int64(from: dict["conversationCheckpointLastUpdatedAt"])
        let updated = max(int64(from: dict["lastUpdatedAt"]), checkpoint)
        return ComposerMeta(
            composerID: composerID,
            status: dict["status"] as? String,
            updatedMs: updated,
            checkpointMs: checkpoint,
            createdMs: int64(from: dict["createdAt"]),
            name: dict["name"] as? String
        )
    }

    private static func loadPlanRegistryNamesFromDB() -> Set<String> {
        guard FileManager.default.fileExists(atPath: globalDBPath) else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(globalDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key='composer.planRegistry'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW, let valueText = sqlite3_column_text(stmt, 0) else {
            return []
        }

        let jsonString = String(cString: valueText)
        guard let data = jsonString.data(using: .utf8),
              let registry = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var names: Set<String> = []
        for entry in registry.values {
            guard let dict = entry as? [String: Any],
                  let name = dict["name"] as? String else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                names.insert(trimmed)
            }
        }
        return names
    }

    private static func loadComposerHeaders(from path: String) -> [String: ComposerMeta] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [:] }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key='composer.composerHeaders'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [:] }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW, let valueText = sqlite3_column_text(stmt, 0) else {
            return [:]
        }

        let jsonString = String(cString: valueText)
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let composers = root["allComposers"] as? [[String: Any]] else {
            return [:]
        }

        var results: [String: ComposerMeta] = [:]
        for entry in composers {
            guard let meta = parseComposerHeaderEntry(entry) else { continue }
            results[meta.composerID] = meta
        }
        return results
    }

    private static func parseComposerHeaderEntry(_ dict: [String: Any]) -> ComposerMeta? {
        guard let id = dict["composerId"] as? String, !id.isEmpty else { return nil }
        let checkpoint = int64(from: dict["conversationCheckpointLastUpdatedAt"])
        let updated = max(int64(from: dict["lastUpdatedAt"]), checkpoint)
        return ComposerMeta(
            composerID: id,
            status: dict["status"] as? String,
            updatedMs: updated,
            checkpointMs: checkpoint,
            createdMs: int64(from: dict["createdAt"]),
            name: dict["name"] as? String
        )
    }

    private static func loadFromDatabase(path: String) -> [ComposerMeta] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }

        var results: [ComposerMeta] = []
        // Narrow key filter — avoid loading every composer-related blob.
        let sql = """
        SELECT key, value FROM ItemTable
        WHERE key = 'composer.composerHeaders'
           OR key LIKE 'composerData:%'
        LIMIT 200
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let valueText = sqlite3_column_text(stmt, 1) else { continue }
            let jsonString = String(cString: valueText)
            results.append(contentsOf: parseComposerJSON(jsonString))
        }

        return results
    }

    private static func parseComposerJSON(_ jsonString: String) -> [ComposerMeta] {
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        if let array = root as? [[String: Any]] {
            return array.compactMap(parseComposerEntry)
        }

        if let dict = root as? [String: Any] {
            if let allComposers = dict["allComposers"] as? [[String: Any]] {
                return allComposers.compactMap(parseComposerEntry)
            }
            if let composerID = dict["composerId"] as? String ?? dict["composerID"] as? String {
                if let entry = parseComposerEntry(dict) {
                    return [entry]
                }
                return [ComposerMeta(
                    composerID: composerID,
                    status: dict["status"] as? String,
                    updatedMs: int64(from: dict["lastUpdatedAt"] ?? dict["updatedAt"] ?? dict["updated_ms"]),
                    checkpointMs: int64(from: dict["checkpointMs"] ?? dict["checkpoint_ms"]),
                    createdMs: int64(from: dict["createdAt"] ?? dict["created_ms"]),
                    name: dict["name"] as? String
                )]
            }
        }

        return []
    }

    private static func parseComposerEntry(_ dict: [String: Any]) -> ComposerMeta? {
        let id = (dict["composerId"] as? String)
            ?? (dict["composerID"] as? String)
            ?? (dict["id"] as? String)
        guard let id, !id.isEmpty else { return nil }

        return ComposerMeta(
            composerID: id,
            status: dict["status"] as? String ?? dict["composerStatus"] as? String,
            updatedMs: int64(from: dict["lastUpdatedAt"] ?? dict["updatedAt"] ?? dict["updated_ms"]),
            checkpointMs: int64(from: dict["checkpointMs"] ?? dict["checkpoint_ms"]),
            createdMs: int64(from: dict["createdAt"] ?? dict["created_ms"]),
            name: dict["name"] as? String
        )
    }

    private static func int64(from value: Any?) -> Int64 {
        switch value {
        case let number as NSNumber:
            return number.int64Value
        case let string as String:
            return Int64(string) ?? 0
        default:
            return 0
        }
    }
}
