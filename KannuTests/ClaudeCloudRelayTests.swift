//
//  ClaudeCloudRelayTests.swift
//  KannuTests
//
//  Copyright (C) 2026 Kannu contributors
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import CryptoKit
import XCTest

/// Kannu's end of the cloud-session relay: everything that arrives is untrusted until the topic,
/// the signature, a closed schema and the clock all agree, and then it can only become a card.
final class ClaudeCloudRelayTests: XCTestCase {
    typealias Relay = ClaudeCloudRelay

    private let secret = String(repeating: "0123456789abcdef", count: 4)
    private lazy var credentials = Relay.credentials(secret: secret)!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Helpers

    private func payload(_ overrides: [String: Any] = [:], removing: [String] = []) -> [String: Any] {
        var object: [String: Any] = ["v": 1, "kind": "kannu-cloud", "session": "session_Abc123", "state": "executing",
                                     "event": "PreToolUse", "note": "", "repo": "my-repo",
                                     "ts": Int64(now.timeIntervalSince1970 * 1000)]
        object.merge(overrides) { _, new in new }
        removing.forEach { object.removeValue(forKey: $0) }
        return object
    }

    private func message(_ object: [String: Any], key: Data? = nil) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key ?? credentials.macKey))
        return "KC1 " + Relay.hex(Data(mac)) + " " + String(decoding: data, as: UTF8.self)
    }

    private func line(_ message: String, topic: String? = nil, time: Date? = nil, event: String = "message") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": "abc", "time": Int((time ?? now).timeIntervalSince1970), "event": event,
            "topic": topic ?? credentials.topic, "message": message
        ])
    }

    private func parse(_ object: [String: Any]) throws -> Relay.Line {
        Relay.parse(line: try line(message(object)), credentials: credentials, now: now)
    }

    private func event(state: String, ts: TimeInterval, received: TimeInterval? = nil, note: String = "",
                       session: String = "session_Abc123", event: String = "PreToolUse") -> Relay.Event {
        Relay.Event(sessionID: session, state: state, event: event, note: note, repo: "my-repo",
                    ts: now.addingTimeInterval(ts), receivedAt: now.addingTimeInterval(received ?? ts))
    }

    // MARK: - Keys

    func testCredentialsAreDerivedFromTheSecretOnly() {
        // The same vector, computed independently with Python's hashlib, is what the script uses.
        XCTAssertEqual(credentials.topic, "kannu-d7b0368ee423e8a461a99c07f909346f")
        XCTAssertEqual(Relay.hex(credentials.macKey), "52772e70cf00178d16274ca23a4f92ee876aee074166e4eccfe4bd6f70d5e743")
        XCTAssertEqual(Relay.credentials(secret: "  " + secret.uppercased() + "\n"), credentials,
                       "pasted with stray whitespace or in upper case, it is the same key")
        XCTAssertNil(Relay.credentials(secret: String(secret.dropLast())))
        XCTAssertNil(Relay.credentials(secret: String(repeating: "g", count: 64)))
    }

    func testAGeneratedSecretIsWellFormed() throws {
        let first = try XCTUnwrap(Relay.newSecret())
        XCTAssertNotNil(first.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
        XCTAssertNotEqual(first, Relay.newSecret())
        XCTAssertNotNil(Relay.credentials(secret: first))
        XCTAssertNil(Relay.newSecret(fromRandomBytes: Array(repeating: 1, count: 31)))
        XCTAssertEqual(Relay.newSecret(fromRandomBytes: Array(repeating: 255, count: 32)), String(repeating: "f", count: 64))
    }

    // MARK: - Parsing

    func testAValidMessageLineBecomesAnEvent() throws {
        guard case .event(let report) = try parse(payload()) else { return XCTFail("expected an event") }
        XCTAssertEqual(report.sessionID, "session_Abc123")
        XCTAssertEqual(report.state, "executing")
        XCTAssertEqual(report.event, "PreToolUse")
        XCTAssertEqual(report.repo, "my-repo")
        XCTAssertEqual(report.receivedAt, now)
    }

    func testOpenAndKeepaliveLinesAreLiveness() throws {
        XCTAssertEqual(Relay.parse(line: try line("", event: "open"), credentials: credentials), .open)
        XCTAssertEqual(Relay.parse(line: try line("", event: "keepalive"), credentials: credentials), .keepalive)
    }

    func testMalformedLinesAreIgnored() throws {
        XCTAssertEqual(Relay.parse(line: Data("not json".utf8), credentials: credentials), .ignored(.notJSON))
        XCTAssertEqual(Relay.parse(line: Data("[1,2]".utf8), credentials: credentials), .ignored(.notJSON))
        XCTAssertEqual(Relay.parse(line: try line("x", event: "poll_request"), credentials: credentials), .ignored(.notAMessage))
        let noTime = try JSONSerialization.data(withJSONObject: ["event": "message", "topic": credentials.topic,
                                                                 "message": try message(payload())])
        XCTAssertEqual(Relay.parse(line: noTime, credentials: credentials), .ignored(.notAMessage))
    }

    func testAMessageForAnotherTopicIsIgnored() throws {
        let other = try line(message(payload()), topic: "kannu-00000000000000000000000000000000")
        XCTAssertEqual(Relay.parse(line: other, credentials: credentials), .ignored(.wrongTopic))
    }

    func testAForgedOrAlteredMessageIsRejected() throws {
        let forged = try message(payload(), key: Data(repeating: 7, count: 32))
        XCTAssertEqual(Relay.parse(line: try line(forged), credentials: credentials, now: now), .ignored(.badSignature))
        let genuine = try message(payload())
        let altered = genuine.replacingOccurrences(of: "\"executing\"", with: "\"stopped\"")
        XCTAssertEqual(Relay.parse(line: try line(altered), credentials: credentials, now: now), .ignored(.badSignature))
        let unsigned = String(decoding: try JSONSerialization.data(withJSONObject: payload()), as: UTF8.self)
        XCTAssertEqual(Relay.parse(line: try line(unsigned), credentials: credentials, now: now), .ignored(.notSigned))
        XCTAssertEqual(Relay.parse(line: try line("KC1 zz " + unsigned), credentials: credentials, now: now), .ignored(.notSigned))
    }

    func testUnknownStatesEventsAndExtraKeysAreRejected() throws {
        XCTAssertEqual(try parse(payload(["state": "pwned"])), .ignored(.badPayload))
        XCTAssertEqual(try parse(payload(["event": "Shell"])), .ignored(.badPayload))
        XCTAssertEqual(try parse(payload(["note": "open this url"])), .ignored(.badPayload))
        XCTAssertEqual(try parse(payload(["url": "https://evil.example"])), .ignored(.badPayload), "an extra key is a different protocol")
        XCTAssertEqual(try parse(payload(removing: ["repo"])), .ignored(.badPayload))
        XCTAssertEqual(try parse(payload(["v": 2])), .ignored(.badPayload))
        XCTAssertEqual(try parse(payload(["kind": "other"])), .ignored(.badPayload))
        XCTAssertEqual(try parse(payload(["repo": "../etc"])), .ignored(.badPayload))
        XCTAssertEqual(try parse(payload(["repo": String(repeating: "r", count: 65)])), .ignored(.badPayload))
    }

    func testBadSessionIDsAreRejected() throws {
        for id in ["local_abc", "session_", "session_a/b", "session_a b", "SESSION_abc", "session_" + String(repeating: "a", count: 65)] {
            XCTAssertEqual(try parse(payload(["session": id])), .ignored(.badPayload), id)
        }
    }

    func testACseIDIsNormalized() throws {
        guard case .event(let report) = try parse(payload(["session": "cse_Abc123"])) else { return XCTFail("expected an event") }
        XCTAssertEqual(report.sessionID, "session_Abc123", "claude.ai's URLs use the session_ form")
    }

    func testOversizedLinesAndPayloadsAreRejected() throws {
        XCTAssertEqual(Relay.parse(line: Data(repeating: 0x61, count: Relay.maxLineBytes + 1), credentials: credentials),
                       .ignored(.oversized))
        let big = "KC1 " + String(repeating: "0", count: 64) + " " + String(repeating: "x", count: Relay.maxPayloadBytes + 1)
        XCTAssertEqual(Relay.parse(line: try line(big), credentials: credentials), .ignored(.oversized))
    }

    func testATimestampFarFromTheRelaysClockIsRejected() throws {
        let late = Int64(now.addingTimeInterval(Relay.maxClockSkew + 60).timeIntervalSince1970 * 1000)
        XCTAssertEqual(try parse(payload(["ts": late])), .ignored(.clockSkew))
        let close = Int64(now.addingTimeInterval(Relay.maxClockSkew - 60).timeIntervalSince1970 * 1000)
        guard case .event = try parse(payload(["ts": close])) else { return XCTFail("within the skew window") }
    }

    func testARelayClockAheadOfThisMacCannotDateAReportInTheFuture() throws {
        let ahead = now.addingTimeInterval(300)
        let ts = Int64(ahead.timeIntervalSince1970 * 1000)
        let parsed = Relay.parse(line: try line(message(payload(["ts": ts])), time: ahead), credentials: credentials, now: now)
        guard case .event(let report) = parsed else { return XCTFail("expected an event") }
        XCTAssertEqual(report.receivedAt, now, "dated no later than this Mac's clock")
    }

    func testACheckMessageIsNotACard() throws {
        XCTAssertEqual(try parse(payload(["event": "Check", "state": "idle", "repo": ""])),
                       .check(sessionID: "session_Abc123", at: now))
    }

    func testTheLineSplitterDropsOverlongLines() {
        var splitter = Relay.LineSplitter(cap: 8)
        let lines = splitter.append(Array("short\n0123456789abc\nok\n\n".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["short", "ok"],
                       "an over-long line is dropped through its newline, and blank lines are not lines")
        XCTAssertTrue(splitter.append(Array("unterminated".utf8)).isEmpty)
    }

    // MARK: - Store

    func testTheNewestEventWinsWhateverTheArrivalOrder() {
        var snapshot = Relay.Snapshot()
        snapshot = Relay.applying(event(state: "stopped", ts: -10), to: snapshot, now: now)
        snapshot = Relay.applying(event(state: "executing", ts: -20), to: snapshot, now: now)
        XCTAssertEqual(snapshot.events["session_Abc123"]?.state, "stopped", "an older report arriving late does not win")
    }

    func testATieGoesToTheMoreUrgentState() {
        var snapshot = Relay.applying(event(state: "executing", ts: -5), to: Relay.Snapshot(), now: now)
        snapshot = Relay.applying(event(state: "awaiting_input", ts: -5), to: snapshot, now: now)
        XCTAssertEqual(snapshot.events["session_Abc123"]?.state, "awaiting_input")
        snapshot = Relay.applying(event(state: "thinking", ts: -5), to: snapshot, now: now)
        XCTAssertEqual(snapshot.events["session_Abc123"]?.state, "awaiting_input")
    }

    func testReplayingAnOldMessageChangesNothing() {
        let first = Relay.applying(event(state: "awaiting_input", ts: -30), to: Relay.Snapshot(), now: now)
        let latest = Relay.applying(event(state: "thinking", ts: -10), to: first, now: now)
        XCTAssertEqual(Relay.applying(event(state: "awaiting_input", ts: -30), to: latest, now: now), latest)
    }

    func testTheStoreKeepsAtMostThirtyTwoSessionsAndForgetsOldOnes() {
        var snapshot = Relay.Snapshot()
        for index in 0..<40 {
            snapshot = Relay.applying(event(state: "thinking", ts: Double(-index), session: "session_S\(index)"),
                                      to: snapshot, now: now)
        }
        XCTAssertEqual(snapshot.events.count, Relay.maxSessions)
        XCTAssertNotNil(snapshot.events["session_S0"], "the newest are kept")
        XCTAssertNil(snapshot.events["session_S39"])
        let later = Relay.pruned(snapshot, now: now.addingTimeInterval(Relay.memory + 60))
        XCTAssertTrue(later.events.isEmpty, "an hour without news forgets a session")
    }

    // MARK: - Cards

    private func cards(_ events: [Relay.Event], connected: Bool = true, staleMinutes: Int = 30) -> [AgentSessionStatus] {
        var snapshot = Relay.Snapshot()
        events.forEach { snapshot = Relay.applying($0, to: snapshot, now: now) }
        snapshot.connected = connected
        return Relay.sessions(snapshot: snapshot, staleMinutes: staleMinutes, collapseSeconds: 5, inactiveSeconds: 5, now: now)
    }

    func testCloudSessionsMapThroughTheHookLadder() throws {
        let fresh = try XCTUnwrap(cards([event(state: "executing", ts: -10)]).first)
        XCTAssertEqual(fresh.provider, "claudecloud")
        XCTAssertEqual(fresh.displayState, .executing)
        XCTAssertTrue(fresh.isVisible)
        let quiet = try XCTUnwrap(cards([event(state: "executing", ts: -400)]).first)
        XCTAssertNotEqual(quiet.displayState, .executing, "six minutes with no report is the same threshold every hook uses")
    }

    func testAWaitingQuestionIsHeldOnlyWhileKannuIsListening() throws {
        let waiting = event(state: "awaiting_input", ts: -600, note: "permission_prompt", event: "Notification")
        XCTAssertEqual(try XCTUnwrap(cards([waiting], connected: true).first).displayState, .awaitingInput,
                       "ten minutes on, a healthy stream with no newer report means the session is still waiting")
        XCTAssertNotEqual(cards([waiting], connected: false).first?.displayState, .awaitingInput,
                          "without the stream nothing says the prompt is still open")
    }

    func testAnIdleNoticeStaysOnTheClock() {
        let idle = event(state: "awaiting_input", ts: -600, note: "idle_prompt", event: "Notification")
        XCTAssertNotEqual(cards([idle], connected: true).first?.displayState, .awaitingInput,
                          "an idle notice is not a question; it ages like Claude's does locally")
    }

    func testTheStaleCapEndsEveryCard() {
        let waiting = event(state: "awaiting_input", ts: -31 * 60, note: "permission_prompt", event: "Notification")
        XCTAssertTrue(cards([waiting], connected: true, staleMinutes: 30).isEmpty)
    }

    func testSessionEndHidesTheCard() {
        XCTAssertFalse(cards([event(state: "session_end", ts: -1, event: "SessionEnd")]).first?.isVisible ?? false)
    }

    func testAStopFailureCarriesAFailedVerdict() {
        XCTAssertEqual(cards([event(state: "stopped", ts: -1, event: "StopFailure")]).first?.runError, .failed)
        XCTAssertNil(cards([event(state: "stopped", ts: -1, event: "Stop")]).first?.runError)
    }

    func testCardsCarryTheRepoAndAContentFreeName() throws {
        let card = try XCTUnwrap(cards([event(state: "thinking", ts: -1)]).first)
        XCTAssertEqual(card.projectName, "my-repo")
        XCTAssertEqual(card.chatName, "Cloud session c123", "the last characters of the id, never anything typed")
        XCTAssertNil(card.cwd)
        XCTAssertNil(card.hostPID)
    }

    func testConversationIDsCannotCollideWithHookIDs() {
        let id = Relay.conversationID(sessionID: "session_Abc123")
        XCTAssertEqual(id, "claudecloud.session_Abc123")
        XCTAssertTrue(id.contains("."), "the hook script strips everything outside [A-Za-z0-9_-] from local ids")
        XCTAssertEqual(Relay.sessionID(conversationID: id), "session_Abc123")
        XCTAssertNil(Relay.sessionID(conversationID: "session_Abc123"))
        XCTAssertNil(Relay.sessionID(conversationID: "claudecloud.session_a/../b"))
    }

    // MARK: - Subscribing

    func testSubscribeURLUsesTheDerivedTopicAndSince() {
        XCTAssertEqual(Relay.subscribeURL(server: "https://ntfy.sh", topic: credentials.topic, since: .minutes(30))?.absoluteString,
                       "https://ntfy.sh/\(credentials.topic)/json?since=30m")
        XCTAssertEqual(Relay.subscribeURL(server: "https://relay.example.com/ntfy/", topic: credentials.topic,
                                          since: .unixTime(1_800_000_000))?.absoluteString,
                       "https://relay.example.com/ntfy/\(credentials.topic)/json?since=1800000000")
        XCTAssertNil(Relay.subscribeURL(server: "http://ntfy.sh", topic: credentials.topic, since: .minutes(1)))
        XCTAssertNil(Relay.subscribeURL(server: "https://ntfy.sh", topic: "anything/../else", since: .minutes(1)))
        XCTAssertNil(Relay.subscribeURL(server: "https://ntfy.sh?x=1", topic: credentials.topic, since: .minutes(1)))
    }

    func testAStreamResumesFromItsLastMessageWithinTheStaleWindow() {
        XCTAssertEqual(Relay.resumePoint(lastMessageTime: nil, staleMinutes: 30, now: now), .minutes(30),
                       "the first connection replays every session still worth a card")
        let recent = Int(now.timeIntervalSince1970) - 120
        XCTAssertEqual(Relay.resumePoint(lastMessageTime: recent, staleMinutes: 30, now: now), .unixTime(recent))
        let old = Int(now.timeIntervalSince1970) - 31 * 60
        XCTAssertEqual(Relay.resumePoint(lastMessageTime: old, staleMinutes: 30, now: now), .minutes(30),
                       "never further back than the stale window, after a long sleep")
        XCTAssertEqual(Relay.resumePoint(lastMessageTime: nil, staleMinutes: 0, now: now), .minutes(1))
    }

    func testBackoffIsCapped() {
        XCTAssertEqual(Relay.nextBackoff(after: 0, httpStatus: nil), 1)
        XCTAssertEqual(Relay.nextBackoff(after: 8, httpStatus: 500), 16)
        XCTAssertEqual(Relay.nextBackoff(after: 50, httpStatus: nil), 60)
        XCTAssertEqual(Relay.nextBackoff(after: 1, httpStatus: 429), 300, "a used-up quota cannot be retried away")
        XCTAssertEqual(Relay.nextBackoff(after: 1, httpStatus: 403), 300)
    }
}
