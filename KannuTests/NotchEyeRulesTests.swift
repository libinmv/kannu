//
//  NotchEyeRulesTests.swift
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

/// Show / Hide Notch's eye plays in the notch windows on AppDelegate's clock. The rules that keep
/// it safe live in AppKit and SwiftUI code this logic-only target cannot run, so they are pinned in
/// the source, the way `NotchToggleRulesTests` pins the switch:
///
/// - one writer: only `AppDelegate` moves the eye, so no view can start, stop or strand it;
/// - a hide re-checks the switch after its wait, cancels the run before it, closes every display's
///   notch, honours Reduce Motion, and never fades the window itself (entry 20) or touches its
///   mouse handling (entry 18);
/// - a lock settles it at once, before the windows are ordered out;
/// - launch never plays it;
/// - nothing opens or hovers the notch while it plays, and it takes the closed notch first;
/// - the view runs no clock of its own.
final class NotchEyeRulesTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let writerPattern = #"\bnotchEye(\.\w+)?\s*=[^=]"#

    func testOnlyTheAppDelegateMovesTheEye() throws {
        let sources = try FileManager.default.subpathsOfDirectory(atPath: Self.repoRoot.appendingPathComponent("Kannu").path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(sources.count, 100, "the scan is looking at the wrong tree")
        var writers: [String] = []
        for path in sources {
            let text = NotchTeardownRulesTests.code(try Self.source("Kannu/\(path)"))
            if !Self.writes(in: text).isEmpty { writers.append(path) }
        }
        XCTAssertEqual(writers, ["KannuApp.swift"], "only AppDelegate.applyNotchVisibility and its helpers move the eye")
    }

    func testTheWriterScanSeesAPlantedOffender() {
        XCTAssertEqual(Self.writes(in: "coordinator.notchEye.progress = 0\n").count, 1)
        XCTAssertEqual(Self.writes(in: "coordinator.notchEye = .settled\n").count, 1)
        XCTAssertEqual(Self.writes(in: "if coordinator.notchEye == .settled {}\n").count, 0)
        XCTAssertEqual(Self.writes(in: "@Published var notchEye = NotchEyeState.settled\n").count, 0)
    }

    func testTheSwitchKeepsItsRules() throws {
        let app = try Self.source("Kannu/KannuApp.swift")
        let apply = try Self.body("applyNotchVisibility", in: app)
        for rule in ["accessibilityDisplayShouldReduceMotion", "viewModels.values", "!Defaults[.showNotch]",
                     "notchEyeTask?.cancel()", "syncStatusItem(visible: isStatusItemNeeded)"] {
            XCTAssertTrue(apply.contains(rule), "applyNotchVisibility lost \(rule)")
        }
        // An open notch hidden with no eye still draws closed once before its window goes, so the
        // open tab's views get their `.onDisappear` (the typed search's key monitor leaked otherwise).
        let unanimatedOpen = try XCTUnwrap(apply.range(of: "} else if wasOpen, animated {"),
                                           "an open notch hidden with no eye is torn down mid-open")
        XCTAssertTrue(apply[unanimatedOpen.upperBound...].prefix(400).contains("Task.sleep"))
        let run = try Self.body("runNotchEye", in: app)
        XCTAssertTrue(run.contains("guard !Task.isCancelled"), "a cancelled run still finishes")
        for body in [apply, run] {
            XCTAssertFalse(body.contains("alphaValue"), "the eye fades the window itself; an alpha-0 notch reads as unseen (entry 20)")
            XCTAssertFalse(body.contains("ignoresMouseEvents"), "the eye changes the window's mouse handling (entry 18)")
        }
    }

    func testALockSettlesTheEyeBeforeOrderingOut() throws {
        let locked = try Self.body("onScreenLocked", in: try Self.source("Kannu/KannuApp.swift"))
        let settle = try XCTUnwrap(locked.range(of: "applyNotchVisibility(Defaults[.showNotch], animated: false)"),
                                   "a lock leaves the eye playing into ordered-out windows")
        let orderOut = try XCTUnwrap(locked.range(of: "hideWindowsForLock()"))
        XCTAssertLessThan(settle.lowerBound, orderOut.lowerBound)
    }

    /// The publisher fires on subscribe without `options: []`, and the eye would play at launch.
    func testLaunchNeverPlaysTheEye() throws {
        let app = try Self.source("Kannu/KannuApp.swift")
        XCTAssertTrue(NotchTeardownRulesTests.code(app).contains("Defaults.publisher(.showNotch, options: [])"))
        let launch = try Self.body("continueLaunch", in: app)
        XCTAssertEqual(launch.components(separatedBy: "applyNotchVisibility(").count - 1, 1,
                       "continueLaunch shows or hides the notch outside the switch's sink")
        XCTAssertFalse(launch.contains("notchEye"), "continueLaunch touches the eye")
    }

    func testNothingOpensOrHoversWhileTheEyePlays() throws {
        let gate = "!coordinator.notchEye.isAnimating"
        let model = try Self.source("Kannu/models/KannuViewModel.swift")
        XCTAssertTrue(try Self.body("open", in: model).contains("guard \(gate)"), "the notch opens over the eye")
        let content = try Self.source("Kannu/ContentView.swift")
        for name in ["handleHover", "handleRegionHoverOpen", "shouldShowMusicControlWindow"] {
            XCTAssertTrue(try Self.body(name, in: content).contains(gate), "\(name) ignores the eye")
        }
        // The Clipboard popover and tab and the Screen Assistant popover open the notch and then act
        // on it; with the open refused they posted to a notch still closed (CodeRabbit, #133).
        let shortcuts = try Self.body("registerOptionalShortcutHandlers", in: try Self.source("Kannu/KannuApp.swift"))
        XCTAssertEqual(shortcuts.components(separatedBy: "guard Defaults[.showNotch], \(gate) else { return }").count - 1, 3,
                       "a notch-backed shortcut acts while the eye plays")
    }

    /// Three things the eye must not leave behind: an island parked off-screen, where the eye
    /// would play unseen; a toggle's 3 s auto-close armed for an open that was refused; and
    /// pointer following removed by a hide that a show then reversed on the same windows.
    func testTheEyeIsSeenAndLeavesNothingBehind() throws {
        let content = NotchTeardownRulesTests.code(try Self.source("Kannu/ContentView.swift"))
        let hideUntilHover = try XCTUnwrap(Self.block(after: "private var shouldHideUntilHover: Bool", in: content),
                                           "shouldHideUntilHover went away — move this pin")
        XCTAssertTrue(hideUntilHover.contains("!coordinator.notchEye.isAnimating"),
                      "a hide-until-hover island stays off-screen while the eye plays")

        let app = try Self.source("Kannu/KannuApp.swift")
        XCTAssertTrue(try Self.body("toggleNotch", in: app).contains("!coordinator.notchEye.isAnimating"),
                      "toggleNotch arms its auto-close while the eye refuses the open")
        let apply = try Self.body("applyNotchVisibility", in: app)
        let pointer = try XCTUnwrap(apply.range(of: "syncPointerTracking()", options: .backwards))
        let status = try XCTUnwrap(apply.range(of: "syncStatusItem(visible: isStatusItemNeeded)", options: .backwards))
        XCTAssertLessThan(pointer.lowerBound, status.lowerBound)
        XCTAssertFalse(apply[pointer.upperBound..<status.lowerBound].contains("}"),
                       "pointer tracking is not resynced on every path, a reversal included")
    }

    /// Right after the hello, before every live activity and HUD.
    func testTheEyeTakesTheClosedNotchFirst() throws {
        let content = NotchTeardownRulesTests.code(try Self.source("Kannu/ContentView.swift"))
        let hello = try XCTUnwrap(content.range(of: "HelloAnimation()"), "the hello went away — move this pin")
        let branch = try XCTUnwrap(content.range(of: "} else if", range: hello.upperBound..<content.endIndex))
        let line = content[branch.lowerBound...].prefix { $0 != "\n" }
        XCTAssertTrue(line.contains("playsNotchEyeHere"), "the eye is not the closed notch's first branch: \(line)")
        XCTAssertTrue(content.contains("NotchEyeView("), "the closed notch's body never draws the eye")
    }

    func testTheEyeRunsNoClockOfItsOwn() throws {
        let view = NotchTeardownRulesTests.code(try Self.source("Kannu/components/Notch/NotchEyeRevealView.swift"))
        for clock in ["TimelineView", "repeatForever", ".onAppear", "withAnimation", ".task", "Timer"] {
            XCTAssertFalse(view.contains(clock), "the eye's view runs \(clock); AppDelegate's run is its only clock")
        }
    }

    private static func writes(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: writerPattern)
        return text.components(separatedBy: "\n").filter { line in
            !line.contains("var notchEye")
                && regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
    }

    /// From the first `{` after `marker` to the brace that closes it.
    private static func block(after marker: String, in text: String) -> String? {
        guard let start = text.range(of: marker),
              let open = text[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 { return String(text[open...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func body(_ name: String, in text: String) throws -> String {
        NotchTeardownRulesTests.code(try XCTUnwrap(NotchTeardownRulesTests.body(ofFunction: name, in: text),
                                                   "\(name) went away — move this pin to whatever replaced it"))
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }
}
