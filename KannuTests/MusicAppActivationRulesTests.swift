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

import XCTest

/// Tapping the album art brings the music app forward. A running Spotify must come forward the way
/// Cmd-Tab does, with `activate()`: `NSWorkspace.openApplication` also sends a running app a reopen
/// event, and 0.2 s after one (2026-10-22, 20:49:00) Spotify started a second, hidden audio session
/// in its helper process that every later Play command woke as well, so two tracks played at once.
/// Every other app keeps the reopen, which brings back a closed or minimized window. `MusicManager`
/// is AppKit-bound, so the branches are read from the source.
final class MusicAppActivationRulesTests: XCTestCase {

    func testARunningSpotifyIsActivatedAndNeverReopened() throws {
        let body = try Self.openMusicAppBody()
        XCTAssertTrue(body.contains("if bundleID == Self.spotifyBundleID,"),
                      "the activate-only branch is no longer limited to Spotify; other apps lose the reopen that restores their window")
        let running = try XCTUnwrap(body.range(of: "let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {"),
                                    "openMusicApp no longer looks for a running Spotify first")
        let launchBranch = try XCTUnwrap(body.range(of: "} else if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {"),
                                         "an app that is not running is no longer launched")
        let runningBranch = body[running.upperBound..<launchBranch.lowerBound]
        XCTAssertTrue(runningBranch.contains("running.activate()"), "a running music app is no longer activated")
        XCTAssertFalse(runningBranch.contains("openApplication("),
                       "a running app is reopened again; Spotify answered a reopen with a second, hidden player")
    }

    /// `openApplication` is reachable only from the second branch: every app but a running Spotify.
    func testEveryOtherAppKeepsTheReopen() throws {
        let body = try Self.openMusicAppBody()
        let launchBranch = try XCTUnwrap(body.range(of: "} else if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {"))
        let opens = body.components(separatedBy: "openApplication(").count - 1
        XCTAssertEqual(opens, 1, "openApplication appears \(opens) times; only the launch branch may call it")
        let open = try XCTUnwrap(body.range(of: "openApplication("))
        XCTAssertGreaterThan(open.lowerBound, launchBranch.lowerBound)
    }

    private static func openMusicAppBody() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Kannu/managers/MusicManager.swift"), encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let start = try XCTUnwrap(code.range(of: "func openMusicApp() {"), "openMusicApp went away — update this test")
        let rest = code[start.upperBound...]
        let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.range(of: "\n    private static func ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }
}
