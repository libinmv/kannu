//
//  HiddenTextIncidentTests.swift
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

import XCTest

/// The hook's `hidden_text` entries as Kannu reads them, and how a sighting becomes a finding.
final class HiddenTextIncidentTests: XCTestCase {
    typealias Incident = HiddenTextIncident
    private let t0: Int64 = 1_789_000_000_000

    private func incident(_ kind: Incident.Kind = .tags, _ location: Incident.Location = .toolResult,
                          tool: String? = "Read", chars: Int = 25, events: Int = 1, preview: String = "hidden words",
                          first: Int64? = nil, last: Int64? = nil) -> Incident {
        Incident(kind: kind, location: location, tool: tool, characterCount: chars, eventCount: events, preview: preview,
                 firstSeenMs: first ?? t0, lastSeenMs: last ?? first ?? t0)
    }

    private func entry(_ fields: [String: Any]) -> [String: Any] {
        var base: [String: Any] = ["kind": "tags", "where": "tool_result", "tool": "Read", "chars": 25, "events": 1,
                                   "preview": "hidden words", "first_ts": NSNumber(value: t0), "last_ts": NSNumber(value: t0)]
        base.merge(fields) { _, new in new }
        return base
    }

    // MARK: - Parsing

    func testParsesWhatTheHookWrites() {
        let parsed = Incident.list(fromHookValue: [entry([:])])
        XCTAssertEqual(parsed, [incident()])
    }

    func testParsingIsTolerantOfJunk() {
        XCTAssertEqual(Incident.list(fromHookValue: nil), [])
        XCTAssertEqual(Incident.list(fromHookValue: "tags"), [])
        XCTAssertEqual(Incident.list(fromHookValue: [42, "x", ["kind": "mystery", "first_ts": t0]]), [])
        XCTAssertEqual(Incident.list(fromHookValue: [entry(["first_ts": 12345])]), [], "an implausible clock is dropped")
        let clamped = Incident.list(fromHookValue: [entry(["chars": -5, "events": 5000, "last_ts": NSNumber(value: t0 - 10),
                                                             "where": "nowhere", "tool": "Re\u{0}ad<script>"])])
        XCTAssertEqual(clamped.first?.characterCount, 0)
        XCTAssertEqual(clamped.first?.eventCount, 999)
        XCTAssertEqual(clamped.first?.lastSeenMs, t0, "last never precedes first")
        XCTAssertEqual(clamped.first?.location, .other)
        XCTAssertEqual(clamped.first?.tool, "Readscript")
        let many = (0..<5).map { entry(["first_ts": NSNumber(value: t0 + Int64($0))]) }
        XCTAssertEqual(Incident.list(fromHookValue: many).map(\.firstSeenMs), [t0 + 2, t0 + 3, t0 + 4], "newest three")
    }

    func testPreviewIsPrintableASCIIOnly() {
        XCTAssertEqual(Incident.sanitizedPreview("ok\u{7}\u{E0041}é done\n"), "ok done")
        XCTAssertEqual(Incident.sanitizedPreview(String(repeating: "a", count: 500)).count, Incident.previewLimit)
        XCTAssertNil(Incident.sanitizedTool(""))
        XCTAssertNil(Incident.sanitizedTool("\u{202E}"))
        XCTAssertEqual(Incident.sanitizedTool("mcp__github__get_issue"), "mcp__github__get_issue")
    }

    // MARK: - Severity, identity, wording

    func testSeverityIsHighOnlyForReadableHiddenMessages() {
        XCTAssertEqual(incident(.tags, preview: "ignore this").severity, .high)
        XCTAssertEqual(incident(.variationSelectors, preview: "hi there").severity, .high)
        XCTAssertEqual(incident(.tags, preview: "ab").severity, .medium, "a stray tag or two decodes to nothing")
        XCTAssertEqual(incident(.zeroWidth, preview: "").severity, .medium)
        XCTAssertEqual(incident(.bidi, preview: "if x <RLO> y").severity, .medium, "reordering is suspicious, not a message")
    }

    func testFindingIDIgnoresWhatChangesAndFollowsWhatDoesNot() {
        let base = incident()
        let later = incident(chars: 300, events: 4, preview: "hidden words and more", last: t0 + 60_000)
        XCTAssertEqual(base.findingID(conversationID: "c1"), later.findingID(conversationID: "c1"),
                       "more sightings of the same incident keep its acknowledgement")
        XCTAssertNotEqual(base.findingID(conversationID: "c1"), base.findingID(conversationID: "c2"))
        XCTAssertNotEqual(base.findingID(conversationID: "c1"), incident(first: t0 + 1).findingID(conversationID: "c1"))
        XCTAssertNotEqual(base.findingID(conversationID: "c1"), incident(.tags, .prompt).findingID(conversationID: "c1"))
        let a = base.finding(conversationID: "c1", provider: "claude", chatName: "Old", projectName: nil, cwd: nil)
        let b = base.finding(conversationID: "c1", provider: "claude", chatName: "Fix the parser", projectName: "kannu", cwd: "/p")
        XCTAssertEqual(a.id, b.id, "a resolved chat name does not change the id")
    }

    func testEveryKindAndPlaceHasWords() {
        for kind in Incident.Kind.allCases {
            for location in Incident.Location.allCases {
                let i = incident(kind, location)
                XCTAssertFalse(i.title.isEmpty)
                XCTAssertTrue(i.rule.hasPrefix("hidden_text_"))
                XCTAssertFalse(i.summary(chatName: "Chat").isEmpty)
            }
        }
        XCTAssertEqual(incident(.tags, .prompt).title, "Hidden text in your prompt")
        XCTAssertEqual(incident(.tags, .toolInput, tool: "Write").title, "Hidden text the agent wrote")
    }

    func testSummaryNeverCarriesTheHiddenText() {
        let i = incident(events: 3, preview: "SECRET PAYLOAD")
        let summary = i.summary(chatName: "Fix the parser")
        XCTAssertFalse(summary.contains("SECRET"), "the summary is what a push sends")
        XCTAssertTrue(summary.contains("25 invisible characters in a Read result"))
        XCTAssertTrue(summary.contains("Seen 3 times"))
        let finding = i.finding(conversationID: "c1", provider: "claude", chatName: "Fix the parser", projectName: "kannu", cwd: "/p")
        XCTAssertEqual(finding.source, AgentSecurityFinding.Source.kannu)
        XCTAssertEqual(finding.severity, AgentSecurityFinding.Severity.high)
        XCTAssertEqual(finding.sessionID, "c1")
        XCTAssertEqual(finding.kannuOnlyEvidence, ["Decodes to: “SECRET PAYLOAD”"], "the decoded text is shown in Kannu only")
        XCTAssertEqual(finding.displayedEvidence.first, "Decodes to: “SECRET PAYLOAD”")
        XCTAssertFalse(finding.evidence.contains { $0.contains("SECRET") }, "evidence is what leaves Kannu")
        XCTAssertEqual(Set(finding.displayedEvidence).count, finding.displayedEvidence.count, "evidence lines are distinct")
    }

    // MARK: - Merging

    func testUnionKeepsTheNewerCopyAndTheNewestThree() {
        let first = incident(first: t0)
        let firstLater = incident(events: 3, first: t0, last: t0 + 5_000)
        XCTAssertEqual(Incident.union([first], []), [first])
        XCTAssertEqual(Incident.union([], [first]), [first])
        XCTAssertEqual(Incident.union([first], [firstLater]), [firstLater])
        XCTAssertEqual(Incident.union([firstLater], [first]), [firstLater])
        let four = (0..<4).map { incident(first: t0 + Int64($0)) }
        XCTAssertEqual(Incident.union(Array(four.prefix(2)), Array(four.suffix(2))).map(\.firstSeenMs),
                       [t0 + 1, t0 + 2, t0 + 3])
    }

    func testReconstructionHelpersKeepTheField() {
        var s = AgentSessionStatus(id: "claude-a", provider: "claude", conversationID: "a", chatName: "Chat", projectName: "proj",
                                   rawState: "executing", displayState: .executing, updatedAt: Date(timeIntervalSince1970: 1_000),
                                   isVisible: true, executionStartedAt: nil, cwd: nil, hostPID: nil)
        s.sightings.hiddenText = [incident()]
        XCTAssertEqual(s.withDisplayState(.stopped, visible: true).sightings.hiddenText, [incident()])
        XCTAssertEqual(s.replacingChatName("x").sightings.hiddenText, [incident()])
        XCTAssertEqual(s.replacingProjectName("y").sightings.hiddenText, [incident()])
        var bare = s
        bare.sightings = HookSightings()
        XCTAssertEqual(bare.carryingExtras(from: s).sightings.hiddenText, [incident()])
    }

    // MARK: - Persisted records

    func testRecordsUpsertRefreshAndEvictLeastRecentlySeen() {
        var session = AgentSessionStatus(id: "claude-a", provider: "claude", conversationID: "a", chatName: nil, projectName: "proj",
                                         rawState: "executing", displayState: .executing, updatedAt: Date(timeIntervalSince1970: 1_000),
                                         isVisible: true, executionStartedAt: nil, cwd: "/p", hostPID: nil)
        typealias Record = HookSightingRecord<Incident>
        XCTAssertEqual(Record.upserting([session], \.hiddenText, into: [], cap: 5), [], "no sighting, nothing to do")
        session.sightings.hiddenText = [incident()]
        let once = Record.upserting([session], \.hiddenText, into: [], cap: 5)
        XCTAssertEqual(once.count, 1)
        XCTAssertEqual(once[0].chatName, "Untitled chat")
        XCTAssertEqual(Record.upserting([session], \.hiddenText, into: once, cap: 5), once, "unchanged input, unchanged output")
        session.sightings.hiddenText = [incident(events: 2, last: t0 + 1_000)]
        let refreshed = Record.upserting([session], \.hiddenText, into: once, cap: 5)
        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(refreshed[0].sighting.eventCount, 2)
        XCTAssertEqual(refreshed[0].finding.id, once[0].finding.id)
        session.sightings.hiddenText = [incident(first: t0 + 10), incident(.bidi, first: t0 + 20)]
        let capped = Record.upserting([session], \.hiddenText, into: refreshed, cap: 2)
        // Last seen: the refreshed record at t0+1000, the bidi one at t0+20, the new tags one at t0+10.
        XCTAssertEqual(capped.map { $0.sighting.firstSeenMs }, [t0, t0 + 20], "the least recently seen is evicted")
    }
}
