//
//  HeaderOrderRulesTests.swift
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

/// The notch header's trailing row is right-aligned, so an item that appears pushes only what is to
/// its left. The rule (AGENTS.md, "UI"): buttons that are always there keep fixed positions on the
/// right; buttons and indicators that come and go appear to their left, so a fixed button never
/// moves. `KannuHeader` is a view, not in the logic target, so the order is read from the source
/// (the `TasksPopoverRulesTests` idiom):
///
/// - inside the open, non-minimalistic block, left to right: the screen-recording indicator, the
///   Do Not Disturb indicator, the Usage tab's Refresh button, the Tasks button (they come and go),
///   then the clipboard button, the timer popover button and the Brain button (always there);
/// - the battery block (minimalistic and normal) comes after that block and is last in the row;
/// - the Refresh button shows and hides with a plain fade, driven by an animation on its own gate.
///
/// Each detector has a planted-offender test, so a scanner that stops matching fails instead of
/// passing vacuously.
final class HeaderOrderRulesTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root
    static let headerPath = "Kannu/components/Notch/KannuHeader.swift"

    static let rowMarker = "HStack(spacing: 4) {"
    static let openMarker = "if vm.notchState == .open && !enableMinimalisticUI {"
    static let batteryMarker = "if vm.notchState == .open && showBatteryIndicator {"
    static let refreshMarker = "if coordinator.currentView == .llmUsage {"
    static let refreshAnimation = ".animation(.easeInOut(duration: 0.15), value: coordinator.currentView == .llmUsage)"
    static let batteryViews = ["KannuBatteryView(", "MinimalisticBatteryView("]

    /// Items that come and go, in their left-to-right order.
    static let dynamicItems: [(name: String, marker: String)] = [
        ("the screen-recording indicator", "RecordingIndicator()"),
        ("the Do Not Disturb indicator", "FocusIndicator()"),
        ("the Usage tab's Refresh button", refreshMarker),
        ("the Tasks button", "TasksHeaderButton()"),
    ]
    /// Buttons that are always there (setting-driven), in their left-to-right order.
    static let fixedItems: [(name: String, marker: String)] = [
        ("the clipboard button", #"Image(systemName: "doc.on.clipboard")"#),
        ("the timer popover button", #"Image(systemName: "timer")"#),
        ("the Brain button", #"Image(systemName: "brain")"#),
    ]

    private static func read(_ path: String) throws -> String {
        code(try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8))
    }

    // MARK: - The rules, on the real source

    func testWhatComesAndGoesSitsLeftOfWhatIsAlwaysThere() throws {
        XCTAssertEqual(Self.orderProblems(in: try Self.read(Self.headerPath)), [])
    }

    func testTheRefreshButtonSimplyFades() throws {
        XCTAssertEqual(Self.refreshFadeProblems(in: try Self.read(Self.headerPath)), [])
    }

    // MARK: - The scanners catch planted offenders

    func testTheOrderScannerCatchesPlantedOffenders() {
        XCTAssertEqual(Self.orderProblems(in: Plant.header()), [])

        // The order this test was written against: Tasks first, Refresh after the clipboard, the
        // indicators after Brain.
        let before = Self.orderProblems(in: Plant.header([Plant.tasks, Plant.clipboard, Plant.refresh, Plant.timer,
                                                          Plant.brain, Plant.recording, Plant.dnd]))
        for name in ["the screen-recording indicator", "the Do Not Disturb indicator", "the Usage tab's Refresh button"] {
            XCTAssertTrue(before.contains("\(name) comes and goes but sits right of the clipboard button, which is always there"),
                          "\(name): \(before)")
        }

        XCTAssertEqual(Self.orderProblems(in: Plant.header([Plant.recording, Plant.dnd, Plant.refresh, Plant.clipboard,
                                                            Plant.timer, Plant.brain, Plant.tasks])),
                       ["the Tasks button comes and goes but sits right of the clipboard button, which is always there"])
        XCTAssertEqual(Self.orderProblems(in: Plant.header([Plant.dnd, Plant.recording, Plant.refresh, Plant.tasks,
                                                            Plant.clipboard, Plant.timer, Plant.brain])),
                       ["the screen-recording indicator is not left of the Do Not Disturb indicator"])
        XCTAssertEqual(Self.orderProblems(in: Plant.header([Plant.recording, Plant.dnd, Plant.refresh, Plant.tasks,
                                                            Plant.timer, Plant.clipboard, Plant.brain])),
                       ["the clipboard button is not left of the timer popover button"])

        let withoutRecording = Plant.order.filter { $0 != Plant.recording }
        XCTAssertEqual(Self.orderProblems(in: Plant.header(withoutRecording)),
                       ["the screen-recording indicator is not in the open, non-minimalistic header"])
        XCTAssertEqual(Self.orderProblems(in: Plant.header(withoutRecording, beforeOpen: Plant.recording)),
                       ["the screen-recording indicator is not in the open, non-minimalistic header"])
        XCTAssertEqual(Self.orderProblems(in: Plant.header(Plant.order + [Plant.brain])),
                       ["the Brain button appears more than once"])
        XCTAssertEqual(Self.orderProblems(in: Plant.header(open: "if vm.notchState == .open {")),
                       ["the header has no open, non-minimalistic block"])
    }

    func testTheBatteryScannerCatchesPlantedOffenders() {
        XCTAssertEqual(Self.orderProblems(in: Plant.header(battery: "")), ["the header has no battery block"])
        let lostView = Plant.battery.replacingOccurrences(of: "MinimalisticBatteryView(level: 1)", with: "EmptyView()")
        XCTAssertNotEqual(lostView, Plant.battery, "the plant did not take")
        XCTAssertEqual(Self.orderProblems(in: Plant.header(battery: lostView)),
                       ["the battery block lost MinimalisticBatteryView("])
        XCTAssertEqual(Self.orderProblems(in: Plant.header(afterBattery: #"Text("x")"#)),
                       ["the battery is not last in the row"])
        let first = Self.orderProblems(in: Plant.header(beforeOpen: Plant.battery, battery: ""))
        XCTAssertTrue(first.contains("the battery is not after the open, non-minimalistic header"), "\(first)")
        XCTAssertTrue(first.contains("the battery is not last in the row"), "\(first)")
        let inside = Self.orderProblems(in: Plant.header(Plant.order + [Plant.battery], battery: ""))
        XCTAssertTrue(inside.contains("the battery is not after the open, non-minimalistic header"), "\(inside)")
    }

    func testTheRefreshFadeScannerCatchesPlantedOffenders() {
        XCTAssertEqual(Self.refreshFadeProblems(in: Plant.header()), [])
        let swap: (String) -> [String] = { refresh in
            Plant.order.map { $0 == Plant.refresh ? refresh : $0 }
        }
        let noFade = Plant.refresh.replacingOccurrences(of: ".transition(.opacity)", with: "")
        XCTAssertNotEqual(noFade, Plant.refresh, "the plant did not take")
        XCTAssertEqual(Self.refreshFadeProblems(in: Plant.header(swap(noFade))), ["the Refresh button does not simply fade"])
        let scales = Plant.refresh.replacingOccurrences(of: ".transition(.opacity)", with: ".transition(.scale)")
        XCTAssertEqual(Self.refreshFadeProblems(in: Plant.header(swap(scales))), ["the Refresh button does not simply fade"])
        let still = Plant.header().replacingOccurrences(of: Self.refreshAnimation, with: "")
        XCTAssertNotEqual(still, Plant.header(), "the plant did not take")
        XCTAssertEqual(Self.refreshFadeProblems(in: still), ["the Refresh button's show/hide is not animated"])
        XCTAssertEqual(Self.refreshFadeProblems(in: Plant.header(Plant.order.filter { $0 != Plant.refresh })),
                       ["the header shows no Usage tab Refresh button"])
    }

    // MARK: - Scanners

    /// Every item once, inside the open, non-minimalistic block; what comes and goes left of what is
    /// always there; each group in its own order; the battery block after that block and last in the
    /// row, carrying both battery views.
    static func orderProblems(in header: String) -> [String] {
        guard let open = blockRange(after: openMarker, in: header) else {
            return ["the header has no open, non-minimalistic block"]
        }
        var problems: [String] = []
        var position: [String: String.Index] = [:]
        for item in dynamicItems + fixedItems {
            if header.components(separatedBy: item.marker).count > 2 {
                problems.append("\(item.name) appears more than once")
            }
            if let found = header.range(of: item.marker, range: open) {
                position[item.name] = found.lowerBound
            } else {
                problems.append("\(item.name) is not in the open, non-minimalistic header")
            }
        }
        let placed: ([(name: String, marker: String)]) -> [(name: String, at: String.Index)] = { group in
            group.compactMap { item in position[item.name].map { (name: item.name, at: $0) } }
        }
        let dynamic = placed(dynamicItems)
        if let leftmostFixed = placed(fixedItems).min(by: { $0.at < $1.at }) {
            for item in dynamic where item.at > leftmostFixed.at {
                problems.append("\(item.name) comes and goes but sits right of \(leftmostFixed.name), which is always there")
            }
        }
        for group in [dynamic, placed(fixedItems)] {
            for (left, right) in zip(group, group.dropFirst()) where left.at > right.at {
                problems.append("\(left.name) is not left of \(right.name)")
            }
        }
        problems += batteryProblems(in: header, open: open)
        return problems
    }

    private static func batteryProblems(in header: String, open: Range<String.Index>) -> [String] {
        guard let battery = blockRange(after: batteryMarker, in: header) else { return ["the header has no battery block"] }
        var problems: [String] = []
        for view in batteryViews where !header[battery].contains(view) {
            problems.append("the battery block lost \(view)")
        }
        if battery.lowerBound < open.upperBound {
            problems.append("the battery is not after the open, non-minimalistic header")
        }
        // Last in the row: nothing but the row's own closing brace follows the battery block.
        let row = blockRange(after: rowMarker, in: header)
        let isLast = row.map { row in
            row.lowerBound < battery.lowerBound && battery.upperBound <= row.upperBound
                && header[battery.upperBound..<row.upperBound].trimmingCharacters(in: .whitespacesAndNewlines) == "}"
        } ?? false
        if !isLast { problems.append("the battery is not last in the row") }
        return problems
    }

    /// The Refresh button sits in the Usage tab gate, fades in and out with a plain
    /// `.transition(.opacity)`, and an `.animation` on that gate drives it (a tab click changes
    /// `currentView` with no transaction, so without it the fade never runs).
    static func refreshFadeProblems(in header: String) -> [String] {
        guard let gate = blockRange(after: refreshMarker, in: header) else {
            return ["the header shows no Usage tab Refresh button"]
        }
        let body = header[gate]
        var problems: [String] = []
        if !body.contains(#"Image(systemName: "arrow.clockwise")"#) {
            problems.append("the Usage tab gate shows no Refresh button")
        }
        if !body.contains(".transition(.opacity)") || [".scale", ".move", ".slide", ".offset"].contains(where: { body.contains($0) }) {
            problems.append("the Refresh button does not simply fade")
        }
        if !header.contains(refreshAnimation) {
            problems.append("the Refresh button's show/hide is not animated")
        }
        return problems
    }

    // MARK: - Helpers

    /// Source lines only: a line that is a `//` comment is dropped, so prose cannot satisfy a marker.
    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// From the first `marker` to the end of the balanced `{ … }` it opens (its own brace, when it
    /// ends with one), or nil.
    private static func blockRange(after marker: String, in source: String) -> Range<String.Index>? {
        guard let start = source.range(of: marker),
              let open = source[start.lowerBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        repeat {
            if source[index] == "{" { depth += 1 } else if source[index] == "}" { depth -= 1 }
            index = source.index(after: index)
        } while index < source.endIndex && depth > 0
        return start.lowerBound..<index
    }
}

/// A miniature header, in the real one's shape, to plant offenders in.
private enum Plant {
    static let recording = "if Defaults[.showRecordingIndicator] { RecordingIndicator() }"
    static let dnd = "if doNotDisturbManager.isDoNotDisturbActive { FocusIndicator().transition(.opacity) }"
    static let refresh = """
        if coordinator.currentView == .llmUsage {
            Button { Image(systemName: "arrow.clockwise") }
                .transition(.opacity)
        }
        """
    static let tasks = "if showsTasksButton { TasksHeaderButton().transition(.opacity) }"
    static let clipboard = #"if showClipboardIcon { Button { Image(systemName: "doc.on.clipboard") } }"#
    static let timer = #"if timerDisplayMode == .popover { Button { Image(systemName: "timer") } }"#
    static let brain = #"if Defaults[.settingsIconInNotch] { Button { Image(systemName: "brain") } }"#
    static let battery = """
        if vm.notchState == .open && showBatteryIndicator {
            if enableMinimalisticUI { MinimalisticBatteryView(level: 1) } else { KannuBatteryView(level: 1) }
        }
        """
    static let order = [recording, dnd, refresh, tasks, clipboard, timer, brain]

    static func header(_ items: [String] = Plant.order,
                       beforeOpen: String = "",
                       open: String = HeaderOrderRulesTests.openMarker,
                       battery: String = Plant.battery,
                       afterBattery: String = "") -> String {
        """
        HStack(spacing: 4) {
        \(beforeOpen)
        \(open)
        \(items.joined(separator: "\n"))
        }
        \(battery)
        \(afterBattery)
        }
        .font(.system(.headline, design: .rounded))
        \(HeaderOrderRulesTests.refreshAnimation)
        """
    }
}
