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

/// The parts of the hang watchdog that can be tested without a wedged app: the threshold, the file
/// format, the scrubbing, and the issue the user is offered.
///
/// The part that cannot be tested here — suspending the main thread and walking its frame pointers
/// — is kept as small as possible for exactly this reason.
final class HangReportTests: XCTestCase {

    private let recorded = Date(timeIntervalSince1970: 1_757_680_000)

    private func report(
        duration: TimeInterval = 12.4,
        frames: [String] = ["0  Kannu  $s5Kannu9freezeHereyyF + 32", "1  AppKit  -[NSApplication run] + 464"]
    ) -> HangReport {
        HangReport(
            duration: duration,
            recordedAt: recorded,
            appVersion: "1.3.0",
            buildNumber: "3",
            systemVersion: "Version 15.6 (Build 24G84)",
            architecture: "arm64",
            frames: frames
        )
    }

    // MARK: - The ladder

    func testTheThresholdFiresAtFiveSecondsAndNotBefore() {
        XCTAssertFalse(HangWatchdogSpec.isHung(unansweredFor: 0))
        XCTAssertFalse(HangWatchdogSpec.isHung(unansweredFor: 2))
        XCTAssertFalse(HangWatchdogSpec.isHung(unansweredFor: 4.99))
        XCTAssertTrue(HangWatchdogSpec.isHung(unansweredFor: 5))
        XCTAssertTrue(HangWatchdogSpec.isHung(unansweredFor: 90))
    }

    /// The ping has to be well under the threshold or a hang is noticed a tick late, and well over
    /// a frame or the tick itself is the cost.
    func testThePingIsCheaperThanTheThreshold() {
        XCTAssertLessThan(HangWatchdogSpec.pingInterval, HangWatchdogSpec.hangThreshold)
        XCTAssertGreaterThanOrEqual(HangWatchdogSpec.pingInterval, 1)
    }

    // MARK: - The file

    func testTheFileRoundTrips() throws {
        let written = report()
        let read = try XCTUnwrap(HangReport.parse(fileContents: written.fileContents))
        XCTAssertEqual(read.appVersion, "1.3.0")
        XCTAssertEqual(read.buildNumber, "3")
        XCTAssertEqual(read.systemVersion, "Version 15.6 (Build 24G84)")
        XCTAssertEqual(read.architecture, "arm64")
        XCTAssertEqual(read.frames, written.frames)
        XCTAssertEqual(read.duration, 12.4, accuracy: 0.05)
        XCTAssertEqual(read.recordedAt.timeIntervalSince1970, recorded.timeIntervalSince1970, accuracy: 1)
    }

    func testAReportWithNoStackStillRoundTrips() throws {
        let written = report(frames: [])
        XCTAssertTrue(written.fileContents.contains("main thread stack: unavailable"))
        let read = try XCTUnwrap(HangReport.parse(fileContents: written.fileContents))
        XCTAssertEqual(read.frames, [])
        XCTAssertEqual(read.duration, 12.4, accuracy: 0.05)
    }

    /// A report is written while the app is wedged, so a force-quit can cut it short.
    func testATruncatedOrForeignFileIsRefused() {
        XCTAssertNil(HangReport.parse(fileContents: ""))
        XCTAssertNil(HangReport.parse(fileContents: "Kannu hang report"))
        XCTAssertNil(HangReport.parse(fileContents: "Kannu hang report\nrecorded: 2026-09-12T12:00:00Z"))
        XCTAssertNil(HangReport.parse(fileContents: "Process: Kannu [123]\nException Type: EXC_CRASH"))
    }

    /// The newest report is found by sorting file names, so the name has to sort by time.
    func testFileNamesSortNewestLast() {
        let early = HangReport.fileName(for: Date(timeIntervalSince1970: 1_757_600_000))
        let late = HangReport.fileName(for: Date(timeIntervalSince1970: 1_757_690_000))
        XCTAssertLessThan(early, late)
        XCTAssertTrue(HangReport.isHangLogName(early))
        XCTAssertFalse(HangReport.isHangLogName("Kannu-2026-09-12-234024.ips"))
        XCTAssertFalse(HangReport.isHangLogName("hang-notes.md"))
    }

    // MARK: - Scrubbing

    func testScrubbingRemovesTheHomeFolderAndAnyOtherUsername() {
        let raw = "3  Kannu  /Users/someone/Library/Developer/Xcode/DerivedData/Kannu/Kannu.debug.dylib"
        let scrubbed = HangReport.scrub(raw, home: "/Users/someone")
        XCTAssertFalse(scrubbed.contains("someone"))
        XCTAssertTrue(scrubbed.contains("~/Library/Developer"))

        let other = HangReport.scrub("/Users/anotherperson/Applications/Kannu.app", home: "/Users/someone")
        XCTAssertEqual(other, "/Users/redacted/Applications/Kannu.app")
    }

    func testScrubbingKeepsWhatTheReportIsFor() {
        let scrubbed = HangReport.scrub(
            "7  AppKit  -[NSSavePanel runModal] + 124",
            home: "/Users/someone"
        )
        XCTAssertEqual(scrubbed, "7  AppKit  -[NSSavePanel runModal] + 124")
    }

    /// A trailing slash, an empty string or `/` must not turn every path into nonsense.
    func testScrubbingSurvivesAnOddHomePath() {
        XCTAssertEqual(HangReport.scrub("no paths here", home: ""), "no paths here")
        XCTAssertEqual(HangReport.scrub("/var/log/x", home: "/"), "/var/log/x")
        XCTAssertTrue(HangReport.scrub("/Users/someone/x", home: "/Users/someone/").contains("~/x"))
    }

    // MARK: - What the user reads and sends

    func testTheAlertSaysHowLongInWords() {
        XCTAssertEqual(report(duration: 12.4).alertMessage, "Kannu froze for 12 seconds last time it ran.")
        XCTAssertEqual(HangReport.spokenDuration(0.2), "1 second")
        XCTAssertEqual(HangReport.spokenDuration(1), "1 second")
        XCTAssertEqual(HangReport.spokenDuration(59.4), "59 seconds")
        XCTAssertEqual(HangReport.spokenDuration(60), "1 minute")
        XCTAssertEqual(HangReport.spokenDuration(125), "2 minutes 5 seconds")
        XCTAssertEqual(HangReport.spokenDuration(121), "2 minutes 1 second")
    }

    func testTheIssueCarriesTheBuildAndTheStackAndNoIdentifiers() throws {
        let url = try XCTUnwrap(report().issueURL(repository: "libinmv/kannu"))
        XCTAssertEqual(url.host, "github.com")
        XCTAssertTrue(url.path.hasSuffix("/libinmv/kannu/issues/new"))

        let body = report().issueBody
        XCTAssertTrue(body.contains("1.3.0 (3)"))
        XCTAssertTrue(body.contains("Version 15.6 (Build 24G84)"))
        XCTAssertTrue(body.contains("arm64"))
        XCTAssertTrue(body.contains("-[NSApplication run] + 464"))
        XCTAssertFalse(body.lowercased().contains("/users/"))
    }

    /// The bug this test exists for: `URLComponents` leaves `+` alone (RFC 3986 allows it in a
    /// query), and GitHub — like every form-urlencoded reader — decodes `+` as a space. Without the
    /// substitution every `symbol + 124` frame arrives as `symbol   124`.
    ///
    /// Decoded the way a form reader does, not the way `URLComponents` does: Foundation's own parser
    /// leaves `+` intact, so a round trip through it would pass while the real thing was broken.
    func testTheStackSurvivesFormDecodingOnTheOtherEnd() throws {
        let url = try XCTUnwrap(report().issueURL(repository: "libinmv/kannu"))
        let body = try XCTUnwrap(
            (url.query ?? "")
                .split(separator: "&")
                .first { $0.hasPrefix("body=") }
                .map { String($0.dropFirst("body=".count)) }
        )
        let formDecoded = try XCTUnwrap(
            body.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        )
        XCTAssertTrue(formDecoded.contains("-[NSApplication run] + 464"), "got: \(formDecoded)")
        XCTAssertFalse(formDecoded.contains("run]   464"), "the offset separator was eaten")
    }

    /// GitHub refuses a very long URL, so a deep stack is trimmed rather than dropped — and the
    /// frames nearest the wedge, which are the ones worth reading, are the ones kept.
    func testALongStackIsTrimmedFromTheBottom() {
        let deep = (0..<400).map { "\($0)  Kannu  $s5Kannu8veryLongSymbolNameForPaddingyyF + \($0)" }
        let body = report(frames: deep).issueBody
        XCTAssertLessThanOrEqual(body.count, HangReport.issueBodyLimit)
        XCTAssertTrue(body.contains("0  Kannu"), "The innermost frames must survive the trim.")
        XCTAssertTrue(body.contains("… trimmed"))
        XCTAssertFalse(body.contains("399  Kannu"))
    }

    /// The raw-length budget is not what has to fit — the percent-encoded URL is. A stack big enough
    /// to blow past that falls back to a body that names the log file instead of failing to open.
    func testAnEnormousStackStillProducesAnOpenableURL() throws {
        var huge = report()
        huge.frames = (0..<4000).map { "\($0)  Kannu  $s5Kannu28aRatherLongMangledSymbolNameyyF + \($0)" }
        let url = try XCTUnwrap(huge.issueURL(repository: "libinmv/kannu"))
        XCTAssertLessThanOrEqual(url.absoluteString.count, HangReport.issueURLLimit)
        XCTAssertTrue(url.absoluteString.contains("issues/new"))
    }

    func testAStacklessReportSaysSoRatherThanLookingEmpty() {
        let body = report(frames: []).issueBody
        XCTAssertTrue(body.contains("could not read the main thread's stack"))
        XCTAssertTrue(body.contains("Frozen for"))
    }
}
