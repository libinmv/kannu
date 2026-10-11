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
        for forbidden in ["AgentHookInstaller", "CursorAgentStatusMonitor", "SecurityFindingsStore",
                          "createKannuWindow", "adjustWindowPosition", "syncStatusItem",
                          "autoEnableLaunchAtLogin", "showOnboardingWindow", "LockScreenWeatherManager",
                          "SystemHUDManager", "configureProviderDefaultsIfNeeded", "installTopMenuItems",
                          "UNUserNotificationCenter", "requestAuthorization", "TasksManager", "TaskFileStore",
                          "launchDidContinue"] {
            XCTAssertFalse(preGate.contains(forbidden), "\(forbidden) now runs before the Terms of Use are accepted")
        }
        // The one exception, a delegate that asks nothing: testTheReminderDelegateIsInstalledBeforeTheGate.
        XCTAssertTrue(preGate.contains("TaskReminderCenter.shared.install()"),
                      "the reminder delegate is no longer set before the gate: a click that launches Kannu is lost")
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

    /// A task reminder clicked while Kannu is not running launches it, and macOS hands the click to
    /// the delegate set by the time `applicationDidFinishLaunching` returns — so the delegate is the
    /// one thing installed before the gate (CodeRabbit on #86: installed in `continueLaunch()`, it
    /// missed that click). Installing it asks nothing, reads no file and builds nothing; the click
    /// waits in `TaskReminderCenter` until `continueLaunch()` has run, and is answered last. The
    /// permission prompt still belongs to the user's first schedule (`TaskListRulesTests`), and
    /// `TasksManager` stays lazy.
    func testTheReminderDelegateIsInstalledBeforeTheGate() throws {
        XCTAssertEqual(Self.reminderProblems(appDelegate: try Self.appDelegate(), reminders: try Self.reminders()), [])
    }

    func testTheReminderScannerSeesPlantedOffenders() throws {
        let delegate = try Self.appDelegate()
        let reminders = try Self.reminders()
        let install = "        TaskReminderCenter.shared.install()\n"
        let drain = "        TaskReminderCenter.shared.launchDidContinue()\n"
        let setDelegate = "        center.delegate = self\n"
        // Installed in continueLaunch again: the click that launched Kannu is lost.
        let late = delegate.replacingOccurrences(of: install, with: "").replacingOccurrences(of: drain, with: install + drain)
        XCTAssertEqual(Self.reminderProblems(appDelegate: late, reminders: reminders),
                       ["the reminder delegate is not installed before the Terms of Use are checked"])
        // The pre-gate install grew teeth.
        let asks = delegate.replacingOccurrences(of: install, with: install + "        Task { _ = await TaskReminders.requestPermission() }\n")
        XCTAssertEqual(Self.reminderProblems(appDelegate: asks, reminders: reminders), ["the launch asks for notifications"])
        let builds = delegate.replacingOccurrences(of: install, with: install + "        TasksManager.shared.checkReminderPermission()\n")
        XCTAssertEqual(Self.reminderProblems(appDelegate: builds, reminders: reminders),
                       ["the launch builds TasksManager, which reads tasks.json"])
        // install() itself asks, or reads the task file.
        let asking = reminders.replacingOccurrences(of: setDelegate, with: setDelegate + "        Task { _ = await TaskReminders.requestPermission() }\n")
        XCTAssertEqual(Self.reminderProblems(appDelegate: delegate, reminders: asking), ["the launch asks for notifications"])
        let reading = reminders.replacingOccurrences(of: setDelegate, with: setDelegate + "        _ = TasksManager.shared\n")
        XCTAssertEqual(Self.reminderProblems(appDelegate: delegate, reminders: reading),
                       ["the launch builds TasksManager, which reads tasks.json"])
        // A click answered the moment it arrives, or never answered at all.
        let eager = reminders.replacingOccurrences(of: Self.heldUntilLaunch, with: "self.answer(reminder)")
        XCTAssertEqual(Self.reminderProblems(appDelegate: delegate, reminders: eager),
                       ["a reminder's click is answered before the launch continued"])
        let silent = delegate.replacingOccurrences(of: drain, with: "")
        XCTAssertEqual(Self.reminderProblems(appDelegate: silent, reminders: reminders),
                       ["continueLaunch never answers the clicks that waited for it, or not last"])
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

    // MARK: - The reminder delegate rule

    /// The line that holds a click back until the launch continued.
    private static let heldUntilLaunch =
        "if self.launchContinued { self.answer(reminder) } else { self.waiting.append(reminder) }"

    /// The rule as problems: none for the real sources. `install()`, the pre-gate part of the launch
    /// and nothing else may set the delegate; none of them may ask or build `TasksManager`; a click
    /// waits for the launch, which answers it last.
    static func reminderProblems(appDelegate: String, reminders: String) -> [String] {
        var problems: [String] = []
        let launch = code(body(ofFunction: "applicationDidFinishLaunching", in: appDelegate) ?? "")
        let invariants = code(body(ofFunction: "startLaunchInvariants", in: appDelegate) ?? "")
        let proceed = code(body(ofFunction: "continueLaunch", in: appDelegate) ?? "")
        let install = code(body(ofFunction: "install", in: reminders) ?? "")
        let installed = launch.range(of: "TaskReminderCenter.shared.install()")?.lowerBound
        let checked = launch.range(of: "TermsOfUse.isAccepted(")?.lowerBound
        if occurrences(of: "TaskReminderCenter.shared.install()", in: code(appDelegate)) != 1
            || installed == nil || checked == nil || installed! > checked! {
            problems.append("the reminder delegate is not installed before the Terms of Use are checked")
        }
        let preGate = launch + invariants + install
        if preGate.contains("requestAuthorization") || preGate.contains("requestPermission") {
            problems.append("the launch asks for notifications")
        }
        if preGate.contains("TasksManager") || preGate.contains("TaskFileStore") {
            problems.append("the launch builds TasksManager, which reads tasks.json")
        }
        if !code(reminders).contains(heldUntilLaunch) {
            problems.append("a reminder's click is answered before the launch continued")
        }
        let drained = proceed.range(of: "TaskReminderCenter.shared.launchDidContinue()")?.lowerBound
        let shelf = proceed.range(of: "handleIncomingShelfURLs(waiting)")?.lowerBound
        if occurrences(of: "launchDidContinue()", in: code(appDelegate)) != 1
            || drained == nil || shelf == nil || drained! < shelf! {
            problems.append("continueLaunch never answers the clicks that waited for it, or not last")
        }
        return problems
    }

    // MARK: - Helpers

    private static func appDelegate() throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("Kannu/KannuApp.swift"), encoding: .utf8)
    }

    private static func reminders() throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("Kannu/managers/Tasks/TaskReminders.swift"), encoding: .utf8)
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
