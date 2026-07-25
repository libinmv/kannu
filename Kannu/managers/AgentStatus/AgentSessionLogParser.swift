import Foundation

enum AgentSessionLogProvider: String, CaseIterable {
    case codex
    case claude

    static func from(hookProvider: String) -> AgentSessionLogProvider? {
        switch hookProvider.lowercased() {
        case "codex": return .codex
        case "claude": return .claude
        default: return nil
        }
    }
}

enum AgentSessionLogParser {
    private static let leadingByteLimit = 32_000
    private static let trailingByteLimit = 16_000
    private static let maxSessionsPerScan = 24
    private static let pathListCacheTTL: TimeInterval = 2.0

    private static var cachedPaths: [AgentSessionLogProvider: [URL]] = [:]
    private static var cachedPathsAt: Date?
    private static var cachedPathsMaxAgeMinutes: Int = 0

    static var codexSessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    static var claudeProjectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    static var claudeSessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    static func invalidatePathCache() {
        cachedPaths = [:]
        cachedPathsAt = nil
    }

    static func listRecentSessionPaths(
        provider: AgentSessionLogProvider,
        maxAgeMinutes: Int,
        now: Date = Date()
    ) -> [URL] {
        if let cachedPathsAt,
           cachedPathsMaxAgeMinutes == maxAgeMinutes,
           now.timeIntervalSince(cachedPathsAt) < pathListCacheTTL,
           let cached = cachedPaths[provider] {
            return cached
        }

        let root = rootDirectory(for: provider)
        guard FileManager.default.fileExists(atPath: root.path) else {
            cachedPaths[provider] = []
            cachedPathsAt = now
            cachedPathsMaxAgeMinutes = maxAgeMinutes
            return []
        }

        let cutoff = now.addingTimeInterval(-TimeInterval(maxAgeMinutes * 60))
        var results: [(url: URL, mtime: Date)] = []

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            cachedPaths[provider] = []
            cachedPathsAt = now
            cachedPathsMaxAgeMinutes = maxAgeMinutes
            return []
        }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard isSessionLogFile(url, provider: provider) else { continue }

            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = values.contentModificationDate,
                  mtime >= cutoff else { continue }

            results.append((url, mtime))
        }

        results.sort { $0.mtime > $1.mtime }
        if results.count > maxSessionsPerScan {
            results = Array(results.prefix(maxSessionsPerScan))
        }

        let paths = results.map(\.url)
        cachedPaths[provider] = paths
        cachedPathsAt = now
        cachedPathsMaxAgeMinutes = maxAgeMinutes
        return paths
    }

    static func sessionID(from url: URL, provider: AgentSessionLogProvider) -> String {
        switch provider {
        case .codex:
            return codexSessionID(from: url)
        case .claude:
            return url.deletingPathExtension().lastPathComponent
        }
    }

    static func hasSessionBacking(
        provider: AgentSessionLogProvider,
        conversationID: String,
        maxAgeMinutes: Int,
        now: Date = Date()
    ) -> Bool {
        listRecentSessionPaths(provider: provider, maxAgeMinutes: maxAgeMinutes, now: now)
            .contains { sessionID(from: $0, provider: provider) == conversationID }
    }

    static func displayChatName(from path: URL, provider: AgentSessionLogProvider) -> String? {
        guard let text = readLeadingLines(at: path) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)

        // Claude Code writes ai-title records with a clean model-generated title — prefer those.
        // Search both leading and trailing bytes since the record may appear late in long sessions.
        if provider == .claude {
            let searchChunks: [Substring.SubSequence] = {
                var chunks = lines
                if let tail = readTrailingLines(at: path) {
                    chunks += tail.split(separator: "\n", omittingEmptySubsequences: true)
                }
                return chunks
            }()
            var lastAiTitle: String? = nil
            for line in searchChunks {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (json["type"] as? String) == "ai-title",
                      let title = json["aiTitle"] as? String,
                      !title.isEmpty else { continue }
                lastAiTitle = String(title.prefix(72))
            }
            if let title = lastAiTitle { return title }
        }

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = userPromptText(from: json, provider: provider),
                  let title = normalizedChatTitle(fromUserText: raw) else {
                continue
            }
            return title
        }
        return nil
    }

    static func displayChatNamesBySessionID(
        provider: AgentSessionLogProvider,
        maxAgeMinutes: Int,
        now: Date = Date()
    ) -> [String: String] {
        var results: [String: String] = [:]
        for path in listRecentSessionPaths(provider: provider, maxAgeMinutes: maxAgeMinutes, now: now) {
            guard let title = displayChatName(from: path, provider: provider) else { continue }
            results[sessionID(from: path, provider: provider)] = title
        }
        return results
    }

    static func assistantSnippets(from path: URL, provider: AgentSessionLogProvider) -> [String] {
        guard let text = readLeadingLines(at: path) else { return [] }
        var snippets: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = assistantText(from: json, provider: provider),
                  let snippet = normalizedAssistantSnippet(from: raw) else {
                continue
            }
            snippets.append(snippet)
        }
        return snippets
    }

    static func assistantSnippetsBySessionID(
        provider: AgentSessionLogProvider,
        maxAgeMinutes: Int,
        now: Date = Date()
    ) -> [String: [String]] {
        var results: [String: [String]] = [:]
        for path in listRecentSessionPaths(provider: provider, maxAgeMinutes: maxAgeMinutes, now: now) {
            let snippets = assistantSnippets(from: path, provider: provider)
            guard !snippets.isEmpty else { continue }
            results[sessionID(from: path, provider: provider)] = snippets
        }
        return results
    }

    static func isPromptFallback(
        _ candidate: String?,
        sessionID: String,
        logTitles: [String: String]
    ) -> Bool {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty,
              let logTitle = logTitles[sessionID] else {
            return false
        }
        return candidate == logTitle
    }

    static func isAssistantProseFallback(
        _ candidate: String?,
        sessionID: String,
        assistantSnippets: [String: [String]]
    ) -> Bool {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty,
              let snippets = assistantSnippets[sessionID] else {
            return false
        }
        for snippet in snippets {
            if candidate == snippet { return true }
            if snippet.hasPrefix(candidate) || candidate.hasPrefix(snippet) { return true }
        }
        return false
    }

    static func displayProjectName(from path: URL, provider: AgentSessionLogProvider) -> String? {
        guard let text = readLeadingLines(at: path) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cwd = projectWorkingDirectory(from: json, provider: provider) else {
                continue
            }
            let basename = URL(fileURLWithPath: cwd).lastPathComponent
            return basename.isEmpty ? nil : basename
        }
        return nil
    }

    static func projectNamesBySessionID(
        provider: AgentSessionLogProvider,
        maxAgeMinutes: Int,
        now: Date = Date()
    ) -> [String: String] {
        var results: [String: String] = [:]
        for path in listRecentSessionPaths(provider: provider, maxAgeMinutes: maxAgeMinutes, now: now) {
            guard let projectName = displayProjectName(from: path, provider: provider) else { continue }
            results[sessionID(from: path, provider: provider)] = projectName
        }
        return results
    }

    // MARK: - Private

    private static func rootDirectory(for provider: AgentSessionLogProvider) -> URL {
        switch provider {
        case .codex: return codexSessionsDirectory
        case .claude: return claudeProjectsDirectory
        }
    }

    private static func isSessionLogFile(_ url: URL, provider: AgentSessionLogProvider) -> Bool {
        switch provider {
        case .codex:
            return url.lastPathComponent.hasPrefix("rollout-")
        case .claude:
            guard !url.path.contains("/subagents/") else { return false }
            let name = url.deletingPathExtension().lastPathComponent
            return !name.hasPrefix("agent-")
        }
    }

    private static func codexSessionID(from url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        guard base.hasPrefix("rollout-") else { return base }
        let trimmed = String(base.dropFirst("rollout-".count))
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 5 else { return trimmed }
        return parts.suffix(5).joined(separator: "-")
    }

    /// Passive approval detection for Claude Code: the session is likely waiting on a
    /// permission prompt when the newest transcript record is an assistant `tool_use`
    /// with no tool_result recorded after it. (Indistinguishable from a long-running
    /// tool by transcript alone, so callers should also require a short write-idle gap.)
    static func claudeAppearsAwaitingApproval(at path: URL) -> Bool {
        let text = readTrailingLines(at: path) ?? readLeadingLines(at: path) ?? ""
        var lastKind: String? = nil // "toolUse" | "toolResult" | "other"
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            switch type {
            case "assistant":
                guard let message = json["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                let hasToolUse = content.contains { ($0["type"] as? String) == "tool_use" }
                lastKind = hasToolUse ? "toolUse" : "other"
            case "user":
                let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                let hasToolResult = content.contains { ($0["type"] as? String) == "tool_result" }
                lastKind = hasToolResult ? "toolResult" : "other"
            default:
                continue // ai-title, summaries, etc. don't change the pending-tool signal
            }
        }
        return lastKind == "toolUse"
    }

    private static func readLeadingLines(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let data: Data
        if #available(macOS 10.15.4, *) {
            data = (try? handle.read(upToCount: leadingByteLimit)) ?? Data()
        } else {
            data = handle.readData(ofLength: leadingByteLimit)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func readTrailingLines(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return nil }
        let readSize = UInt64(trailingByteLimit)
        guard fileSize > readSize else { return nil }
        let offset = fileSize - readSize
        if #available(macOS 10.15.4, *) {
            try? handle.seek(toOffset: offset)
            let data = (try? handle.readToEnd()) ?? Data()
            return String(data: data, encoding: .utf8)
        } else {
            handle.seek(toFileOffset: offset)
            let data = handle.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        }
    }

    private static func userPromptText(from json: [String: Any], provider: AgentSessionLogProvider) -> String? {
        switch provider {
        case .claude:
            return claudeUserPromptText(from: json)
        case .codex:
            return codexUserPromptText(from: json)
        }
    }

    private static func assistantText(from json: [String: Any], provider: AgentSessionLogProvider) -> String? {
        switch provider {
        case .claude:
            return claudeAssistantText(from: json)
        case .codex:
            return codexAssistantText(from: json)
        }
    }

    private static func projectWorkingDirectory(from json: [String: Any], provider: AgentSessionLogProvider) -> String? {
        switch provider {
        case .claude:
            if let cwd = json["cwd"] as? String, !cwd.isEmpty { return cwd }
            return nil
        case .codex:
            if let payload = json["payload"] as? [String: Any],
               let cwd = payload["cwd"] as? String,
               !cwd.isEmpty {
                return cwd
            }
            if let payload = json["session_meta"] as? [String: Any],
               let nested = payload["payload"] as? [String: Any],
               let cwd = nested["cwd"] as? String,
               !cwd.isEmpty {
                return cwd
            }
            return nil
        }
    }

    private static func claudeUserPromptText(from json: [String: Any]) -> String? {
        guard (json["type"] as? String) == "user" else { return nil }
        if let message = json["message"] as? [String: Any] {
            if let content = message["content"] as? String, !content.isEmpty {
                return content
            }
            if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks where (block["type"] as? String) == "text" {
                    if let text = block["text"] as? String, !text.isEmpty {
                        return text
                    }
                }
            }
        }
        if let prompt = json["prompt"] as? String, !prompt.isEmpty {
            return prompt
        }
        return nil
    }

    private static func claudeAssistantText(from json: [String: Any]) -> String? {
        guard (json["type"] as? String) == "assistant" else { return nil }
        guard let message = json["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else {
            return nil
        }
        for block in blocks where (block["type"] as? String) == "text" {
            if let text = block["text"] as? String, !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func codexUserPromptText(from json: [String: Any]) -> String? {
        let type = (json["type"] as? String) ?? ""
        if type == "user_message" {
            if let payload = json["payload"] as? [String: Any],
               let message = payload["message"] as? String,
               !message.isEmpty {
                return message
            }
        }
        if type == "event_msg",
           let payload = json["payload"] as? [String: Any],
           let message = payload["message"] as? String,
           !message.isEmpty,
           payload["type"] as? String == "user_message" {
            return message
        }
        if (json["role"] as? String) == "user",
           let message = json["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            for block in content where (block["type"] as? String) == "text" {
                if let text = block["text"] as? String, !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private static func codexAssistantText(from json: [String: Any]) -> String? {
        let type = (json["type"] as? String) ?? ""
        if type == "agent_message" || type == "assistant_message" {
            if let payload = json["payload"] as? [String: Any],
               let message = payload["message"] as? String,
               !message.isEmpty {
                return message
            }
        }
        if (json["role"] as? String) == "assistant",
           let message = json["message"] as? [String: Any],
           let blocks = message["content"] as? [[String: Any]] {
            for block in blocks where (block["type"] as? String) == "text" {
                if let text = block["text"] as? String, !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private static func normalizedChatTitle(fromUserText raw: String) -> String? {
        let tagged = extractTaggedContent(named: "user_query", in: raw)
            ?? extractTaggedContent(named: "user_query", in: raw.replacingOccurrences(of: "&lt;", with: "<"))
        let candidate = (tagged ?? raw)
            .replacingOccurrences(of: "<timestamp>.*?</timestamp>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        let firstLine = candidate
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? candidate
        let collapsed = firstLine.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard collapsed.count >= 4 else { return nil }
        return String(collapsed.prefix(72))
    }

    private static func normalizedAssistantSnippet(from raw: String) -> String? {
        let candidate = raw
            .replacingOccurrences(of: "\\[REDACTED\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        let firstLine = candidate
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? candidate
        let collapsed = firstLine.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard collapsed.count >= 4 else { return nil }
        return String(collapsed.prefix(72))
    }

    private static func extractTaggedContent(named tag: String, in text: String) -> String? {
        let pattern = "<\(tag)>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
