//
//  ADRSnapshotTests.swift
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

/// The fixture is a real `adr-discovery --json --dry-run` snapshot (schema 1.0, catalog
/// 2026.08.22) taken on a developer Mac and sanitised: hostname, username and paths replaced,
/// the asset list trimmed to the ones the finding and the coverage refer to.
enum ADRSnapshotFixture {
    static let json = """
    {
      "assets": [
        {
          "asset_id": "4a7894375c7bf6336b3e8989402d9f99",
          "catalog_id": null,
          "confidence": {"channels": ["config"], "label": "low"},
          "evidence": [
            {"channel": "config", "confidence": 0.85, "path": "/Users/dev/.claude/mcp.json", "proof": "declared in plugin scope", "rung": null, "stage": "extractor"}
          ],
          "flags": ["config_scope=plugin"],
          "identity": "mcp_server:notion",
          "install_method": null,
          "install_path": "/Users/dev/.claude/mcp.json",
          "install_root": "/Users/dev/.claude",
          "kind": "mcp_server",
          "last_used": null,
          "liveness": "declared_only",
          "location": "local",
          "name": "notion",
          "owner": "system",
          "risk": {"credential_kinds": [], "destinations": [], "env_names": ["NOTION_API_KEY"], "factors": ["unpinned_supply_chain"], "pinned": false, "transport": "stdio", "unattended": false},
          "sanction": "unknown",
          "vendor": null,
          "verification": [],
          "version": null
        },
        {
          "asset_id": "b2c2a5235818c9078210753c56c8cc47",
          "catalog_id": "claude-code",
          "confidence": {"channels": ["package"], "label": "low"},
          "evidence": [
            {"channel": "package", "confidence": 0.95, "path": "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code", "proof": "npm owns @anthropic-ai/claude-code", "rung": "provenance", "stage": "identifier"}
          ],
          "flags": [],
          "identity": "claude-code",
          "install_method": "npm",
          "install_path": "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code",
          "install_root": "/opt/homebrew/lib/node_modules/@anthropic-ai",
          "kind": "cli_agent",
          "last_used": null,
          "liveness": "installed",
          "location": "local",
          "name": "Claude Code",
          "owner": "system",
          "risk": {"credential_kinds": [], "destinations": [], "env_names": [], "factors": [], "pinned": null, "transport": null, "unattended": false},
          "sanction": "unknown",
          "vendor": "Anthropic",
          "verification": ["provenance"],
          "version": "2.1.223"
        }
      ],
      "catalog_version": "2026.08.22",
      "coverage": {
        "boundaries_hit": [
          {"boundary": "budget_exhausted", "detail": "cap 200000; directory truncated", "path": "/Users/dev/Library/Containers/com.apple.photoanalysisd/Data/tmp"}
        ],
        "denied": [
          {"path": "/Users/jamfadmin/Library/Application Support/Claude", "reason": "Permission denied"}
        ],
        "out_of_scope": ["instruction_files", "agent_hooks", "scheduling_mechanisms"],
        "probes": [
          {"detail": "30 records", "name": "packages", "status": "ran"},
          {"detail": "75 records", "name": "applications", "status": "ran"}
        ],
        "roots_swept": [
          {"depth_reached": 6, "entries": 198042, "path": "/Users/dev"}
        ],
        "truncated": [],
        "unavailable": [
          {"provider": "dns_cache", "reason": "mDNSResponder cache is not enumerable"}
        ]
      },
      "findings": [
        {
          "asset_id": "4a7894375c7bf6336b3e8989402d9f99",
          "evidence": [
            {"channel": "config", "confidence": 0.9, "path": "/Users/dev/.claude/mcp.json", "proof": "no version in the resolved operand", "rung": null, "stage": "judge"}
          ],
          "rule": "unpinned_mcp_server",
          "severity": "medium",
          "summary": "notion resolves its package at launch time"
        }
      ],
      "hostname": "mac.local",
      "platform": "darwin",
      "review_queue": [
        {"path": "/Users/dev/Library/Application Support/mystery-agent", "score": 0.55, "signals": ["mcp_participation", "state_dir"]}
      ],
      "schema_version": "1.0",
      "timestamp": "2026-09-09T02:00:00+00:00",
      "username": "dev"
    }
    """
}

final class ADRSnapshotTests: XCTestCase {

    func testDecodesARealSnapshot() throws {
        let snapshot = try ADRSnapshot.decode(Data(ADRSnapshotFixture.json.utf8))
        XCTAssertEqual(snapshot.schemaVersion, "1.0")
        XCTAssertEqual(snapshot.catalogVersion, "2026.08.22")
        XCTAssertEqual(snapshot.platform, "darwin")
        XCTAssertEqual(snapshot.assets.count, 2)
        XCTAssertEqual(snapshot.findings.count, 1)
        XCTAssertEqual(snapshot.reviewQueue.count, 1)

        let finding = snapshot.findings[0]
        XCTAssertEqual(finding.rule, "unpinned_mcp_server")
        XCTAssertEqual(finding.severity, "medium")
        XCTAssertEqual(finding.evidence.first?.proof, "no version in the resolved operand")
        XCTAssertNil(finding.evidence.first?.rung)

        let asset = try XCTUnwrap(snapshot.asset(id: finding.assetId))
        XCTAssertEqual(asset.name, "notion")
        XCTAssertEqual(asset.kind, "mcp_server")
        XCTAssertEqual(asset.liveness, "declared_only")
        XCTAssertEqual(asset.risk?.pinned, false)
        XCTAssertEqual(asset.risk?.envNames, ["NOTION_API_KEY"], "names only — ADR never emits values")
        XCTAssertEqual(asset.confidence?.label, "low")

        let claude = try XCTUnwrap(snapshot.assets.first { $0.catalogId == "claude-code" })
        XCTAssertEqual(claude.version, "2.1.223")
        XCTAssertEqual(claude.installMethod, "npm")
    }

    func testCoverageIsPartialWhenAnythingWentUnread() throws {
        let snapshot = try ADRSnapshot.decode(Data(ADRSnapshotFixture.json.utf8))
        XCTAssertFalse(snapshot.coverage.isComplete, "one denied dir, one boundary, one unavailable probe")
        XCTAssertEqual(snapshot.coverage.gapCount, 3)
        XCTAssertEqual(snapshot.coverage.outOfScope, ["instruction_files", "agent_hooks", "scheduling_mechanisms"])
        XCTAssertEqual(snapshot.coverage.probes.map(\.name), ["packages", "applications"])
    }

    func testUnknownKeysAreIgnoredAndMissingOptionalsAreNil() throws {
        let extended = ADRSnapshotFixture.json.replacingOccurrences(
            of: "\"hostname\": \"mac.local\",",
            with: "\"hostname\": \"mac.local\", \"future_field\": {\"x\": 1},"
        )
        let snapshot = try ADRSnapshot.decode(Data(extended.utf8))
        XCTAssertEqual(snapshot.hostname, "mac.local")
        XCTAssertNil(snapshot.assets[0].vendor)
        XCTAssertNil(snapshot.assets[0].version)
    }

    func testNewerSchemaMajorIsRefusedWithAMessage() {
        let v2 = ADRSnapshotFixture.json.replacingOccurrences(of: "\"schema_version\": \"1.0\"", with: "\"schema_version\": \"2.0\"")
        XCTAssertThrowsError(try ADRSnapshot.decode(Data(v2.utf8))) { error in
            XCTAssertEqual(error as? ADRSnapshot.DecodeError, .unsupportedSchema("2.0"))
        }
        // A minor bump within 1.x must keep decoding.
        let v1_3 = ADRSnapshotFixture.json.replacingOccurrences(of: "\"schema_version\": \"1.0\"", with: "\"schema_version\": \"1.3\"")
        XCTAssertNoThrow(try ADRSnapshot.decode(Data(v1_3.utf8)))
    }

    func testNotASnapshotIsRefused() {
        XCTAssertThrowsError(try ADRSnapshot.decode(Data("{\"hello\": 1}".utf8))) { error in
            XCTAssertEqual(error as? ADRSnapshot.DecodeError, .notASnapshot)
        }
        XCTAssertThrowsError(try ADRSnapshot.decode(Data("not json".utf8)))
    }

    func testNewestSnapshotFileWins() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kannu-adr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(ADRSnapshot.newestSnapshotURL(in: dir))

        let older = dir.appendingPathComponent("snapshot-20260901T090000.json")
        let newer = dir.appendingPathComponent("snapshot-20260909T090000.json")
        let decoy = dir.appendingPathComponent("notes.json")
        try "{}".write(to: older, atomically: true, encoding: .utf8)
        try "{}".write(to: decoy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: older.path)
        try "{}".write(to: newer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: newer.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3_000)], ofItemAtPath: decoy.path)

        XCTAssertEqual(ADRSnapshot.newestSnapshotURL(in: dir)?.lastPathComponent, "snapshot-20260909T090000.json",
                       "only snapshot-*.json counts, newest by mtime")
    }
}
