//
//  LaunchGateRulesTests.swift
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

/// Kannu does nothing before the Terms of Use are accepted.
///
/// It used to act the instant it launched: the delegate's eager singletons spawned the
/// `mediaremote-adapter.pl` and `log stream` children and could raise the Bluetooth and ~/Downloads
/// permission prompts before any window existed, and the launch wrote agent hooks into `~/.claude` and
/// `~/.cursor` on first run — all before anyone could have agreed to anything. None of that is
/// testable at runtime here (it is AppKit launch order), so it is pinned in the source, the way
/// `ModalPresentationRulesTests` pins the modal ban.
final class LaunchGateRulesTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The delegate properties that used to be built eagerly. Each one starts work when constructed.
    private static let heldSingletons = [
        "vm", "dndManager", "bluetoothAudioManager", "idleAnimationManager", "downloadManager",
        "lockScreenPanelManager", "mediaControlsStateCoordinator", "systemTimerBridge",
        "extensionXPCServiceHost", "extensionRPCServer",
    ]

    func testTheLaunchDecidesOnTheTermsBeforeContinuing() throws {
        let launch = try XCTUnwrap(Self.body(ofFunction: "applicationDidFinishLaunching", in: try Self.appDelegate()),
                                   "applicationDidFinishLaunching went away — this pin is vacuous")
        let check = try XCTUnwrap(launch.range(of: "TermsOfUse.isAccepted(")?.lowerBound,
                                  "the launch no longer checks the Terms of Use")
        let proceed = try XCTUnwrap(launch.range(of: "continueLaunch()")?.lowerBound,
                                    "the launch never continues")
        XCTAssertLessThan(check, proceed, "continueLaunch() runs before the terms are checked")
        XCTAssertTrue(launch.contains("TermsGateWindowController.shared.show"),
                      "an unaccepted launch no longer shows the gate")
        XCTAssertEqual(Self.occurrences(of: "continueLaunch()", in: Self.code(launch)), 2,
                       "expected exactly the accepted path and the gate's callback")
    }

    /// The pre-gate part of the launch may start only the invariants. Anything that installs hooks,
    /// starts a monitor or builds a window belongs in `continueLaunch()`.
    func testNothingElseStartsBeforeTheGate() throws {
        let source = try Self.appDelegate()
        let launch = Self.code(try XCTUnwrap(Self.body(ofFunction: "applicationDidFinishLaunching", in: source)))
        let invariants = Self.code(try XCTUnwrap(Self.body(ofFunction: "startLaunchInvariants", in: source)))
        let preGate = launch + invariants
        for forbidden in ["AgentHookInstaller", "CursorAgentStatusMonitor", "ClaudeCloudRelayManager", "SecurityFindingsStore",
                          "createKannuWindow", "adjustWindowPosition", "syncStatusItem",
                          "autoEnableLaunchAtLogin", "showOnboardingWindow", "LockScreenWeatherManager",
                          "SystemHUDManager", "configureProviderDefaultsIfNeeded", "installTopMenuItems"] {
            XCTAssertFalse(preGate.contains(forbidden), "\(forbidden) now runs before the Terms of Use are accepted")
        }
        for allowed in ["HangWatchdog.shared.start()", "CrashReporter.shared.start()",
                        "SparkleUpdaterController.shared.configure()", "MediaRemoteAdapterReaper"] {
            XCTAssertTrue(invariants.contains(allowed), "\(allowed) no longer runs whatever the user decides")
        }
    }

    func testTheEagerSingletonsStayLazy() throws {
        let source = try Self.appDelegate()
        for name in Self.heldSingletons {
            XCTAssertTrue(source.contains("lazy var \(name)"),
                          "\(name) is no longer lazy — constructing it at init starts work before the terms")
            XCTAssertFalse(source.contains("    let \(name) "),
                           "\(name) is a stored let again — it is built before the gate")
        }
        // continueLaunch touches every one, so they all still start at launch once accepted.
        let proceed = Self.code(try XCTUnwrap(Self.body(ofFunction: "continueLaunch", in: source)))
        for name in Self.heldSingletons {
            XCTAssertTrue(proceed.contains("_ = \(name)\n"), "continueLaunch no longer starts \(name)")
        }
    }

    /// The App struct runs before the delegate; it must not do work of its own.
    func testTheAppStructDoesNoWorkAtInit() throws {
        let source = try Self.appDelegate()
        let appStruct = try XCTUnwrap(source.range(of: "struct KannuApp: App {"))
        let delegateClass = try XCTUnwrap(source.range(of: "class AppDelegate:"))
        let head = String(source[appStruct.lowerBound..<delegateClass.lowerBound])
        XCTAssertFalse(Self.code(head).contains("init() {"), "KannuApp has an init again — it runs before the gate")
    }

    func testTheLegalDocumentsShipInsideTheApp() throws {
        let project = try String(contentsOf: Self.repoRoot.appendingPathComponent("Kannu.xcodeproj/project.pbxproj"),
                                 encoding: .utf8)
        XCTAssertTrue(project.contains("mediaremote-adapter.pl in Resources */,"),
                      "the Resources phase scan found nothing — check the anchor, not the rule")
        for file in ["TERMS.md", "LICENSE", "NOTICE"] {
            XCTAssertTrue(project.contains("/* \(file) in Resources */,"),
                          "\(file) is no longer copied into Kannu.app — the gate and About would have nothing to show")
            XCTAssertTrue(project.contains("path = \(file); sourceTree = SOURCE_ROOT;"),
                          "\(file) no longer points at the repo-root copy — a second copy would drift")
        }
    }

    /// A file opened with Kannu while the terms are up waits for acceptance instead of vanishing
    /// (CodeRabbit on #65: the first version of the gate dropped it, and Accept never replayed it).
    func testFilesOpenedBeforeAcceptanceWaitAndReachTheShelf() throws {
        let source = try Self.appDelegate()
        for handler in ["application(_ application: NSApplication, open urls", "application(_ sender: NSApplication, openFile"] {
            let start = try XCTUnwrap(source.range(of: "func \(handler)"), "\(handler) went away")
            let body = Self.code(String(source[start.upperBound...].prefix(600)))
            XCTAssertTrue(body.contains("shelfURLsAwaitingAcceptance.append"),
                          "\(handler) drops a file opened before the terms are accepted")
        }
        let proceed = Self.code(try XCTUnwrap(Self.body(ofFunction: "continueLaunch", in: source)))
        XCTAssertTrue(proceed.contains("handleIncomingShelfURLs(waiting)"),
                      "continueLaunch no longer hands the waiting files to the shelf")
    }

    // MARK: - The scanner is not vacuous

    func testTheScannerSeesAPlantedOffender() {
        let planted = """
            func applicationDidFinishLaunching(_ notification: Notification) {
                AgentHookInstaller.shared.install(.claude)
                continueLaunch()
            }

            private func other() {}
            """
        let body = Self.code(Self.body(ofFunction: "applicationDidFinishLaunching", in: planted) ?? "")
        XCTAssertTrue(body.contains("AgentHookInstaller"))
        XCTAssertNil(body.range(of: "TermsOfUse.isAccepted("))
        // Prose about a forbidden call is not the call.
        XCTAssertFalse(Self.code("    // AgentHookInstaller used to run here\n").contains("AgentHookInstaller"))
    }

    // MARK: - Helpers

    private static func appDelegate() throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("Kannu/KannuApp.swift"), encoding: .utf8)
    }

    /// A function's body: from its declaration to the next member declaration at the same indent.
    private static func body(ofFunction name: String, in text: String) -> String? {
        guard let start = text.range(of: "func \(name)(") else { return nil }
        let rest = text[start.upperBound...]
        let candidates = ["\n    private func ", "\n    func ", "\n    @objc func ",
                          "\n    @objc private func ", "\n    /// "]
        let end = candidates.compactMap { rest.range(of: $0)?.lowerBound }.min()
        guard let end else { return String(rest) }
        return String(rest[..<end])
    }

    /// Source with comment lines dropped, so prose about a rule never trips it.
    private static func code(_ text: String) -> String {
        text.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("/*")
        }.joined(separator: "\n") + "\n"
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
