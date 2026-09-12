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

/// Reads macOS's own diagnostics about Kannu and proves that what a user would send carries the
/// failure and not their identity.
///
/// The `.cpu_resource.diag` fixture is a real header from this repository's machine, host name and
/// all, because that is the one field the file name itself leaks. The `.ips` fixture is synthetic:
/// Kannu had produced no crash report on that machine, which is exactly why this reporting exists.
final class CrashReportTests: XCTestCase {

    private let home = "/Users/someone"
    private let host = "Davids-MacBook-Pro"

    // MARK: - Fixtures

    /// A real `cpu_resource.diag` header, verbatim apart from the home folder.
    private let cpuDiagnostic = """
    Date/Time:        2026-09-12 03:35:17.909 +0530
    End time:         2026-09-12 03:38:05.559 +0530
    OS Version:       macOS 26.6.2 (Build 25G83)
    Architecture:     arm64e
    Report Version:   72
    Incident Identifier: 2D7B53EA-D935-4F79-AB2A-ECE57E0797F3
    Share With Devs:  Yes

    Data Source:      Microstackshots
    Shared Cache:     F2E86C53-6052-388B-BA71-5A0C9B569413 slid base address 0x18ecc4000

    Command:          Kannu
    Path:             /Users/someone/Applications/Kannu.app/Contents/MacOS/Kannu
    Identifier:       com.kannu.app.dev
    Version:          1.2.0 (2)
    Is First Party:   No
    Beta Identifier:  7727663C-B371-5813-9570-A6312D090DF8
    Resource Coalition: "com.kannu.app.dev"(18177)
    Architecture:     arm64
    Parent:           UNKNOWN [1]
    PID:              87306

    Event:            cpu usage
    Action taken:     none
    CPU:              90 seconds cpu time over 168 seconds (54% cpu average), exceeding limit of 50%

    Powerstats for:   Kannu
    Start time:       2026-09-12 03:35:17 +0530
    Microstackshots:  168 samples
      1000 Thread_1234   DispatchQueue_1: com.apple.main-thread
        1000 start + 6992 (dyld + 12345) [0x18ecc4000]
    """

    private var cpuDiagnosticName: String { "Kannu_2026-09-12-033808_\(host).cpu_resource.diag" }

    private let ipsHeader = """
    {"app_name":"Kannu","timestamp":"2026-09-12 21:04:11.00 +0530","app_version":"1.3.0",\
    "slice_uuid":"aaaa","build_version":"3","platform":1,"bundleID":"com.kannu.app",\
    "share_with_app_devs":1,"is_first_party":0,"bug_type":"309","os_version":"macOS 15.6 (24G84)",\
    "roots_installed":0,"name":"Kannu","incident_id":"BEEF-1234"}
    """

    private var ipsBody: String {
        """
        {"uptime":420,"procRole":"Background","version":2,"userID":501,"modelCode":"MacBookPro18,3",
         "coalitionID":1234,"osVersion":{"train":"macOS 15.6","build":"24G84","releaseType":"User"},
         "captureTime":"2026-09-12 21:04:11.1234 +0530","pid":4242,"cpuType":"ARM-64",
         "procName":"Kannu","procPath":"/Users/someone/Applications/Kannu.app/Contents/MacOS/Kannu",
         "bundleInfo":{"CFBundleShortVersionString":"1.3.0","CFBundleVersion":"3","CFBundleIdentifier":"com.kannu.app"},
         "coalitionName":"com.kannu.app","crashReporterKey":"SECRET-MACHINE-KEY",
         "exception":{"type":"EXC_CRASH","signal":"SIGABRT","codes":"0x0, 0x0"},
         "termination":{"flags":0,"code":6,"namespace":"SIGNAL","indicator":"Abort trap: 6","byProc":"Kannu"},
         "asi":{"libsystem_c.dylib":["abort() called"]},
         "faultingThread":1,
         "threads":[
           {"id":1,"queue":"com.apple.somequeue","frames":[{"imageOffset":1,"symbol":"idle","symbolLocation":0,"imageIndex":0}]},
           {"triggered":true,"id":2,"queue":"com.apple.main-thread","frames":[
             {"imageOffset":100,"symbol":"__pthread_kill","symbolLocation":8,"imageIndex":0},
             {"imageOffset":200,"symbol":"-[NSSavePanel runModal]","symbolLocation":124,"imageIndex":1},
             {"imageOffset":300,"imageIndex":2}]}],
         "usedImages":[
           {"name":"libsystem_kernel.dylib","path":"/usr/lib/system/libsystem_kernel.dylib"},
           {"name":"AppKit","path":"/System/Library/Frameworks/AppKit.framework/AppKit"},
           {"name":"Kannu","path":"/Users/someone/Applications/Kannu.app/Contents/MacOS/Kannu"}]}
        """
    }

    private func parseIPS() -> CrashReport? {
        CrashReport.parse(
            fileName: "Kannu_2026-09-12-210411_\(host).ips",
            contents: ipsHeader + "\n" + ipsBody,
            home: home,
            hostName: host
        )
    }

    private func parseCPU() -> CrashReport? {
        CrashReport.parse(fileName: cpuDiagnosticName, contents: cpuDiagnostic, home: home, hostName: host)
    }

    // MARK: - Which files are ours

    func testOnlyThisAppsDiagnosticsAreRead() {
        XCTAssertTrue(CrashReport.isDiagnostic(fileName: cpuDiagnosticName))
        XCTAssertTrue(CrashReport.isDiagnostic(fileName: "Kannu_2026-09-12-210411_host.ips"))
        XCTAssertTrue(CrashReport.isDiagnostic(fileName: "Kannu_2026-09-12-210411_host.hang"))
        XCTAssertFalse(CrashReport.isDiagnostic(fileName: "Google Chrome_2026-09-12_host.diag"))
        XCTAssertFalse(CrashReport.isDiagnostic(fileName: "JetsamEvent-2026-09-12-130606.ips"))
        // The extension macOS stopped writing in macOS 12 — the filter that found nothing.
        XCTAssertFalse(CrashReport.isDiagnostic(fileName: "Kannu_2019-01-01_host.crash"))
    }

    // MARK: - A crash

    func testACrashCarriesTheFailureAndTheCrashingThread() throws {
        let report = try XCTUnwrap(parseIPS())
        XCTAssertEqual(report.kind, .crash)
        XCTAssertEqual(report.appVersion, "1.3.0")
        XCTAssertEqual(report.buildNumber, "3")
        XCTAssertEqual(report.systemVersion, "macOS 15.6 (24G84)")
        XCTAssertEqual(report.architecture, "ARM-64")
        XCTAssertEqual(report.modelCode, "MacBookPro18,3")
        XCTAssertEqual(report.summary, "EXC_CRASH (SIGABRT) · Abort trap: 6")
        XCTAssertEqual(report.messages, ["libsystem_c.dylib: abort() called"])
    }

    /// `faultingThread` is an index, and taking the wrong one reports an idle thread as the cause.
    func testTheCrashingThreadIsTheOneReported() throws {
        let report = try XCTUnwrap(parseIPS())
        XCTAssertEqual(report.frames.count, 3)
        XCTAssertEqual(report.frames[0], "0  libsystem_kernel.dylib  __pthread_kill + 8")
        XCTAssertEqual(report.frames[1], "1  AppKit  -[NSSavePanel runModal] + 124")
        XCTAssertFalse(report.frames.contains { $0.contains("idle") })
    }

    /// A frame with no symbol still has to say which image it was in.
    func testAnUnsymbolisedFrameKeepsItsImage() throws {
        let report = try XCTUnwrap(parseIPS())
        XCTAssertEqual(report.frames[2], "2  Kannu  + 300")
    }

    // MARK: - A CPU report

    func testACPUReportSummarisesAsACPUTermination() throws {
        let report = try XCTUnwrap(parseCPU())
        XCTAssertEqual(report.kind, .cpuLimit)
        XCTAssertEqual(report.appVersion, "1.2.0")
        XCTAssertEqual(report.buildNumber, "2")
        XCTAssertEqual(report.systemVersion, "macOS 26.6.2 (Build 25G83)")
        XCTAssertTrue(report.summary.contains("cpu usage"))
        XCTAssertTrue(report.summary.contains("54% cpu average"))
        XCTAssertEqual(report.frames, [], "The microstackshot body must never be published.")
    }

    /// The header is `Architecture: arm64e` then `Architecture: arm64`. First wins, deterministically.
    func testARepeatedHeaderKeyTakesItsFirstValue() throws {
        XCTAssertEqual(try XCTUnwrap(parseCPU()).architecture, "arm64e")
    }

    // MARK: - What must not leave the Mac

    func testNoMachineOrUserIdentifierSurvives() throws {
        for report in [try XCTUnwrap(parseIPS()), try XCTUnwrap(parseCPU())] {
            let body = report.issueBody
            XCTAssertFalse(body.contains(host), "the host name is in every diagnostic's file name")
            XCTAssertFalse(body.contains("Davids"))
            XCTAssertFalse(body.lowercased().contains("/users/someone"))
            XCTAssertFalse(body.contains("SECRET-MACHINE-KEY"), "crashReporterKey identifies the Mac")
            XCTAssertFalse(body.contains("7727663C"), "Beta Identifier identifies the Mac")
            XCTAssertFalse(body.contains("Resource Coalition"))
            XCTAssertFalse(body.contains("18177"))
            XCTAssertFalse(body.contains("userID"))
            XCTAssertFalse(body.contains("501"))
        }
    }

    /// The file name is shown to the user, so it must be scrubbed in the field too, not only in the
    /// body that happens to contain it.
    func testTheDiagnosticsOwnNameIsScrubbed() throws {
        XCTAssertEqual(
            try XCTUnwrap(parseCPU()).sourceName,
            "Kannu_2026-09-12-033808_this-mac.cpu_resource.diag"
        )
    }

    func testTheIssueKeepsWhatAMaintainerNeeds() throws {
        let body = try XCTUnwrap(parseIPS()).issueBody
        XCTAssertTrue(body.contains("1.3.0 (3)"))
        XCTAssertTrue(body.contains("macOS 15.6 (24G84)"))
        XCTAssertTrue(body.contains("MacBookPro18,3"))
        XCTAssertTrue(body.contains("abort() called"))
        XCTAssertTrue(body.contains("-[NSSavePanel runModal] + 124"))
    }

    // MARK: - Refusal

    func testATruncatedOrForeignReportYieldsNilRatherThanHalfAReport() {
        XCTAssertNil(CrashReport.parse(fileName: "Kannu_x.ips", contents: "", home: home, hostName: host))
        XCTAssertNil(CrashReport.parse(fileName: "Kannu_x.ips", contents: ipsHeader, home: home, hostName: host))
        XCTAssertNil(CrashReport.parse(fileName: "Kannu_x.ips", contents: "not json\nnot json either", home: home, hostName: host))
        XCTAssertNil(CrashReport.parse(fileName: "Kannu_x.cpu_resource.diag", contents: "nothing useful", home: home, hostName: host))
    }

    /// A `.ips` whose body is valid JSON but missing every field must still produce something
    /// sendable rather than crashing or lying.
    func testASparseCrashReportStillSaysWhatItKnows() throws {
        let report = try XCTUnwrap(CrashReport.parse(
            fileName: "Kannu_x.ips",
            contents: ipsHeader + "\n{}",
            home: home,
            hostName: host
        ))
        XCTAssertEqual(report.appVersion, "unknown")
        XCTAssertEqual(report.summary, "unknown failure")
        XCTAssertEqual(report.frames, [])
        XCTAssertTrue(report.issueBody.contains("No stack was available"))
    }

    func testALongStackIsTrimmedRatherThanBreakingTheURL() throws {
        var report = try XCTUnwrap(parseIPS())
        report.frames = (0..<400).map { "\($0)  Kannu  $s5Kannu22aVeryLongSymbolNameHereyyF + \($0)" }
        XCTAssertLessThanOrEqual(report.issueBody.count, CrashReport.issueBodyLimit)
        XCTAssertTrue(report.issueBody.contains("0  Kannu"))
        XCTAssertTrue(report.issueBody.contains("… trimmed"))
    }

    func testTheIssueURLIsWellFormed() throws {
        let url = try XCTUnwrap(try XCTUnwrap(parseIPS()).issueURL(repository: "libinmv/kannu"))
        XCTAssertEqual(url.host, "github.com")
        XCTAssertTrue(url.path.hasSuffix("/libinmv/kannu/issues/new"))
        XCTAssertTrue(url.query?.contains("labels=crash") == true)
    }

    // MARK: - The scrubber itself

    func testTheScrubberHandlesTheOrderThatMatters() {
        // A home folder often contains the host name, so paths go first and the host name second.
        let text = "/Users/Davids-MacBook-Pro/Library/Logs on Davids-MacBook-Pro"
        let scrubbed = DiagnosticScrub.everything(in: text, home: "/Users/Davids-MacBook-Pro", hostName: host)
        XCTAssertFalse(scrubbed.contains("Davids"))
    }

    /// A two-character computer name would otherwise replace half the alphabet.
    func testAnAbsurdlyShortHostNameIsIgnored() {
        XCTAssertEqual(DiagnosticScrub.hostName("a", in: "a stack frame"), "a stack frame")
    }
}
