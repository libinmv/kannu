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

/// One request as the hook recorded it (v39): from the user's prompt to the Stop that answered it.
/// Work after that Stop without a new prompt — a background task finishing, a stop hook — reopens
/// the same turn, so its time counts from the user's message. On disk, so it survives a relaunch
/// (the in-memory `executionStartedAt` restarts on one, and on any gap in the state).
///
/// A locator-like field of `AgentSessionStatus`, written only by the hook: `carryingExtras` keeps
/// `self ?? source`, and the subagent fold sets it explicitly (docs/REGRESSIONS.md entry 7).
struct HookTurn: Equatable {
    let startedAt: Date
    var endedAt: Date?
    /// Completed tool calls in this turn; the parent's card also adds its subagents' calls.
    var toolCalls: Int
    /// Claude's main transcript, when the hook recorded a followable one.
    var transcriptPath: String?
    /// The transcript's size when the turn began; nil when unknown (tokens are then hidden).
    var transcriptOffset: Int64?

    static let maxToolCalls = 99_999
    /// The hook refuses a clock more than this far ahead; so does Kannu.
    static let futureSlackMs: Int64 = 60_000
    static let maxPathLength = 1024
    static let maxOffset: Int64 = 9_007_199_254_740_992

    init(startedAt: Date, endedAt: Date? = nil, toolCalls: Int = 0, transcriptPath: String? = nil, transcriptOffset: Int64? = nil) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.toolCalls = toolCalls
        self.transcriptPath = transcriptPath
        self.transcriptOffset = transcriptOffset
    }

    /// The turn a hook status file carries (untrusted input, re-checked as the hook does); nil
    /// without a plausible start.
    init?(hookFile json: [String: Any], home: String, now: Date) {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        guard let start = Self.integer(json["turn_started_ms"]), start >= 1_000_000_000_000,
              start <= nowMs + Self.futureSlackMs else { return nil }
        startedAt = Date(timeIntervalSince1970: TimeInterval(start) / 1000)
        if let end = Self.integer(json["turn_ended_ms"]), end >= start, end <= nowMs + Self.futureSlackMs {
            endedAt = Date(timeIntervalSince1970: TimeInterval(end) / 1000)
        } else {
            endedAt = nil
        }
        toolCalls = Int(min(max(Self.integer(json["turn_tool_calls"]) ?? 0, 0), Int64(Self.maxToolCalls)))
        if let path = json["transcript_path"] as? String, Self.isFollowableTranscript(path, home: home) {
            transcriptPath = path
            if let offset = Self.integer(json["turn_transcript_offset"]), offset >= 0, offset <= Self.maxOffset {
                transcriptOffset = offset
            } else {
                transcriptOffset = nil
            }
        } else {
            transcriptPath = nil
            transcriptOffset = nil
        }
    }

    /// The only transcripts Kannu reads for tokens: Claude's main transcript under
    /// `~/.claude/projects/`, spelled canonically (no `.`, `..` or empty components, so a string
    /// check cannot be walked out of the folder), printable ASCII, `.jsonl`, never a subagent's.
    /// The hook applies the same rule; the file is untrusted, so Kannu checks again, and the reader
    /// also resolves the real path before opening it.
    static func isFollowableTranscript(_ path: String, home: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= maxPathLength,
              path.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }),
              !home.isEmpty, path.hasPrefix(home + "/.claude/projects/"),
              path.hasSuffix(".jsonl"), !path.contains("/subagents/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first == "" else { return false }
        return components.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// The parent's turn with a subagent's calls added — only when the subagent belongs to this
    /// turn (it started at or after it); a leftover from an earlier request adds nothing. A parent
    /// with no turn stays without one: never adopt a subagent's.
    static func folding(_ sub: HookTurn?, into parent: HookTurn?) -> HookTurn? {
        guard var parent else { return nil }
        guard let sub, sub.startedAt >= parent.startedAt else { return parent }
        parent.toolCalls = min(parent.toolCalls + sub.toolCalls, maxToolCalls)
        return parent
    }

    /// A JSON integer (NSNumber, not a Bool, no fraction).
    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 9.2e18 else { return nil }
        return number.int64Value
    }
}

// MARK: - What the card shows

/// The run time a card shows for its request.
enum AgentTurnDisplay: Equatable {
    /// Still running: the view ticks from this date.
    case live(since: Date)
    /// Ended: "Ran …" for this long.
    case ended(TimeInterval)

    /// Writes after the end that still report work mean the request went on without a new prompt
    /// and without a wake event (a stop hook's text-only continuation); a late completion lands
    /// within this.
    static let supersededAfter: TimeInterval = 2

    /// - An ended turn shows how long it ran — also through the idle notice's yellow afterwards.
    /// - An open turn ticks from the user's prompt while the card is running or waiting; a card that
    ///   stopped without a Stop (Esc, a killed process) shows no time rather than a wrong one.
    /// - Without a turn (hooks before v39, passive sources), the in-memory run start is the best
    ///   there is, shown only while running.
    static func duration(turn: HookTurn?, executionStartedAt: Date?, state: AgentTrafficLightState,
                         hookReportsWork: Bool, updatedAt: Date) -> AgentTurnDisplay? {
        guard let turn else {
            guard state.isActiveRun, let executionStartedAt else { return nil }
            return .live(since: executionStartedAt)
        }
        if let end = turn.endedAt, !(hookReportsWork && updatedAt.timeIntervalSince(end) > supersededAfter) {
            return .ended(max(0, end.timeIntervalSince(turn.startedAt)))
        }
        return state.isActiveRun ? .live(since: turn.startedAt) : nil
    }
}

/// Text for the run time, tool calls and tokens beside a Recent chats row.
enum AgentTurnFormat {
    /// "42s", "3m 24s", "1h 53m 54s".
    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let hours = total / 3600, minutes = total % 3600 / 60, seconds = total % 60
        if hours > 0 { return String(localized: "\(hours)h \(minutes)m \(seconds)s") }
        if minutes > 0 { return String(localized: "\(minutes)m \(seconds)s") }
        return String(localized: "\(seconds)s")
    }

    /// The same without seconds once there are hours or minutes, for a narrow column: "1h 53m".
    static func shortDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let hours = total / 3600, minutes = total % 3600 / 60
        if hours > 0 { return String(localized: "\(hours)h \(minutes)m") }
        if minutes > 0 { return String(localized: "\(minutes)m") }
        return duration(interval)
    }

    /// "Ran 2h 3m 12s".
    static func ran(_ duration: String) -> String { String(localized: "Ran \(duration)") }

    /// "1 tool", "212 tools"; nil for none.
    static func tools(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? String(localized: "1 tool") : String(localized: "\(count) tools")
    }

    /// "1.4M in · 45k out".
    static func tokens(_ tokens: TurnTokens) -> String {
        String(localized: "\(compact(tokens.input)) in · \(compact(tokens.output)) out")
    }

    /// Line 2 of the column, widest first; nil entries are left out.
    static func metricsLines(toolCalls: Int, tokens: TurnTokens?) -> (full: String?, tokensOnly: String?, toolsOnly: String?) {
        let toolsText = tools(toolCalls)
        let tokensText = tokens.map(Self.tokens)
        let full = [toolsText, tokensText].compactMap { $0 }.joined(separator: " · ")
        return (full.isEmpty ? nil : full,
                toolsText != nil ? tokensText : nil,
                tokensText != nil ? toolsText : nil)
    }

    /// 812, 4.5k, 10k, 45k, 1M, 1.4M, 65M, 1.2B — rounding rolls over into the next unit.
    static func compact(_ value: Int) -> String {
        guard value >= 1000 else { return String(max(0, value)) }
        let units: [(divisor: Double, suffix: String)] = [(1e3, "k"), (1e6, "M"), (1e9, "B")]
        var index = 0
        while true {
            let scaled = Double(value) / units[index].divisor
            let rounded = scaled < 10 ? (scaled * 10).rounded() / 10 : scaled.rounded()
            if rounded >= 1000, index < units.count - 1 {
                index += 1
                continue
            }
            let digits = rounded < 10 && rounded != rounded.rounded(.down)
                ? String(format: "%.1f", rounded) : String(Int(rounded))
            return digits + units[index].suffix
        }
    }

    /// Spoken form: "1.4 million", "45 thousand", "812".
    static func spokenCount(_ value: Int) -> String {
        let text = compact(value)
        guard let suffix = text.last, "kMB".contains(suffix) else { return text }
        let number = String(text.dropLast())
        switch suffix {
        case "k": return String(localized: "\(number) thousand")
        case "M": return String(localized: "\(number) million")
        default: return String(localized: "\(number) billion")
        }
    }

    /// One VoiceOver phrase for the whole column.
    static func accessibilityText(_ display: AgentTurnDisplay, now: Date, toolCalls: Int, tokens: TurnTokens?) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        var parts: [String] = []
        switch display {
        case let .live(since):
            parts.append(String(localized: "Running for \(formatter.string(from: max(0, now.timeIntervalSince(since))) ?? "")"))
        case let .ended(interval):
            parts.append(String(localized: "Ran for \(formatter.string(from: interval) ?? "")"))
        }
        if toolCalls > 0 {
            parts.append(toolCalls == 1 ? String(localized: "1 tool call") : String(localized: "\(toolCalls) tool calls"))
        }
        if let tokens {
            parts.append(String(localized: "\(spokenCount(tokens.input)) tokens in, \(spokenCount(tokens.output)) out"))
        }
        return parts.joined(separator: ", ")
    }
}
