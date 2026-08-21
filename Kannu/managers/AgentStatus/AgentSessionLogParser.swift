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
    /// Escalating tail-read windows for `claudeTailState(at:)` — single records can exceed
    /// the first window, and a truncated tail must widen rather than report `.unknown`.
    private static let tailWindowLimits = [16_000, 262_144, 1_048_576]
    private static var tailResultCache: [String: (mtime: Date, size: Int, result: ClaudeTailResult)] = [:]

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

    /// What the newest conversational record in a Claude transcript says the session is doing.
    enum ClaudeTailState {
        case toolInFlight   // assistant proposed a tool and no result has landed yet
        case turnFinished   // assistant ended its turn — nothing is running
        case working        // a tool result or a fresh user prompt; the agent owes a response
        case unknown
    }

    /// Tail verdict plus the timestamp of the record that decided it, so callers can age the
    /// state from when it actually happened rather than from file mtime (which bookkeeping
    /// writes keep bumping long after the run ended).
    struct ClaudeTailResult: Equatable {
        let state: ClaudeTailState
        let recordTimestamp: Date?

        static let unknown = ClaudeTailResult(state: .unknown, recordTimestamp: nil)
    }

    /// An Esc interrupt is recorded as a `user` record with this text; the Stop hook does not
    /// fire for it, so the transcript is the only place the interrupt is visible.
    /// Variants: "[Request interrupted by user]", "[Request interrupted by user for tool use]".
    private static let claudeInterruptMarkerPrefix = "[Request interrupted by user"

    private static let recordTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let recordTimestampFallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func recordTimestamp(from json: [String: Any]) -> Date? {
        guard let raw = json["timestamp"] as? String else { return nil }
        return recordTimestampFormatter.date(from: raw)
            ?? recordTimestampFallbackFormatter.date(from: raw)
    }

    private static func hasInterruptMarker(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix(claudeInterruptMarkerPrefix)
    }

    /// The interrupt text can appear as a plain string content, a `text` block, or inside a
    /// `tool_result` block (interrupt during a tool call) — check all three shapes.
    static func isClaudeInterruptRecord(_ message: [String: Any]?) -> Bool {
        guard let message else { return false }
        if let text = message["content"] as? String {
            return hasInterruptMarker(text)
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return false }
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, hasInterruptMarker(text) { return true }
            case "tool_result":
                if let text = block["content"] as? String, hasInterruptMarker(text) { return true }
                if let nested = block["content"] as? [[String: Any]] {
                    for inner in nested where (inner["type"] as? String) == "text" {
                        if let text = inner["text"] as? String, hasInterruptMarker(text) { return true }
                    }
                }
            default:
                continue
            }
        }
        return false
    }

    /// Reads the tail of a Claude JSONL to tell a running tool apart from an idle prompt.
    ///
    /// File mtime alone cannot do this: a long tool writes its `tool_use` record at the start
    /// and then nothing until it completes, so minutes of real work look identical to an idle
    /// session. `stop_reason` on the assistant record is the authoritative end-of-turn marker.
    ///
    /// Deliberately never reports "awaiting approval" — a pending `tool_use` looks the same
    /// whether the tool is running or a permission card is open, and guessing there is what
    /// produced permanent false yellow. Yellow comes from hooks only.
    ///
    /// Records can exceed the first read window (real transcript lines reach hundreds of KB),
    /// which used to truncate the tail into `.unknown`; the window now escalates until it
    /// produces a verdict or covers the whole file. Results are cached against (mtime, size)
    /// so the 1 Hz rescan costs a stat, not a read, for quiet sessions.
    static func claudeTailState(at url: URL) -> ClaudeTailResult {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = values?.contentModificationDate
        let fileSize = values?.fileSize
        if let mtime, let fileSize,
           let cached = tailResultCache[url.path],
           cached.mtime == mtime, cached.size == fileSize {
            return cached.result
        }

        var result = ClaudeTailResult.unknown
        for limit in tailWindowLimits {
            // `continue`, not `break`: each window seeks to a different offset, so a window
            // that fails to produce text says nothing about the wider ones. Breaking here
            // abandoned escalation on the first stumble — and the cached `.unknown` that
            // resulted now demotes a live session via the reconciler's demote arm.
            guard let text = readTrailingLines(at: url, limit: limit) else { continue }
            result = claudeTailState(fromTailText: text)
            if result.state != .unknown { break }
            if let fileSize, limit >= fileSize { break }
        }

        if let mtime, let fileSize {
            if tailResultCache.count > 2 * maxSessionsPerScan {
                tailResultCache.removeAll()
            }
            tailResultCache[url.path] = (mtime, fileSize, result)
        }
        return result
    }

    /// Pure core of `claudeTailState(at:)` — classifies the newest conversational record.
    static func claudeTailState(fromTailText text: String) -> ClaudeTailResult {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            switch type {
            case "assistant":
                let message = json["message"] as? [String: Any]
                let content = message?["content"] as? [[String: Any]] ?? []
                let timestamp = recordTimestamp(from: json)
                if content.contains(where: { ($0["type"] as? String) == "tool_use" }) {
                    return ClaudeTailResult(state: .toolInFlight, recordTimestamp: timestamp)
                }
                let stopReason = message?["stop_reason"] as? String
                // nil / "tool_use" / "pause_turn" mean the turn is still open. Any other
                // value — end_turn, stop_sequence, max_tokens, refusal, future additions —
                // is terminal: nothing is running.
                if stopReason == nil || stopReason == "tool_use" || stopReason == "pause_turn" {
                    return ClaudeTailResult(state: .working, recordTimestamp: timestamp)
                }
                return ClaudeTailResult(state: .turnFinished, recordTimestamp: timestamp)
            case "user":
                let timestamp = recordTimestamp(from: json)
                if isClaudeInterruptRecord(json["message"] as? [String: Any]) {
                    // Esc leaves the session idle at its prompt; without this the trailing
                    // user record reads as "owes a response" and the light stays green forever.
                    return ClaudeTailResult(state: .turnFinished, recordTimestamp: timestamp)
                }
                return ClaudeTailResult(state: .working, recordTimestamp: timestamp)
            default:
                // attachment, queue-operation, last-prompt, ai-title, custom-title, mode,
                // system, pr-link — bookkeeping that says nothing about run state.
                continue
            }
        }
        return .unknown
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
        // Lossy fallback: the byte slice can cut a multibyte character in half, and a strict
        // decode then nils the ENTIRE read — losing every name and snippet in the file over
        // one boundary-straddling emoji. Dropping the partial codepoint loses one character.
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private static func readTrailingLines(at url: URL, limit: Int = trailingByteLimit) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return nil }
        let readSize = UInt64(limit)
        // Short file: read all of it. Returning nil here sent callers to their
        // `?? readLeadingLines` fallback, which reads the *start* of the transcript —
        // the opposite of what a "trailing lines" reader promises.
        let offset = fileSize > readSize ? fileSize - readSize : 0
        let data: Data
        if #available(macOS 10.15.4, *) {
            try? handle.seek(toOffset: offset)
            data = (try? handle.readToEnd()) ?? Data()
        } else {
            handle.seek(toFileOffset: offset)
            data = handle.readDataToEndOfFile()
        }
        // Lossy fallback for the same reason as readLeadingLines: a boundary-straddling
        // multibyte character must cost one codepoint, not the whole tail — this read now
        // drives run-state detection, where a nil turns a live session into a dim card.
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
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
