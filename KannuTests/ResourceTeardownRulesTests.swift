//
//  ResourceTeardownRulesTests.swift
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

/// Whoever stops using a resource has to say so, and a default no-op is not saying so.
///
/// Two shapes, both of which cost real battery in the field before they were found, and neither of
/// which any unit test can reach — the code is AppKit and process lifecycle throughout. So they are
/// pinned by reading the sources, the way `ModalPresentationRulesTests` pins the modal ban.
///
/// **1. `MediaControllerProtocol` must not default its own teardown.** `stop()` and
/// `terminateChildProcessesForAppExit()` were declared with default no-op implementations, on the
/// reasoning that "most controllers own nothing of the sort". Two of the five did:
/// `AmazonMusicController` owns a `mediaremote-adapter.pl` child, and `YouTubeMusicController` owns a
/// repeating timer and a WebSocket whose disconnect handler reconnects itself. Both silently
/// inherited "release nothing", so `MusicManager.releaseActiveController()` — which was calling both
/// methods correctly all along — released nothing, and every Music Source change left one more
/// orphaned helper or one more self-reconnecting socket running for the life of the process. The rule
/// was already written down for `NowPlayingController` (`e7dfc83`) and the doc comment on the
/// protocol still says `deinit` is not a teardown path; a default implementation is what let the next
/// two controllers ignore it. Restoring the default would make the same class of leak invisible
/// again, which is the only thing this half of the test exists to stop.
///
/// **2. A `readabilityHandler` is cleared wherever it is installed.** When the child at the other end
/// exits, the read end is permanently signalled readable: `availableData` returns empty, the closure
/// returns, GCD re-arms the source, and it fires again immediately — a tight loop that burns idle
/// wakeups with nothing to show. Three sites installed one and never cleared it; three others in the
/// same codebase already did it correctly, which is what makes those three a slip rather than a
/// design.
final class ResourceTeardownRulesTests: XCTestCase {

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root

    // MARK: - 1. No defaulted teardown on the media controller protocol

    func testTheMediaControllerProtocolDoesNotDefaultItsTeardown() throws {
        let path = "Kannu/MediaControllers/MediaControllerProtocol.swift"
        let source = try XCTUnwrap(Self.appSources()[path], "\(path) was not read; the rule would pass vacuously.")

        // Both must still be *requirements*, or the compiler stops catching a missing teardown.
        XCTAssertTrue(source.contains("func stop() async"), "stop() is no longer declared on the protocol.")
        XCTAssertTrue(
            source.contains("func terminateChildProcessesForAppExit()"),
            "terminateChildProcessesForAppExit() is no longer declared on the protocol."
        )

        // And neither may be given a body in an extension of the protocol.
        let defaulted = Self.lines(of: source)
            .filter { $0.contains("func stop() async {") || $0.contains("func terminateChildProcessesForAppExit() {") }
        XCTAssertEqual(
            defaulted, [],
            """
            MediaControllerProtocol is defaulting its own teardown again. A conformer that owns a \
            child process, a timer or a socket then inherits "release nothing" and leaks one per \
            controller switch — silently, because nothing fails to compile. Every conformer states \
            its teardown, even the AppleScript ones that have nothing to release.
            """
        )
    }

    func testEveryMediaControllerStatesItsTeardown() {
        // Conformance is spelled three different ways here — `: MediaControllerProtocol`,
        // `, MediaControllerProtocol` and `MediaControllerProtocol, @unchecked Sendable` — so match
        // the declaration line rather than one punctuation variant. Matching only `:` found three of
        // five, which is what the count assertion below is for.
        let controllers = Self.appSources().filter { path, source in
            guard path.hasPrefix("Kannu/MediaControllers/"),
                  path != "Kannu/MediaControllers/MediaControllerProtocol.swift" else { return false }
            return Self.lines(of: source).contains { line in
                (line.hasPrefix("class ") || line.hasPrefix("final class ") || line.hasPrefix("actor "))
                    && line.contains("MediaControllerProtocol")
            }
        }
        // Five conformers today: NowPlaying, AppleMusic, Amazon, Spotify, YouTubeMusic.
        XCTAssertGreaterThanOrEqual(controllers.count, 5, "The conformer scan found too few files — check the path, not the rule.")

        var silent: [String] = []
        for (path, source) in controllers {
            if !source.contains("func stop() async") { silent.append("\(path): no stop()") }
            if !source.contains("func terminateChildProcessesForAppExit()") {
                silent.append("\(path): no terminateChildProcessesForAppExit()")
            }
        }
        XCTAssertEqual(silent.sorted(), [], "A media controller does not state its teardown.")
    }

    // MARK: - 2. Every installed readabilityHandler is cleared

    func testEveryFileThatInstallsAReadabilityHandlerAlsoClearsIt() {
        let sources = Self.appSources()
        XCTAssertGreaterThan(sources.count, 100, "The source scan found almost nothing — check the path, not the rule.")

        var offenders: [String] = []
        for (path, source) in sources {
            let lines = Self.lines(of: source)
            guard lines.contains(where: { $0.contains("readabilityHandler = {") }) else { continue }
            guard !lines.contains(where: { $0.contains("readabilityHandler = nil") }) else { continue }
            offenders.append(path)
        }

        XCTAssertEqual(
            offenders.sorted(), [],
            """
            A readabilityHandler is installed here and never cleared. Once the child exits, the read \
            end stays signalled readable forever: the handler is re-armed on every empty read and \
            spins, burning idle wakeups until the process quits. Clear it — and close the descriptor \
            — where the process is torn down, as SystemTimerBridge.stopLogStream() does.
            """
        )

        // Anti-vacuity: the files this rule is about must actually be in the scan and must actually
        // install one, or an empty offender list means nothing.
        for path in [
            "Kannu/MediaControllers/NowPlayingController.swift",
            "Kannu/MediaControllers/AmazonMusicController.swift",
            "Kannu/managers/BluetoothAudioManager.swift",
            "Kannu/managers/SystemTimerBridge.swift"
        ] {
            let source = sources[path]
            XCTAssertNotNil(source, "\(path) was not read; the rule would pass vacuously.")
            XCTAssertTrue(
                source?.contains("readabilityHandler = {") == true,
                "\(path) no longer installs a readabilityHandler — drop it from this list deliberately."
            )
        }
    }

    // MARK: - The scanner catches what it claims to

    func testTheScannerCatchesBothShapesOfOffender() {
        let defaulted = """
            extension MediaControllerProtocol {
                func stop() async {}
                func terminateChildProcessesForAppExit() {}
            }
            """
        XCTAssertEqual(
            Self.lines(of: defaulted).filter {
                $0.contains("func stop() async {") || $0.contains("func terminateChildProcessesForAppExit() {")
            }.count,
            2
        )

        // A comment describing the mistake is not the mistake.
        let commented = """
            // func stop() async {} used to be defaulted here.
            /// func terminateChildProcessesForAppExit() {} too.
            """
        XCTAssertEqual(
            Self.lines(of: commented).filter {
                $0.contains("func stop() async {") || $0.contains("func terminateChildProcessesForAppExit() {")
            },
            []
        )

        let installsOnly = "pipe.fileHandleForReading.readabilityHandler = { handle in }"
        XCTAssertTrue(Self.lines(of: installsOnly).contains { $0.contains("readabilityHandler = {") })
        XCTAssertFalse(Self.lines(of: installsOnly).contains { $0.contains("readabilityHandler = nil") })
    }

    // MARK: - Helpers

    /// Source lines with comment lines dropped, so prose about a rule never trips it.
    private static func lines(of source: String) -> [String] {
        source.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("/*")
        }
    }

    /// Every Swift file under `Kannu/`, keyed by its repo-relative path.
    private static func appSources() -> [String: String] {
        let root = repoRoot.appendingPathComponent("Kannu")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
        var out: [String: String] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let path = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            out[path] = text
        }
        return out
    }
}
