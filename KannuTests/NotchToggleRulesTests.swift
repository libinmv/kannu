//
//  NotchToggleRulesTests.swift
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

/// `Defaults[.showNotch]` off tears every notch window down, and the eye's menu is the way back.
/// Kannu has no Dock icon, so an eye that can be off while the notch is hidden locks the user out
/// until they find the defaults key. Every path that would rebuild a window, or open a view model
/// that has none, must check the switch. None of it is reachable in this logic-only target, so the
/// rules are pinned in the source, the way `NotchTeardownRulesTests` pins the teardown.
final class NotchToggleRulesTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testTheEyeStaysWhileTheNotchIsHidden() throws {
        let app = NotchTeardownRulesTests.code(try Self.source("Kannu/KannuApp.swift"))
        XCTAssertTrue(app.contains("Defaults[.menubarIcon] || !Defaults[.showNotch]"),
                      "the status item no longer shows while the notch is hidden — with both off nothing brings Kannu back")
        let calls = app.components(separatedBy: "syncStatusItem(visible: ").dropFirst()
        XCTAssertGreaterThanOrEqual(calls.count, 3, "the scanner stopped seeing the status item syncs; fix the scan, not the rule")
        for call in calls {
            XCTAssertTrue(call.hasPrefix("isStatusItemNeeded") || call.hasPrefix("self.isStatusItemNeeded")
                          || call.hasPrefix("Bool)"),
                          "a syncStatusItem call bypasses isStatusItemNeeded: \(call.prefix(60))")
        }
    }

    func testEveryWindowPathChecksTheSwitch() throws {
        let app = try Self.source("Kannu/KannuApp.swift")
        for name in ["adjustWindowPosition", "applyPlacementChange", "syncPointerTracking", "toggleNotch"] {
            let body = try XCTUnwrap(NotchTeardownRulesTests.body(ofFunction: name, in: app),
                                     "\(name) went away — move this pin to whatever replaced it")
            XCTAssertTrue(NotchTeardownRulesTests.code(body).contains("Defaults[.showNotch]"),
                          "\(name) ignores showNotch — a hidden notch gets a window, a pointer monitor or an opened view model back")
        }
    }

    /// Entry 17's addendum: launch seeds `vm.screen` before anything may bail. Only the window
    /// itself waits on the switch.
    func testLaunchSeedsTheScreenBeforeTheGatedWindow() throws {
        let app = try Self.source("Kannu/KannuApp.swift")
        let launch = NotchTeardownRulesTests.code(try XCTUnwrap(
            NotchTeardownRulesTests.body(ofFunction: "continueLaunch", in: app),
            "continueLaunch went away — this pin is now vacuous, update it"))
        let seed = try XCTUnwrap(launch.range(of: "viewModel.screen = screen.localizedName"), "the launch seed went away")
        let gate = try XCTUnwrap(launch.range(of: "if Defaults[.showNotch] {", range: seed.upperBound..<launch.endIndex),
                                 "launch builds the window without checking showNotch, or checks it before seeding the screen")
        XCTAssertNotNil(launch.range(of: "createKannuWindow(", range: gate.upperBound..<launch.endIndex),
                        "the gated launch window went away")
    }

    /// The notch HUD pauses the native OSD and draws in the notch. A raw read of `enableSystemHUD`
    /// keeps it paused while the notch is hidden, and the volume keys show nothing at all.
    func testTheNotchHUDCountsAsOffWhileTheNotchIsHidden() throws {
        let hud = NotchTeardownRulesTests.code(try Self.source("Kannu/managers/SystemHUDManager.swift"))
        XCTAssertTrue(hud.contains("Defaults[.enableSystemHUD] && Defaults[.showNotch]"),
                      "notchHUDEnabled went away — the hidden notch's HUD keeps the native OSD paused")
        let rawReads = hud.components(separatedBy: "\n").filter {
            $0.contains("Defaults[.enableSystemHUD]")
                && !$0.contains("Defaults[.enableSystemHUD] && Defaults[.showNotch]")
                && !$0.contains("print(")
        }
        XCTAssertEqual(rawReads, [], "SystemHUDManager reads enableSystemHUD directly; use notchHUDEnabled")
    }

    /// The notch hides itself from its header (open, full UI) and its right-click menu (closed,
    /// minimalistic). Both only write the setting: the window they live in is torn down by the
    /// `showNotch` sink a turn later, never from inside their own action.
    func testTheNotchOffersItsOwnHideControl() throws {
        let header = NotchTeardownRulesTests.code(try Self.source("Kannu/components/Notch/KannuHeader.swift"))
        let open = try XCTUnwrap(header.range(of: "if vm.notchState == .open && !enableMinimalisticUI {"),
                                 "the header's open block moved — this pin is vacuous")
        let battery = try XCTUnwrap(header.range(of: "if vm.notchState == .open && showBatteryIndicator {",
                                                 range: open.upperBound..<header.endIndex))
        let buttons = String(header[open.upperBound..<battery.lowerBound])
        XCTAssertTrue(buttons.contains(#"Image(systemName: "eye.slash")"#), "the header lost its Hide Notch button")
        XCTAssertTrue(buttons.contains("Defaults[.showNotch] = false"), "the header's Hide Notch button no longer hides the notch")
        XCTAssertTrue(buttons.contains(#".hoverTooltip(String(localized: "Hide Notch"), edge: .below)"#))
        XCTAssertTrue(buttons.contains(#".accessibilityLabel(String(localized: "Hide Notch"))"#))

        let content = NotchTeardownRulesTests.code(try Self.source("Kannu/ContentView.swift"))
        let menuStart = try XCTUnwrap(content.range(of: ".contextMenu {"), "the notch's right-click menu went away")
        let menu = try XCTUnwrap(Self.block(from: menuStart.lowerBound, in: content))
        XCTAssertTrue(menu.contains(#"Button("Hide Notch") {"#), "the right-click menu lost Hide Notch")
        XCTAssertTrue(menu.contains("Defaults[.showNotch] = false"))

        for (name, text) in [("KannuHeader", header), ("ContentView", content)] {
            XCTAssertFalse(text.contains("applyNotchVisibility") || text.contains("tearDownAllWindows"),
                           "\(name) tears the notch down itself instead of writing showNotch and letting the sink hop")
        }
    }

    /// The eye's menu is the way back, and reopening Kannu is the way back when the eye is pushed
    /// behind the notch. Hiding also drops what lives beside the notch or only feeds it: the timer's
    /// control panel and Stats sampling outlived the window otherwise.
    func testTheWayBackAndTheHidePathHoldTogether() throws {
        let app = try Self.source("Kannu/KannuApp.swift")
        func body(_ name: String) throws -> String {
            NotchTeardownRulesTests.code(try XCTUnwrap(NotchTeardownRulesTests.body(ofFunction: name, in: app),
                                                       "\(name) went away — move this pin to whatever replaced it"))
        }
        let menu = try body("statusItemMenu")
        XCTAssertTrue(menu.contains(#"String(localized: "Show Notch")"#) && menu.contains("#selector(statusMenuToggleNotch)"),
                      "the eye's menu lost Show Notch — a hidden notch has no way back")
        XCTAssertTrue(menu.contains("Defaults[.showNotch] ? .on : .off"))
        XCTAssertTrue(try body("statusItemClicked").contains("|| !Defaults[.showNotch]"),
                      "a plain click on the eye while hidden toggles nothing instead of opening the menu")
        XCTAssertTrue(try body("applicationShouldHandleReopen").contains("Defaults[.showNotch] = true"),
                      "reopening Kannu no longer brings a hidden notch back")

        let apply = try body("applyNotchVisibility")
        for release in ["TimerControlWindowManager.shared.hide(animated: false)", "StatsManager.shared.stopMonitoring()"] {
            XCTAssertTrue(apply.contains(release), "hiding the notch no longer runs \(release)")
        }

        let hud = NotchTeardownRulesTests.code(try Self.source("Kannu/managers/SystemHUDManager.swift"))
        XCTAssertEqual(hud.components(separatedBy: "self.isSetupComplete, self.anyHUDActive").count - 1, 4,
                       "a DDC restart starts the HUD observer, pausing the native OSD, with no HUD to show")
        let lock = NotchTeardownRulesTests.code(try Self.source("Kannu/managers/LockScreenLiveActivityWindowManager.swift"))
        XCTAssertTrue(lock.contains("guard Defaults[.showNotch] else { return nil }"),
                      "the lock screen still shows the notch the user hid")
    }

    /// Showing the notch restarts the HUD observer, and the backlight controller reads its level on
    /// every start. Sent as a change, that read widened the notch into a backlight HUD each time:
    /// the "expands to 2 sides and shows brightness" David saw on Show. The start seeds listeners
    /// only; a HUD comes from a real change.
    func testStartingTheBacklightShowsNoHUD() throws {
        let source = try Self.source("Kannu/managers/SystemKeyboardBacklightController.swift")
        let notify = NotchTeardownRulesTests.code(try XCTUnwrap(NotchTeardownRulesTests.body(ofFunction: "notifyCurrentLevel", in: source),
                                                                "notifyCurrentLevel went away — move this pin"))
        XCTAssertTrue(notify.contains("showsHUD: false"), "the start-time read shows a backlight HUD again")
        let emit = NotchTeardownRulesTests.code(try XCTUnwrap(NotchTeardownRulesTests.body(ofFunction: "emitChange", in: source)))
        XCTAssertTrue(emit.contains("if showsHUD { self.onBacklightChange?(level) }"))
        XCTAssertTrue(emit.contains("keyboardBacklightDidChange"), "the start-time read stopped seeding listeners")
        XCTAssertEqual(NotchTeardownRulesTests.code(source).components(separatedBy: "onBacklightChange?(").count - 1, 1,
                       "a second call reaches the HUD without passing showsHUD")
    }

    /// From the first `{` at or after `start` to the brace that closes it.
    private static func block(from start: String.Index, in text: String) -> String? {
        guard let open = text[start...].firstIndex(of: "{") else { return nil }
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

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }
}
