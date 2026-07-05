import Foundation

struct TranscriptEvent {
    let kind: String
    let toolUses: [String]
    let stopReason: String?
    let tsMs: Int64?
}

enum CursorTranscriptParser {
    private static let tailByteLimit = 200_000

    static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/projects", isDirectory: true)
    }

    static func listRecentTranscriptPaths(maxAgeMinutes: Int, now: Date = Date()) -> [URL] {
        let root = projectsDirectory
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let cutoff = now.addingTimeInterval(-TimeInterval(maxAgeMinutes * 60))
        var results: [URL] = []

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let name = url.lastPathComponent
            let isSessionTranscript = url.path.contains("/agent-transcripts/")
            let isSubagent = name.hasPrefix("agent-") && name.hasSuffix(".jsonl")
            guard isSessionTranscript || isSubagent else { continue }

            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = values.contentModificationDate,
                  mtime >= cutoff else { continue }

            results.append(url)
        }

        return results
    }

    static func sessionID(from url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        if base.hasPrefix("agent-") {
            return String(base.dropFirst("agent-".count))
        }
        return base
    }

    static func analyze(path: URL) -> (events: [TranscriptEvent], mtimeMs: Int64, isDone: Bool, hasActiveToolUse: Bool) {
        let mtimeMs: Int64 = {
            guard let date = (try? path.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
                return 0
            }
            return Int64(date.timeIntervalSince1970 * 1000)
        }()

        let lines = readTailLines(at: path)
        let events = lines.compactMap(parseEvent)
        let isDone = detectDone(events: events)
        let hasActiveToolUse = lastToolUseName(events: events) != nil && !isDone
        return (events, mtimeMs, isDone, hasActiveToolUse)
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
        var stopReason: String? = message["stop_reason"] as? String

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
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp) {
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
}
