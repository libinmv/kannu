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

/// Kannu's own "a new MCP server appeared" check. Reads the MCP server names each agent's
/// settings declare, remembers them per file, and reports a name that was not there before. The
/// first look at a file only learns what is there (trust on first use), so installing Kannu never
/// raises a wall of findings. Names and a short "runs" line only: never env values or headers,
/// and URLs are cut to scheme and host (paths and queries can carry tokens).
enum MCPServerWatch {
    /// One settings file that can declare MCP servers.
    struct Location: Equatable {
        enum Format: Equatable {
            /// `{"mcpServers": {...}}` — Claude Desktop, Cursor, Gemini CLI, Qwen Code, `.mcp.json`.
            case mcpServers
            /// `{"servers": {...}}` — VS Code's `mcp.json`.
            case vsCodeServers
            /// `{"mcp": {...}}` — opencode.
            case opencode
            /// `~/.claude.json`: user-scope `mcpServers` plus `projects.<path>.mcpServers`.
            case claudeUserConfig
            /// `[mcp_servers.<name>]` tables in Codex's `config.toml`.
            case codexTOML
        }

        let path: String
        let appName: String
        let format: Format
        /// Comments and trailing commas allowed (VS Code, Gemini CLI, Qwen Code, opencode).
        let json5: Bool
        let projectRoot: String?
    }

    struct Server: Equatable, Codable {
        /// The project a `~/.claude.json` local-scope server belongs to; nil elsewhere.
        let scope: String?
        let name: String
        /// "npx @modelcontextprotocol/server-github", "https://mcp.example.com"; may be empty.
        let runs: String

        var key: String { (scope ?? "") + "|" + name }
    }

    static func globalLocations(home: String) -> [Location] {
        let support = home + "/Library/Application Support"
        return [
            Location(path: home + "/.claude.json", appName: "Claude Code", format: .claudeUserConfig, json5: false, projectRoot: nil),
            Location(path: home + "/.claude/mcp.json", appName: "Claude Code", format: .mcpServers, json5: false, projectRoot: nil),
            Location(path: support + "/Claude/claude_desktop_config.json", appName: "Claude Desktop", format: .mcpServers, json5: false, projectRoot: nil),
            Location(path: home + "/.cursor/mcp.json", appName: "Cursor", format: .mcpServers, json5: false, projectRoot: nil),
            Location(path: support + "/Code/User/mcp.json", appName: "VS Code", format: .vsCodeServers, json5: true, projectRoot: nil),
            Location(path: home + "/.codex/config.toml", appName: "Codex", format: .codexTOML, json5: false, projectRoot: nil),
            Location(path: home + "/.gemini/settings.json", appName: "Gemini CLI", format: .mcpServers, json5: true, projectRoot: nil),
            Location(path: home + "/.qwen/settings.json", appName: "Qwen Code", format: .mcpServers, json5: true, projectRoot: nil),
            Location(path: home + "/.config/opencode/opencode.json", appName: "opencode", format: .opencode, json5: true, projectRoot: nil),
        ]
    }

    static func projectLocations(root: String) -> [Location] {
        [
            Location(path: root + "/.mcp.json", appName: "Claude Code", format: .mcpServers, json5: false, projectRoot: root),
            Location(path: root + "/.cursor/mcp.json", appName: "Cursor", format: .mcpServers, json5: false, projectRoot: root),
            Location(path: root + "/.vscode/mcp.json", appName: "VS Code", format: .vsCodeServers, json5: true, projectRoot: root),
            Location(path: root + "/.gemini/settings.json", appName: "Gemini CLI", format: .mcpServers, json5: true, projectRoot: root),
            Location(path: root + "/.qwen/settings.json", appName: "Qwen Code", format: .mcpServers, json5: true, projectRoot: root),
            Location(path: root + "/opencode.json", appName: "opencode", format: .opencode, json5: true, projectRoot: root),
        ]
    }

    /// Folders macOS guards with a permission prompt (Desktop, Documents, Downloads, iCloud and
    /// cloud storage, other volumes). A background check must never be the thing that asks.
    static func isProtectedRoot(_ root: String, home: String) -> Bool {
        let guarded = ["/Desktop", "/Documents", "/Downloads", "/Library/Mobile Documents", "/Library/CloudStorage"]
        if guarded.contains(where: { root == home + $0 || root.hasPrefix(home + $0 + "/") }) { return true }
        return root.hasPrefix("/Volumes/")
    }

    /// The project folders worth a look: sessions' working folders, absolute, not the home folder
    /// (its configs are the global ones), not protected, at most `limit`.
    static func projectRoots(_ cwds: [String?], home: String, limit: Int = 20) -> [String] {
        var out: [String] = []
        for case let cwd? in cwds {
            let root = cwd.hasSuffix("/") && cwd.count > 1 ? String(cwd.dropLast()) : cwd
            guard root.hasPrefix("/"), root != home, root != "/", !isProtectedRoot(root, home: home),
                  !out.contains(root) else { continue }
            out.append(root)
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: - Parsing

    /// Servers in one file's contents; nil when the contents cannot be read as that format (a
    /// half-written file must not look like "every server was removed").
    static func servers(in data: Data, format: Location.Format, json5: Bool) -> [Server]? {
        if format == .codexTOML {
            return String(data: data, encoding: .utf8).map(codexServers(inTOML:))
        }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [] }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: json5 ? [.json5Allowed] : []),
              let root = object as? [String: Any] else { return nil }
        switch format {
        case .mcpServers: return entries(root["mcpServers"], scope: nil)
        case .vsCodeServers: return entries(root["servers"], scope: nil)
        case .opencode: return entries(root["mcp"], scope: nil)
        case .claudeUserConfig:
            var out = entries(root["mcpServers"], scope: nil)
            if let projects = root["projects"] as? [String: Any] {
                for path in projects.keys.sorted() {
                    guard let project = projects[path] as? [String: Any] else { continue }
                    out += entries(project["mcpServers"], scope: sanitized(path, limit: 300))
                }
            }
            return out
        case .codexTOML:
            return nil
        }
    }

    private static func entries(_ value: Any?, scope: String?) -> [Server] {
        guard let table = value as? [String: Any] else { return [] }
        return table.keys.sorted().compactMap { raw in
            let name = sanitized(raw, limit: 80)
            guard !name.isEmpty else { return nil }
            return Server(scope: scope, name: name, runs: runs(of: table[raw] as? [String: Any] ?? [:]))
        }
    }

    /// `[mcp_servers.name]` and `[mcp_servers."dotted.name"]`; sub-tables such as
    /// `[mcp_servers.name.env]` name the same server.
    static func codexServers(inTOML text: String) -> [Server] {
        var names: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let header = "[mcp_servers."
            guard line.hasPrefix(header) else { continue }
            var rest = Substring(line.dropFirst(header.count))
            let name: String
            if rest.first == "\"" {
                rest = rest.dropFirst()
                guard let close = rest.firstIndex(of: "\"") else { continue }
                name = String(rest[..<close])
            } else {
                name = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
            }
            let clean = sanitized(name, limit: 80)
            guard !clean.isEmpty, !names.contains(clean) else { continue }
            names.append(clean)
        }
        return names.map { Server(scope: nil, name: $0, runs: "") }
    }

    /// A short, non-secret description of what a server runs.
    static func runs(of entry: [String: Any]) -> String {
        for key in ["url", "serverUrl", "httpUrl"] {
            if let raw = entry[key] as? String, let components = URLComponents(string: raw),
               let host = components.host, !host.isEmpty {
                return sanitized("\(components.scheme ?? "https")://\(host)", limit: 120)
            }
        }
        var command = entry["command"] as? String
        var args = (entry["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        if command == nil, let list = entry["command"] as? [Any] {
            let strings = list.compactMap { $0 as? String }
            command = strings.first
            args = Array(strings.dropFirst())
        }
        guard let command, !command.isEmpty else { return "" }
        var parts = [sanitized((command as NSString).lastPathComponent, limit: 40)]
        if let package = args.first(where: isPackageLike) { parts.append(package) }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "@scope/name", "name@1.2.3", "ghcr.io/org/image" — lowercase package-like text only, so a
    /// token passed as an argument is never shown.
    static func isPackageLike(_ arg: String) -> Bool {
        guard (2...80).contains(arg.count), !arg.hasPrefix("-"),
              arg.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || "@/._-".unicodeScalars.contains($0) }),
              arg.unicodeScalars.contains(where: { ("a"..."z").contains($0) }) else { return false }
        var run = 0
        for scalar in arg.unicodeScalars {
            run = ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) ? run + 1 : 0
            if run >= 24 { return false }
        }
        return true
    }

    private static func sanitized(_ text: String, limit: Int) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { (0x20...0x7E).contains($0.value) }.prefix(limit)))
    }

    // MARK: - Reading (off the main thread; files are re-read only when they change)

    struct CachedRead: Equatable {
        let modified: Date?
        let size: Int
        /// nil: present but unreadable as its format.
        let servers: [Server]?
    }

    /// A missing file declares no servers; an unreadable one is left out, so what Kannu knew
    /// about it stays.
    static func read(_ locations: [Location], cache: [String: CachedRead],
                     fileManager: FileManager = .default) -> (reads: [String: [Server]], cache: [String: CachedRead]) {
        var reads: [String: [Server]] = [:]
        var fresh: [String: CachedRead] = [:]
        for location in locations where fresh[location.path] == nil {
            guard fileManager.fileExists(atPath: location.path) else {
                fresh[location.path] = CachedRead(modified: nil, size: -1, servers: [])
                reads[location.path] = []
                continue
            }
            let url = URL(fileURLWithPath: location.path)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard let values, values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            if let cached = cache[location.path], cached.modified == values.contentModificationDate, cached.size == size {
                fresh[location.path] = cached
                if let servers = cached.servers { reads[location.path] = servers }
                continue
            }
            let servers = size <= 8 * 1024 * 1024 ? (try? Data(contentsOf: url)).flatMap {
                Self.servers(in: $0, format: location.format, json5: location.json5)
            } : nil
            fresh[location.path] = CachedRead(modified: values.contentModificationDate, size: size, servers: servers)
            if let servers { reads[location.path] = servers }
        }
        return (reads, fresh)
    }

    // MARK: - What is new

    /// Server keys per file, as last read.
    struct Baseline: Codable, Equatable {
        var serversByConfig: [String: [String]] = [:]
        static let cap = 300
    }

    /// A server that appeared in a file Kannu had already read.
    struct Addition: Codable, Equatable {
        let configPath: String
        let appName: String
        let projectRoot: String?
        let scope: String?
        let name: String
        let runs: String
        let firstSeenMs: Int64

        var key: String { (scope ?? "") + "|" + name }

        static let rule = "mcp_server_added"

        /// The time is in the id: removed and added again is news again.
        var findingID: String {
            AgentSecurityFinding.stableID(source: .kannu, rule: Self.rule, subject: configPath,
                                          evidence: [key, String(firstSeenMs)])
        }

        func finding(home: String) -> AgentSecurityFinding {
            func shown(_ path: String) -> String { path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path }
            var lines: [String] = []
            if !runs.isEmpty { lines.append(String(localized: "Runs: \(runs)")) }
            var place = String(localized: "In \(shown(configPath))")
            if let scope { place += " · " + String(localized: "project \(shown(scope))") }
            lines.append(place)
            let seen = Date(timeIntervalSince1970: TimeInterval(firstSeenMs) / 1000)
            lines.append(String(localized: "First seen \(seen.formatted(date: .abbreviated, time: .shortened))"))
            return AgentSecurityFinding(
                id: findingID,
                source: .kannu,
                rule: Self.rule,
                severity: .medium,
                title: String(localized: "New MCP server: \(name)"),
                // Pushed as is: the server's name and the app only, no paths.
                summary: String(localized: "“\(name)” was added to \(appName)'s MCP servers. If you did not add it, check where it came from."),
                evidence: lines,
                assetName: appName,
                assetPath: configPath,
                sessionID: nil,
                firstSeen: seen
            )
        }
    }

    /// Updates the baseline with this round's reads. A file seen for the first time is learned
    /// silently; a file not read this round (not watched now, or unreadable) keeps what was known.
    static func compare(baseline: Baseline, reads: [String: [Server]], locations: [Location],
                        nowMs: Int64) -> (baseline: Baseline, additions: [Addition]) {
        var updated = baseline
        var additions: [Addition] = []
        var handled = Set<String>()
        for location in locations where handled.insert(location.path).inserted {
            guard let servers = reads[location.path] else { continue }
            if let known = baseline.serversByConfig[location.path] {
                let knownKeys = Set(known)
                var added = Set<String>()
                for server in servers where !knownKeys.contains(server.key) && added.insert(server.key).inserted {
                    additions.append(Addition(configPath: location.path, appName: location.appName,
                                              projectRoot: location.projectRoot, scope: server.scope,
                                              name: server.name, runs: server.runs, firstSeenMs: nowMs))
                }
            }
            updated.serversByConfig[location.path] = Array(Set(servers.map(\.key))).sorted()
        }
        if updated.serversByConfig.count > Baseline.cap {
            let current = Set(locations.map(\.path))
            for path in updated.serversByConfig.keys.sorted() where !current.contains(path) {
                updated.serversByConfig[path] = nil
                if updated.serversByConfig.count <= Baseline.cap { break }
            }
        }
        return (updated, additions)
    }

    /// Additions whose server is gone from a file read this round are dropped.
    static func pruning(_ additions: [Addition], reads: [String: [Server]]) -> [Addition] {
        additions.filter { addition in
            guard let servers = reads[addition.configPath] else { return true }
            return servers.contains { $0.key == addition.key }
        }
    }

    /// Only the global files, as the ADR scan trigger compares them.
    static func inventory(_ reads: [String: [Server]], home: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for location in globalLocations(home: home) {
            if let servers = reads[location.path] { out[location.path] = servers.map(\.key).sorted() }
        }
        return out
    }
}
