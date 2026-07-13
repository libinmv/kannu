import Foundation

struct TranscriptEvent {
    let kind: String
    let toolUses: [String]
    let stopReason: String?
    let tsMs: Int64?
}

struct TranscriptAnalysis: Equatable {
    let mtimeMs: Int64
    let isDone: Bool
    let hasActiveToolUse: Bool
    let hasPendingToolApproval: Bool
    let isUserPromptAwaitingResponse: Bool
    let isTurnEndedAtTail: Bool
}

enum CursorTranscriptParser {
    /// Keep tails small — only the last few events matter for traffic-light state.
    private static let tailByteLimit = 48_000
    /// Cap how many recent transcripts we parse per cycle.
    private static let maxTranscriptsPerScan = 24
    private static let pathListCacheTTL: TimeInterval = 2.0

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoBasic = ISO8601DateFormatter()

    private static var cachedPaths: [URL] = []
    private static var cachedPathsAt: Date?
    private static var cachedPathsMaxAgeMinutes: Int = 0

    static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/projects", isDirectory: true)
    }

    static func listRecentTranscriptPaths(maxAgeMinutes: Int, now: Date = Date()) -> [URL] {
        if let cachedPathsAt,
           cachedPathsMaxAgeMinutes == maxAgeMinutes,
           now.timeIntervalSince(cachedPathsAt) < pathListCacheTTL {
            return cachedPaths
        }

        let root = projectsDirectory
        guard FileManager.default.fileExists(atPath: root.path) else {
            cachedPaths = []
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
            cachedPaths = []
            cachedPathsAt = now
            cachedPathsMaxAgeMinutes = maxAgeMinutes
            return []
        }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let name = url.lastPathComponent
            let isSessionTranscript = url.path.contains("/agent-transcripts/")
            let isSubagent = name.hasPrefix("agent-") && name.hasSuffix(".jsonl")
            guard isSessionTranscript || isSubagent else { continue }

            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = values.contentModificationDate,
                  mtime >= cutoff else { continue }

            results.append((url, mtime))
        }

        results.sort { $0.mtime > $1.mtime }
        if results.count > maxTranscriptsPerScan {
            results = Array(results.prefix(maxTranscriptsPerScan))
        }

        let paths = results.map(\.url)
        cachedPaths = paths
        cachedPathsAt = now
        cachedPathsMaxAgeMinutes = maxAgeMinutes
        return paths
    }

    static func invalidatePathCache() {
        cachedPaths = []
        cachedPathsAt = nil
    }

    static func sessionID(from url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        if base.hasPrefix("agent-") {
            return String(base.dropFirst("agent-".count))
        }
        return base
    }

    /// Cursor Task/subagent transcripts live under `.../agent-transcripts/<parent>/subagents/<id>.jsonl`.
    static func isSubagentTranscript(_ url: URL) -> Bool {
        url.path.contains("/subagents/")
    }

    static func parentSessionID(fromSubagentPath url: URL) -> String? {
        guard isSubagentTranscript(url) else { return nil }
        let path = url.path
        guard let subagentsRange = path.range(of: "/subagents/") else { return nil }
        let beforeSubagents = path[..<subagentsRange.lowerBound]
        guard let transcriptsRange = beforeSubagents.range(of: "/agent-transcripts/") else { return nil }
        let parent = String(beforeSubagents[transcriptsRange.upperBound...])
        return parent.isEmpty ? nil : parent
    }

    /// Maps subagent conversation IDs to the parent chat that launched them.
    static func subagentToParentSessionMap(maxAgeMinutes: Int, now: Date = Date()) -> [String: String] {
        var map: [String: String] = [:]
        for path in listRecentTranscriptPaths(maxAgeMinutes: maxAgeMinutes, now: now) {
            guard let parentID = parentSessionID(fromSubagentPath: path) else { continue }
            map[sessionID(from: path)] = parentID
        }
        return map
    }

    static func projectSlug(from url: URL) -> String? {
        let marker = "/.cursor/projects/"
        let path = url.path
        guard let start = path.range(of: marker)?.upperBound else { return nil }
        let tail = path[start...]
        guard let end = tail.range(of: "/agent-transcripts/")?.lowerBound else { return nil }
        let slug = String(tail[..<end])
        return slug.isEmpty ? nil : slug
    }

    static func displayProjectName(fromSlug slug: String?) -> String? {
        guard let slug else { return nil }
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("var-") { return nil }
        if trimmed.allSatisfy(\.isNumber) { return nil }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let homePrefix = home.replacingOccurrences(of: "/", with: "-")
        if trimmed.hasPrefix(homePrefix + "-") {
            let suffix = String(trimmed.dropFirst(homePrefix.count + 1))
            let parts = suffix.split(separator: "-", omittingEmptySubsequences: true)
            if let last = parts.last {
                return String(last)
            }
        }

        return trimmed
    }

    static func analyze(path: URL) -> TranscriptAnalysis {
        let mtimeMs: Int64 = {
            guard let date = (try? path.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
                return 0
            }
            return Int64(date.timeIntervalSince1970 * 1000)
        }()

        let events = readTailLines(at: path).compactMap(parseEvent)
        let isDone = detectDone(events: events)
        let turnCompleted = isTurnEndedAtTail(events: events)
        let isUserPromptAwaitingResponse = isUserPromptAwaitingResponse(events: events)
        let hasPendingToolApproval = hasPendingApprovalGatedTool(events: events) && !isDone && !turnCompleted
        let pendingTool = lastToolUseName(events: events)
        let hasActiveToolUse = pendingTool != nil && !hasPendingToolApproval && !isDone && !isUserPromptAwaitingResponse
        return TranscriptAnalysis(
            mtimeMs: mtimeMs,
            isDone: isDone,
            hasActiveToolUse: hasActiveToolUse,
            hasPendingToolApproval: hasPendingToolApproval,
            isUserPromptAwaitingResponse: isUserPromptAwaitingResponse,
            isTurnEndedAtTail: turnCompleted
        )
    }

    /// One filesystem walk + one tail parse per transcript for all enrichment flags.
    static func analyzeRecentSessions(maxAgeMinutes: Int, now: Date = Date()) -> [String: TranscriptAnalysis] {
        var results: [String: TranscriptAnalysis] = [:]
        for path in listRecentTranscriptPaths(maxAgeMinutes: maxAgeMinutes, now: now) {
            results[sessionID(from: path)] = analyze(path: path)
        }
        return results
    }

    /// Last-resort title derived from the first user prompt in an agent transcript.
    /// Prefer composer headers and Glass agent plan titles before using this.
    static func displayChatName(from path: URL) -> String? {
        guard let text = readLeadingLines(at: path, byteLimit: 32_000) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["role"] as? String) == "user",
                  let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else {
                continue
            }
            for block in content where (block["type"] as? String) == "text" {
                guard let raw = block["text"] as? String else { continue }
                if let title = normalizedChatTitle(fromUserText: raw) {
                    return title
                }
            }
        }
        return nil
    }

    static func displayChatNamesBySessionID(maxAgeMinutes: Int, now: Date = Date()) -> [String: String] {
        var results: [String: String] = [:]
        for path in listRecentTranscriptPaths(maxAgeMinutes: maxAgeMinutes, now: now) {
            guard let title = displayChatName(from: path) else { continue }
            results[sessionID(from: path)] = title
        }
        return results
    }

    static func isTranscriptPromptFallback(
        _ candidate: String?,
        sessionID: String,
        transcriptTitles: [String: String]
    ) -> Bool {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty,
              let transcriptTitle = transcriptTitles[sessionID] else {
            return false
        }
        return candidate == transcriptTitle
    }

    /// Assistant narration lines from an agent transcript — used to reject
    /// interim hook/Glass titles that mirror in-chat agent prose.
    static func assistantSnippets(from path: URL) -> [String] {
        guard let text = readLeadingLines(at: path, byteLimit: 32_000) else { return [] }
        var snippets: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["role"] as? String) == "assistant",
                  let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else {
                continue
            }
            for block in content where (block["type"] as? String) == "text" {
                guard let raw = block["text"] as? String else { continue }
                if let snippet = normalizedAssistantSnippet(from: raw) {
                    snippets.append(snippet)
                }
            }
        }
        return snippets
    }

    static func firstAssistantSnippet(from path: URL) -> String? {
        assistantSnippets(from: path).first
    }

    static func assistantSnippetsBySessionID(maxAgeMinutes: Int, now: Date = Date()) -> [String: [String]] {
        var results: [String: [String]] = [:]
        for path in listRecentTranscriptPaths(maxAgeMinutes: maxAgeMinutes, now: now) {
            let snippets = assistantSnippets(from: path)
            guard !snippets.isEmpty else { continue }
            results[sessionID(from: path)] = snippets
        }
        return results
    }

    static func isAssistantProseFallback(
        _ candidate: String?,
        sessionID: String,
        transcriptAssistantSnippets: [String: [String]]
    ) -> Bool {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty,
              let snippets = transcriptAssistantSnippets[sessionID] else {
            return false
        }
        for snippet in snippets {
            if candidate == snippet { return true }
            if snippet.hasPrefix(candidate) || candidate.hasPrefix(snippet) { return true }
        }
        return false
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

    private static func readLeadingLines(at url: URL, byteLimit: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let data: Data
        if #available(macOS 10.15.4, *) {
            data = (try? handle.read(upToCount: byteLimit)) ?? Data()
        } else {
            data = handle.readData(ofLength: byteLimit)
        }
        return String(data: data, encoding: .utf8)
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

    private static func extractTaggedContent(named tag: String, in text: String) -> String? {
        let pattern = "<\(tag)>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readTailLines(at url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let size: UInt64
        if #available(macOS 10.15.4, *) {
            size = (try? handle.seekToEnd()) ?? 0
        } else {
            size = handle.seekToEndOfFile()
        }

        let readLength = min(UInt64(tailByteLimit), size)
        guard readLength > 0 else { return [] }

        let offset = size - readLength
        if #available(macOS 10.15.4, *) {
            try? handle.seek(toOffset: offset)
        } else {
            handle.seek(toFileOffset: offset)
        }

        let data: Data
        if #available(macOS 10.15.4, *) {
            data = (try? handle.read(upToCount: Int(readLength))) ?? Data()
        } else {
            data = handle.readData(ofLength: Int(readLength))
        }

        var text = String(data: data, encoding: .utf8) ?? ""
        if size > UInt64(tailByteLimit), let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }

        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private static func parseEvent(_ line: String) -> TranscriptEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let role = (json["role"] as? String) ?? (json["type"] as? String) ?? "unknown"
        let message = json["message"] as? [String: Any] ?? [:]
        var toolUses: [String] = []
        let stopReason: String? = message["stop_reason"] as? String

        if let content = message["content"] as? [[String: Any]] {
            for block in content {
                guard let type = block["type"] as? String else { continue }
                if type == "tool_use", let name = block["name"] as? String {
                    toolUses.append(name)
                }
            }
        }

        var tsMs: Int64?
        if let timestamp = json["timestamp"] as? String {
            if let date = isoFractional.date(from: timestamp) ?? isoBasic.date(from: timestamp) {
                tsMs = Int64(date.timeIntervalSince1970 * 1000)
            }
        }

        return TranscriptEvent(kind: role, toolUses: toolUses, stopReason: stopReason, tsMs: tsMs)
    }

    private static func detectDone(events: [TranscriptEvent]) -> Bool {
        guard let last = events.last(where: { $0.kind == "assistant" || $0.kind == "user" }),
              last.kind == "assistant" else {
            return false
        }

        let hasTool = !last.toolUses.isEmpty
        if hasTool { return false }

        guard let stopReason = last.stopReason else { return true }
        return ["end_turn", "stop", "stop_sequence", "max_tokens"].contains(stopReason)
    }

    private static func lastToolUseName(events: [TranscriptEvent]) -> String? {
        for event in events.reversed() where event.kind == "assistant" && !event.toolUses.isEmpty {
            return event.toolUses.last
        }
        return nil
    }

    /// True while the latest tool-bearing assistant message is still an approval-gated proposal.
    ///
    /// Used only for sessions without hook coverage: with hooks installed, `preToolUse`
    /// fires when the approval card is shown and drives yellow directly (measured 2026-07).
    /// Transcript flushing lags the live card, so this is a best-effort fallback.
    private static func hasPendingApprovalGatedTool(events: [TranscriptEvent]) -> Bool {
        guard !events.isEmpty else { return false }

        var index = events.count - 1
        while index >= 0 {
            let kind = events[index].kind
            if kind == "turn_ended" || kind == "user" {
                index -= 1
                continue
            }
            if kind == "assistant" {
                if events[index].toolUses.isEmpty {
                    index -= 1
                    continue
                }
                return events[index].toolUses.contains { AgentApprovalGatedTools.requiresUserApproval($0) }
            }
            break
        }
        return false
    }

    /// Analyze a single known session transcript without walking the whole projects tree.
    static func analyzeSession(conversationID: String, maxAgeMinutes: Int, now: Date = Date()) -> TranscriptAnalysis? {
        let paths = listRecentTranscriptPaths(maxAgeMinutes: maxAgeMinutes, now: now)
        guard let path = paths.first(where: { sessionID(from: $0) == conversationID }) else {
            return nil
        }
        return analyze(path: path)
    }

    /// True when the agent finished its turn and is idle (`turn_ended` is the latest event).
    private static func isTurnEndedAtTail(events: [TranscriptEvent]) -> Bool {
        events.last?.kind == "turn_ended"
    }

    /// True when the user sent a new prompt after `turn_ended` and the agent has not replied yet.
    private static func isUserPromptAwaitingResponse(events: [TranscriptEvent]) -> Bool {
        guard events.last?.kind == "user" else { return false }
        for event in events.dropLast().reversed() {
            if event.kind == "turn_ended" { return true }
            if event.kind == "assistant" { return false }
        }
        return false
    }
}
