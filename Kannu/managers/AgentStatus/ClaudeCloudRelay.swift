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

import CryptoKit
import Foundation
import Security

/// The Claude Code cloud-session relay's protocol, Kannu's end (docs/CLOUD-SESSIONS.md).
///
/// A cloud session runs on Anthropic's VMs, where Kannu's user-level hook never runs and from
/// where nothing reaches this Mac. A small hook committed to the repository
/// (`scripts/kannu-cloud-relay.sh`) posts the session's light to an ntfy relay instead, and Kannu
/// subscribes. Both ends derive the topic and a signing key from one secret the user holds in the
/// cloud environment and in Kannu's Keychain. Everything that arrives is untrusted: a line is
/// checked against the topic, the signature, a closed set of keys and values, sizes and the
/// relay's clock before it becomes a card, and a card can only ever open a claude.ai session page.
///
/// Pure: the listener (`ClaudeCloudRelayManager`) owns the network; this owns the rules.
enum ClaudeCloudRelay {
    static let providerKey = "claudecloud"
    static let defaultServerURL = "https://ntfy.sh"
    /// The prefix of a cloud card's conversation id. A dot never survives the local hook's id
    /// sanitizing, so a cloud card can never merge with a local chat's.
    static let conversationPrefix = "claudecloud."

    static let protocolVersion = 1
    static let payloadKeys: Set<String> = ["v", "kind", "session", "state", "event", "note", "repo", "ts"]
    static let states: Set<String> = ["idle", "thinking", "executing", "awaiting_input", "stopped", "session_end"]
    static let events: Set<String> = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                                      "PostToolUseFailure", "PermissionRequest", "Notification",
                                      "Stop", "StopFailure", "SessionEnd", "Check"]
    static let notes: Set<String> = ["", "permission_prompt", "idle_prompt", "agent_needs_input", "agent_completed"]

    static let maxLineBytes = 16 * 1024
    static let maxPayloadBytes = 1024
    static let maxSessions = 32
    /// How far a message's own time may be from the relay's receive time.
    static let maxClockSkew: TimeInterval = 600
    /// How long a session is remembered without news. The stale cap hides it long before.
    static let memory: TimeInterval = 3600

    // MARK: - Keys

    struct Credentials: Equatable, Sendable {
        let topic: String
        let macKey: Data
    }

    /// The topic and signing key for a relay secret (64 lowercase hex characters), or nil.
    static func credentials(secret: String) -> Credentials? {
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard secret.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
        let topicHash = hex(Data(SHA256.hash(data: Data("kannu-relay-topic|\(secret)".utf8))))
        let macKey = Data(SHA256.hash(data: Data("kannu-relay-mac|\(secret)".utf8)))
        return Credentials(topic: "kannu-" + topicHash.prefix(32), macKey: macKey)
    }

    /// A fresh 256-bit relay secret, or nil if the system cannot supply randomness.
    static func newSecret() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return newSecret(fromRandomBytes: bytes)
    }

    static func newSecret(fromRandomBytes bytes: [UInt8]) -> String? {
        bytes.count == 32 ? hex(Data(bytes)) : nil
    }

    // MARK: - The stream

    /// Splits a byte stream into lines, dropping any line longer than `cap` through its newline,
    /// so a hostile or broken relay cannot grow memory (`AsyncBytes.lines` has no cap).
    struct LineSplitter {
        let cap: Int
        private var buffer = Data()
        private var discarding = false

        init(cap: Int = ClaudeCloudRelay.maxLineBytes) {
            self.cap = cap
        }

        /// The completed line, if this byte ends one.
        mutating func append(_ byte: UInt8) -> Data? {
            if byte == 0x0A {
                defer { buffer.removeAll(keepingCapacity: true); discarding = false }
                return discarding || buffer.isEmpty ? nil : buffer
            }
            guard !discarding else { return nil }
            if buffer.count >= cap {
                buffer.removeAll(keepingCapacity: true)
                discarding = true
            } else {
                buffer.append(byte)
            }
            return nil
        }

        mutating func append<S: Sequence>(_ bytes: S) -> [Data] where S.Element == UInt8 {
            bytes.compactMap { append($0) }
        }
    }

    /// One state report from one cloud session.
    struct Event: Equatable, Sendable {
        /// `session_…`: a `cse_` id is normalized to the form claude.ai's URLs use.
        let sessionID: String
        let state: String
        let event: String
        let note: String
        let repo: String?
        /// The session's own clock: orders reports, strictly increasing per session.
        let ts: Date
        /// The relay's clock: what a card ages by.
        let receivedAt: Date
    }

    enum Rejection: Equatable, Sendable {
        case notJSON, notAMessage, wrongTopic, oversized, notSigned, badSignature, badPayload, clockSkew
    }

    enum Line: Equatable, Sendable {
        case open
        case keepalive
        case event(Event)
        /// `--check` from a session's terminal: proof the whole path works, shown in Settings.
        case check(sessionID: String, at: Date)
        case ignored(Rejection)
    }

    private struct Payload: Decodable {
        let v: Int
        let kind: String
        let session: String
        let state: String
        let event: String
        let note: String
        let repo: String
        let ts: Int64
    }

    /// One line of ntfy's JSON stream, checked end to end. `now` is this Mac's clock: a report is
    /// dated by the relay, never later than now, so a relay clock running ahead cannot keep a card fresh.
    static func parse(line: Data, credentials: Credentials, now: Date = Date()) -> Line {
        guard line.count <= maxLineBytes else { return .ignored(.oversized) }
        guard let envelope = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return .ignored(.notJSON)
        }
        switch envelope["event"] as? String {
        case "open": return .open
        case "keepalive": return .keepalive
        case "message": break
        default: return .ignored(.notAMessage)
        }
        guard (envelope["topic"] as? String) == credentials.topic else { return .ignored(.wrongTopic) }
        guard let time = (envelope["time"] as? NSNumber)?.doubleValue,
              let message = envelope["message"] as? String else { return .ignored(.notAMessage) }

        let parts = message.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "KC1", let mac = data(hex: String(parts[1])), mac.count == 32 else {
            return .ignored(.notSigned)
        }
        let payloadData = Data(parts[2].utf8)
        guard payloadData.count <= maxPayloadBytes else { return .ignored(.oversized) }
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: payloadData,
                                                     using: SymmetricKey(data: credentials.macKey)) else {
            return .ignored(.badSignature)
        }

        guard let keys = ((try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any]).map({ Set($0.keys) }),
              keys == payloadKeys,
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadData),
              payload.v == protocolVersion, payload.kind == "kannu-cloud",
              states.contains(payload.state), events.contains(payload.event), notes.contains(payload.note),
              let sessionID = normalizedSessionID(payload.session),
              payload.repo.range(of: "^[A-Za-z0-9._-]{0,64}$", options: .regularExpression) != nil,
              payload.ts > 0 else {
            return .ignored(.badPayload)
        }
        let relayTime = Date(timeIntervalSince1970: time)
        let ts = Date(timeIntervalSince1970: TimeInterval(payload.ts) / 1000)
        guard abs(ts.timeIntervalSince(relayTime)) <= maxClockSkew else { return .ignored(.clockSkew) }
        let receivedAt = min(relayTime, now)

        if payload.event == "Check" { return .check(sessionID: sessionID, at: receivedAt) }
        return .event(Event(sessionID: sessionID, state: payload.state, event: payload.event, note: payload.note,
                            repo: payload.repo.isEmpty ? nil : payload.repo, ts: ts, receivedAt: receivedAt))
    }

    // MARK: - What Kannu currently knows

    struct Snapshot: Equatable, Sendable {
        var events: [String: Event] = [:]
        /// The stream is healthy. A waiting prompt holds its yellow only while it is.
        var connected = false
        var lastCheckAt: Date?
    }

    /// The newest report per session wins whatever order they arrive in; a tie goes to the more
    /// urgent state, and a replayed old report changes nothing.
    static func applying(_ event: Event, to snapshot: Snapshot, now: Date) -> Snapshot {
        var next = snapshot
        if let current = next.events[event.sessionID],
           current.ts > event.ts || (current.ts == event.ts && urgency(current.state) >= urgency(event.state)) {
            return pruned(next, now: now)
        }
        next.events[event.sessionID] = event
        return pruned(next, now: now)
    }

    static func pruned(_ snapshot: Snapshot, now: Date) -> Snapshot {
        var next = snapshot
        next.events = next.events.filter { now.timeIntervalSince($0.value.receivedAt) <= memory }
        if next.events.count > maxSessions {
            let keep = next.events.values.sorted { $0.receivedAt > $1.receivedAt }.prefix(maxSessions).map(\.sessionID)
            next.events = next.events.filter { keep.contains($0.key) }
        }
        return next
    }

    private static func urgency(_ state: String) -> Int {
        ["awaiting_input": 40, "stopped": 30, "session_end": 25, "executing": 20, "thinking": 10][state] ?? 0
    }

    // MARK: - Subscribing

    enum Since: Equatable, Sendable {
        case minutes(Int)
        case unixTime(Int)

        var queryValue: String {
            switch self {
            case .minutes(let minutes): return "\(minutes)m"
            case .unixTime(let seconds): return "\(seconds)"
            }
        }
    }

    /// `<server>/<topic>/json?since=…`: ntfy's newline-delimited JSON stream for one topic.
    static func subscribeURL(server: String, topic: String, since: Since) -> URL? {
        guard topic.range(of: "^kannu-[0-9a-f]{32}$", options: .regularExpression) != nil,
              var components = URLComponents(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "https", components.host?.isEmpty == false,
              components.query == nil, components.fragment == nil else { return nil }
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + "/" + topic + "/json"
        components.queryItems = [URLQueryItem(name: "since", value: since.queryValue)]
        return components.url
    }

    /// Doubles from 1 s to a 60 s cap; a client error (a refused topic, a used-up quota) waits
    /// five minutes, since retrying sooner cannot change the answer.
    static func nextBackoff(after current: TimeInterval, httpStatus: Int?) -> TimeInterval {
        if let status = httpStatus, (400..<500).contains(status) { return 300 }
        return min(60, max(1, current * 2))
    }

    // MARK: - Cards

    static func conversationID(sessionID: String) -> String {
        conversationPrefix + sessionID
    }

    /// The `session_…` id a cloud card's conversation id carries, or nil for anything else.
    static func sessionID(conversationID: String) -> String? {
        guard conversationID.hasPrefix(conversationPrefix) else { return nil }
        let id = String(conversationID.dropFirst(conversationPrefix.count))
        return id.range(of: "^session_[A-Za-z0-9]{1,64}$", options: .regularExpression) != nil ? id : nil
    }

    /// The cards for what the relay has reported, through the same ladder hook files use: a run
    /// ages from its last report, and a waiting prompt is held only while the stream is healthy
    /// (an idle notice stays on the clock, as Claude's does locally). The stale cap ends every card.
    static func sessions(
        snapshot: Snapshot,
        staleMinutes: Int,
        collapseSeconds: Int,
        inactiveSeconds: Int,
        now: Date
    ) -> [AgentSessionStatus] {
        let staleMs = Int64(staleMinutes) * 60_000
        return snapshot.events.values.sorted { $0.sessionID < $1.sessionID }.compactMap { report in
            let reportedAt = min(report.receivedAt, now)
            let ageMs = Int64(now.timeIntervalSince(reportedAt) * 1000)
            guard ageMs <= staleMs else { return nil }
            let hold = report.state == "awaiting_input" && report.note != "idle_prompt" && snapshot.connected
            let resolved = AgentTrafficLightMapper.resolveHookState(
                rawState: report.state,
                ageMs: ageMs,
                collapseMs: Int64(collapseSeconds) * 1000,
                inactiveMs: Int64(inactiveSeconds) * 1000,
                holdAwaitingInput: hold
            )
            let suffix = String(report.sessionID.suffix(4))
            var session = AgentSessionStatus(
                id: "\(providerKey)-\(report.sessionID)",
                provider: providerKey,
                conversationID: conversationID(sessionID: report.sessionID),
                chatName: String(localized: "Cloud session \(suffix)"),
                projectName: report.repo,
                rawState: report.state,
                displayState: resolved.state,
                updatedAt: reportedAt,
                isVisible: resolved.visible,
                executionStartedAt: nil,
                cwd: nil,
                hostPID: nil
            )
            if report.state == "stopped", report.event == "StopFailure" {
                session.runError = .failed
            }
            return session
        }
    }

    // MARK: - Helpers

    /// `cse_…` becomes `session_…`, the form claude.ai's session URLs use; anything else is nil.
    static func normalizedSessionID(_ raw: String) -> String? {
        guard raw.range(of: "^(session|cse)_[A-Za-z0-9]{1,64}$", options: .regularExpression) != nil else { return nil }
        return raw.hasPrefix("cse_") ? "session_" + raw.dropFirst(4) : raw
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func data(hex: String) -> Data? {
        guard hex.count % 2 == 0, hex.range(of: "^[0-9a-f]*$", options: .regularExpression) != nil else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
