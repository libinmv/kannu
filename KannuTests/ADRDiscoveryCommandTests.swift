//
//  ADRDiscoveryCommandTests.swift
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

/// The `adr-discovery` invocation as data — the REGRESSIONS entry 8 discipline. Every flag
/// here was checked against upstream's `cli.py` (0.2.0).
final class ADRDiscoveryCommandTests: XCTestCase {
    private let out = URL(fileURLWithPath: "/Users/dev/.kannu/adr/discovery", isDirectory: true)

    func testArgumentsWriteAJSONSnapshotIntoTheWatchedFolder() {
        let args = ADRDiscoveryCommand.arguments(outputDirectory: out, policyFile: nil)
        XCTAssertEqual(args, ["--json", "--output-dir", "/Users/dev/.kannu/adr/discovery"])
        XCTAssertTrue(ADRDiscoveryCommand.isValidScan(arguments: args))
    }

    func testPolicyIsAppendedOnlyWhenConfigured() {
        let policy = URL(fileURLWithPath: "/Users/dev/policy.json")
        let args = ADRDiscoveryCommand.arguments(outputDirectory: out, policyFile: policy)
        XCTAssertEqual(args.suffix(2), ["--policy", "/Users/dev/policy.json"])
        XCTAssertTrue(ADRDiscoveryCommand.isValidScan(arguments: args))
    }

    func testForbiddenFlagsAreRejected() {
        // --dry-run writes nothing; --root scans a fixture tree; --diff/--explain change the output.
        for flag in ["--dry-run", "--root", "--diff", "--explain"] {
            XCTAssertFalse(ADRDiscoveryCommand.isValidScan(arguments: ["--json", "--output-dir", out.path, flag]), flag)
        }
        XCTAssertFalse(ADRDiscoveryCommand.isValidScan(arguments: ["--output-dir", out.path]), "no --json, no machine-readable file")
        XCTAssertFalse(ADRDiscoveryCommand.isValidScan(arguments: ["--json", "--output-dir"]), "dangling --output-dir")
    }

    func testExitCodesMatchUpstream() {
        XCTAssertTrue(ADRDiscoveryCommand.producedSnapshot(exitStatus: 0))
        XCTAssertTrue(ADRDiscoveryCommand.producedSnapshot(exitStatus: 2), "partial coverage still wrote a snapshot")
        XCTAssertFalse(ADRDiscoveryCommand.producedSnapshot(exitStatus: 1))
        XCTAssertFalse(ADRDiscoveryCommand.producedSnapshot(exitStatus: -1))
    }

    func testTimeoutIsBoundedButGenerous() {
        // A real scan here took 17 s; a hung one must not pin a worker forever.
        XCTAssertGreaterThanOrEqual(ADRDiscoveryCommand.timeout, 60)
        XCTAssertLessThanOrEqual(ADRDiscoveryCommand.timeout, 600)
    }

    /// The prompt is the whole spec the user's agent gets, so pin what it must carry: where to
    /// write, the one list that affects MCP servers, the check that keeps a bad file from failing
    /// every scan, and the rule against copying secrets out of MCP configs.
    func testThePolicyDraftingPromptStatesTheFormatAndItsLimits() {
        let prompt = ADRDiscoveryCommand.policyDraftingPrompt
        XCTAssertTrue(prompt.contains(ADRDiscoveryCommand.suggestedPolicyPath))
        XCTAssertTrue(prompt.contains(#"{"tenant_domains": ["#))
        XCTAssertTrue(prompt.contains("python3 -m json.tool"))
        XCTAssertTrue(prompt.contains("never tokens, headers or environment values"))
        XCTAssertTrue(prompt.contains("never flag an MCP server"), "approved/forbidden must not be sold as MCP controls")
        XCTAssertTrue(prompt.contains("Ask me"))
        // The suggested file is ADR's policy, never inside the snapshots folder Kannu watches.
        XCTAssertFalse(ADRDiscoveryCommand.suggestedPolicyPath.contains("/discovery/"))
    }
}
