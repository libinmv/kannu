//
//  TasksPopoverRulesTests.swift
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

/// The notch's Tasks button and popover are views, not in the logic target, so their wiring is read
/// from the source (the `TimerNamingRulesTests` idiom):
///
/// - opening the popover sets `vm.isTasksPopoverActive`, and leaving the view clears it;
/// - `ContentView.hasAnyActivePopovers()` includes that flag, or the notch closes under the popover;
/// - the button has a VoiceOver label and a `.hoverTooltip`, and sits after the timer button, only
///   with tasks on, the notch open and the minimalistic UI off;
/// - no notch view uses `.help(` — it never renders there (docs/REGRESSIONS.md entry 9). The
///   pre-commit hook checks the same, but no CI job runs the hook; this test is the CI-side guard;
/// - Manage tasks…, Connect Jira… / Connect GitLab… and the Brain glyph open Brain › Tasks at
///   Sources through `SettingsDeepLink.tasksSourcesHighlightID`;
/// - the new views never touch the Keychain, and live time ticks only through a `TimelineView`.
///
/// Each detector has a planted-offender test, so a scanner that stops matching fails instead of
/// passing vacuously.
final class TasksPopoverRulesTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root
    static let buttonPath = "Kannu/components/Notch/TasksHeaderButton.swift"
    static let popoverPath = "Kannu/components/Notch/TasksPopover.swift"
    static let menuPath = "Kannu/components/Notch/TaskSourceMenu.swift"
    static let headerPath = "Kannu/components/Notch/KannuHeader.swift"
    static let contentViewPath = "Kannu/ContentView.swift"
    static let viewModelPath = "Kannu/models/KannuViewModel.swift"
    static let newFiles = [buttonPath, popoverPath, menuPath]
    static let notchDirectories = ["Kannu/components/Notch", "Kannu/components/AgentStatus"]
    static let keychainAPIs = ["SecureSecretsStore", "KeychainReader", "SecItem", "JiraCredentialStore", "GitLabCredentialStore"]
    static let tickers = ["Timer.publish", "Timer.scheduledTimer", "Timer(timeInterval", ".autoconnect()", "DispatchSourceTimer"]

    private static func read(_ path: String) throws -> String {
        code(try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8))
    }

    // MARK: - The rules, on the real sources

    func testOpeningThePopoverSetsTheFlagAndLeavingClearsIt() throws {
        XCTAssertEqual(Self.flagProblems(in: try Self.read(Self.buttonPath)), [])
    }

    func testHasAnyActivePopoversIncludesTheTasksFlag() throws {
        XCTAssertEqual(Self.popoverListProblems(
            contentView: try Self.read(Self.contentViewPath),
            viewModel: try Self.read(Self.viewModelPath)
        ), [])
    }

    func testTheButtonHasAnAccessibilityLabelAndAHoverTooltip() throws {
        XCTAssertEqual(Self.buttonProblems(in: try Self.read(Self.buttonPath)), [])
    }

    func testTheButtonSitsAfterTheTimerButtonOnlyWithTasksOn() throws {
        XCTAssertEqual(Self.placementProblems(in: try Self.read(Self.headerPath)), [])
    }

    func testNoNotchViewUsesHelp() throws {
        var sources: [String: String] = [:]
        for directory in Self.notchDirectories {
            let folder = Self.repoRoot.appendingPathComponent(directory)
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".swift") {
                // Raw text: the scan drops comments itself, line by line, the way the hook does.
                sources["\(directory)/\(name)"] = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            }
        }
        for path in Self.newFiles {
            XCTAssertNotNil(sources[path], "\(path) is not where the scan looks")
        }
        XCTAssertGreaterThan(sources.count, 10, "the scan read almost nothing — check the path, not the rule")
        XCTAssertEqual(Self.helpCalls(in: sources), [], "a notch tooltip is .hoverTooltip; .help never renders there (REGRESSIONS entry 9)")
    }

    func testManageTasksAndTheBrainGlyphOpenBrainAtSources() throws {
        XCTAssertEqual(Self.deepLinkProblems(menu: try Self.read(Self.menuPath), popover: try Self.read(Self.popoverPath)), [])
    }

    func testTheNotchTasksViewsNeverTouchTheKeychain() throws {
        var sources: [String: String] = [:]
        for path in Self.newFiles { sources[path] = try Self.read(path) }
        XCTAssertEqual(Self.keychainUses(in: sources), [])
    }

    func testLiveTimeTicksOnlyThroughATimelineView() throws {
        var sources: [String: String] = [:]
        for path in Self.newFiles { sources[path] = try Self.read(path) }
        XCTAssertEqual(Self.tickerProblems(in: sources), [])
        XCTAssertTrue(sources[Self.popoverPath]?.contains("TimelineView(.periodic(from: .now, by: 1))") ?? false,
                      "the Now card no longer ticks through a TimelineView: the scan is vacuous")
    }

    // MARK: - The scanners catch planted offenders

    func testTheFlagScannerCatchesPlantedOffenders() {
        let good = Self.code("""
            .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                TasksPopover(close: { showsPopover = false })
            }
            .onChange(of: showsPopover) { _, isActive in
                vm.isTasksPopoverActive = isActive
            }
            .onDisappear {
                vm.isTasksPopoverActive = false
            }
            """)
        XCTAssertEqual(Self.flagProblems(in: good), [])
        let neverSet = good.replacingOccurrences(of: "vm.isTasksPopoverActive = isActive", with: "print(isActive)")
        XCTAssertEqual(Self.flagProblems(in: neverSet), ["the popover never sets vm.isTasksPopoverActive"])
        let neverCleared = good.replacingOccurrences(of: "vm.isTasksPopoverActive = false", with: "")
        XCTAssertEqual(Self.flagProblems(in: neverCleared), ["leaving the view does not clear vm.isTasksPopoverActive"])
        let commented = """
            .popover(isPresented: $showsPopover) { TasksPopover(close: {}) }
            .onChange(of: showsPopover) { _, isActive in
            }
            .onDisappear {
            }
            """ + "\n// vm.isTasksPopoverActive = isActive\n// vm.isTasksPopoverActive = false"
        XCTAssertEqual(Self.flagProblems(in: Self.code(commented)).count, 2, "a comment sets nothing")
        XCTAssertEqual(Self.flagProblems(in: "Button {}"), [
            "no popover shows TasksPopover",
            "the popover never sets vm.isTasksPopoverActive",
            "leaving the view does not clear vm.isTasksPopoverActive",
        ])
    }

    func testThePopoverListScannerCatchesPlantedOffenders() {
        let viewModel = "@Published var isTimerPopoverActive: Bool = false\n@Published var isTasksPopoverActive: Bool = false"
        let good = """
            private func hasAnyActivePopovers() -> Bool {
                return vm.isTimerPopoverActive ||
                    vm.isTasksPopoverActive ||
                    vm.isMediaOutputPopoverActive
            }
            """
        XCTAssertEqual(Self.popoverListProblems(contentView: good, viewModel: viewModel), [])
        let missing = """
            private func hasAnyActivePopovers() -> Bool {
                return vm.isTimerPopoverActive || vm.isMediaOutputPopoverActive
            }
            func elsewhere() { _ = vm.isTasksPopoverActive }
            """
        XCTAssertEqual(Self.popoverListProblems(contentView: missing, viewModel: viewModel),
                       ["hasAnyActivePopovers() leaves out vm.isTasksPopoverActive"], "a use elsewhere does not count")
        XCTAssertEqual(Self.popoverListProblems(contentView: good, viewModel: "@Published var isTimerPopoverActive = false"),
                       ["KannuViewModel has no @Published isTasksPopoverActive"])
        XCTAssertEqual(Self.popoverListProblems(contentView: "", viewModel: viewModel), ["hasAnyActivePopovers() not found"])
    }

    func testTheButtonScannerCatchesPlantedOffenders() {
        let good = Self.code("""
            Button(action: { showsPopover.toggle() }) {
                Capsule().overlay { Image(systemName: "checklist") }
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(Self.accessibilityLabel(waiting: waiting))
            .hoverTooltip(String(localized: "Tasks"), edge: .below)
            .popover(isPresented: $showsPopover) { TasksPopover(close: {}) }
            """)
        XCTAssertEqual(Self.buttonProblems(in: good), [])
        let help = good.replacingOccurrences(of: ".hoverTooltip(String(localized: \"Tasks\"), edge: .below)", with: ".help(\"Tasks\")")
        XCTAssertEqual(Self.buttonProblems(in: help), ["the button has no .hoverTooltip"])
        let silent = good.replacingOccurrences(of: ".accessibilityLabel(Self.accessibilityLabel(waiting: waiting))", with: "")
        XCTAssertEqual(Self.buttonProblems(in: silent), ["the button has no .accessibilityLabel"])
        let afterThePopover = Self.code("""
            Button(action: {}) { Image(systemName: "checklist") }
            .popover(isPresented: $showsPopover) { TasksPopover(close: {}).accessibilityLabel("x").hoverTooltip("y") }
            """)
        XCTAssertEqual(Self.buttonProblems(in: afterThePopover).count, 2, "modifiers inside the popover's content are not the button's")
        XCTAssertEqual(Self.buttonProblems(in: "Text(\"x\")"), ["no button shows the checklist symbol"])
    }

    func testThePlacementScannerCatchesPlantedOffenders() {
        let good = """
            if vm.notchState == .open && !enableMinimalisticUI {
                if Defaults[.enableTimerFeature] && timerDisplayMode == .popover {
                    Button {} .popover(isPresented: $showTimerPopover) { TimerPopover() }
                }
                if enableTasks {
                    TasksHeaderButton()
                }
                if Defaults[.settingsIconInNotch] {
                    Button {}
                }
            }
            """
        XCTAssertEqual(Self.placementProblems(in: good), [])
        let unconditional = good.replacingOccurrences(of: "if enableTasks {\n        TasksHeaderButton()\n    }", with: "TasksHeaderButton()")
        XCTAssertNotEqual(unconditional, good, "the plant did not take")
        XCTAssertEqual(Self.placementProblems(in: unconditional), ["TasksHeaderButton() is not shown only with tasks on"])
        let first = """
            if vm.notchState == .open && !enableMinimalisticUI {
                if enableTasks { TasksHeaderButton() }
                Button {} .popover(isPresented: $showTimerPopover) { TimerPopover() }
                if Defaults[.settingsIconInNotch] { Button {} }
            }
            """
        XCTAssertEqual(Self.placementProblems(in: first), ["TasksHeaderButton() is not after the timer button"])
        let last = """
            if vm.notchState == .open && !enableMinimalisticUI {
                Button {} .popover(isPresented: $showTimerPopover) { TimerPopover() }
                if Defaults[.settingsIconInNotch] { Button {} }
                if enableTasks { TasksHeaderButton() }
            }
            """
        XCTAssertEqual(Self.placementProblems(in: last), ["TasksHeaderButton() is not before the Brain button"])
        let closed = """
            if enableTasks { TasksHeaderButton() }
            if vm.notchState == .open && !enableMinimalisticUI {
                Button {} .popover(isPresented: $showTimerPopover) { TimerPopover() }
                if Defaults[.settingsIconInNotch] { Button {} }
            }
            """
        XCTAssertTrue(Self.placementProblems(in: closed).contains("TasksHeaderButton() is not inside the open, non-minimalistic header"))
        XCTAssertEqual(Self.placementProblems(in: "struct KannuHeader {}"), ["the header shows no TasksHeaderButton()"])
    }

    func testTheHelpScannerCatchesPlantedOffenders() {
        let planted = [
            "Kannu/components/Notch/Quiet.swift": """
                // .help("in a line comment") is prose
                /// `.help(...)` in a doc comment is prose
                 * .help( in a block comment line is prose
                Button("x") {}.hoverTooltip("Fine", edge: .below)
                """,
            "Kannu/components/Notch/Loud.swift": """
                Button("x") {}
                    .help("Never renders")
                Text("y").help(Text("Nor this"))
                """,
            "Kannu/components/AgentStatus/Trailing.swift": """
                Image(systemName: "cup").help("x") // a trailing comment does not excuse the call
                """,
        ]
        XCTAssertEqual(Self.helpCalls(in: planted), [
            "Kannu/components/AgentStatus/Trailing.swift:1",
            "Kannu/components/Notch/Loud.swift:2",
            "Kannu/components/Notch/Loud.swift:3",
        ])
    }

    func testTheDeepLinkScannerCatchesPlantedOffenders() {
        let menu = Self.code("""
            enum TasksBrainDestination {
                case sources, taskOrder, timeToLog
                var highlightID: String {
                    switch self {
                    case .sources: return SettingsDeepLink.tasksSourcesHighlightID
                    case .taskOrder: return SettingsDeepLink.tasksOrderHighlightID
                    case .timeToLog: return SettingsDeepLink.tasksTimeToLogHighlightID
                    }
                }
                @MainActor
                func open() {
                    SettingsWindowController.shared.showWindow(navigatingToAgentStatusHighlight: highlightID)
                }
            }
            Button("Connect Jira…") { openBrain(.sources) }
            Button("Connect GitLab…") { openBrain(.sources) }
            Button("Manage tasks…") { openBrain(.sources) }
            """)
        let popover = Self.code("""
            private func openBrain(_ destination: TasksBrainDestination) {
                close()
                destination.open()
            }
            Button {
                openBrain(.sources)
            } label: {
                Image(systemName: "brain")
            }
            """)
        XCTAssertEqual(Self.deepLinkProblems(menu: menu, popover: popover), [])

        let wrongRow = menu.replacingOccurrences(of: "Button(\"Manage tasks…\") { openBrain(.sources) }",
                                                 with: "Button(\"Manage tasks…\") { openBrain(.taskOrder) }")
        XCTAssertEqual(Self.deepLinkProblems(menu: wrongRow, popover: popover), ["Manage tasks… does not open Sources"])
        let integrations = menu.replacingOccurrences(of: "case .sources: return SettingsDeepLink.tasksSourcesHighlightID",
                                                     with: "case .sources: return \"integrations-Jira\"")
        XCTAssertEqual(Self.deepLinkProblems(menu: integrations, popover: popover),
                       [".sources is not SettingsDeepLink.tasksSourcesHighlightID"])
        let plainWindow = menu.replacingOccurrences(of: "showWindow(navigatingToAgentStatusHighlight: highlightID)", with: "showWindow()")
        XCTAssertEqual(Self.deepLinkProblems(menu: plainWindow, popover: popover),
                       ["TasksBrainDestination.open() does not use the deep link"])
        let settingsGlyph = popover.replacingOccurrences(of: "openBrain(.sources)", with: "SettingsWindowController.shared.showWindow()")
        XCTAssertEqual(Self.deepLinkProblems(menu: menu, popover: settingsGlyph), ["the Brain glyph does not open Sources"])
        let connect = menu.replacingOccurrences(of: "Button(\"Connect GitLab…\") { openBrain(.sources) }",
                                                with: "Button(\"Connect GitLab…\") { showsConnectSheet = true }")
        XCTAssertEqual(Self.deepLinkProblems(menu: connect, popover: popover), ["Connect GitLab… does not open Sources"])
        let stayOpen = popover.replacingOccurrences(of: "close()\n", with: "")
        XCTAssertEqual(Self.deepLinkProblems(menu: menu, popover: stayOpen), ["openBrain does not close the popover first"])
    }

    func testTheKeychainAndTickerScannersCatchPlantedOffenders() {
        let planted = [
            "A.swift": "let value = SecureSecretsStore.read(.jiraCredential)",
            "B.swift": "Task { _ = await JiraCredentialStore.load(allowInteraction: false) }",
            "C.swift": "Text(\"fine\")",
        ]
        XCTAssertEqual(Self.keychainUses(in: planted), ["A.swift: SecureSecretsStore", "B.swift: JiraCredentialStore"])
        let tickers = [
            "A.swift": ".onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in }",
            "B.swift": "ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick() }",
            "C.swift": "TimelineView(.periodic(from: .now, by: 1)) { context in Text(context.date, style: .timer) }",
        ]
        XCTAssertEqual(Self.tickerProblems(in: tickers), ["A.swift: .autoconnect()", "A.swift: Timer.publish", "B.swift: Timer.scheduledTimer"])
    }

    // MARK: - Rules

    /// The popover is `TasksPopover`; its `onChange` sets the flag from the presentation, and the
    /// view's `onDisappear` clears it — a popover that vanished with its button never says it closed.
    static func flagProblems(in source: String) -> [String] {
        var problems: [String] = []
        if !(block(after: ".popover(isPresented: $showsPopover", in: source)?.contains("TasksPopover(") ?? false) {
            problems.append("no popover shows TasksPopover")
        }
        if !(block(after: ".onChange(of: showsPopover)", in: source)?.contains("vm.isTasksPopoverActive = isActive") ?? false) {
            problems.append("the popover never sets vm.isTasksPopoverActive")
        }
        if !(block(after: ".onDisappear", in: source)?.contains("vm.isTasksPopoverActive = false") ?? false) {
            problems.append("leaving the view does not clear vm.isTasksPopoverActive")
        }
        return problems
    }

    /// The notch's auto-close asks `hasAnyActivePopovers()`; the flag must be in its body, and on the
    /// view model.
    static func popoverListProblems(contentView: String, viewModel: String) -> [String] {
        var problems: [String] = []
        if let body = block(after: "func hasAnyActivePopovers()", in: contentView) {
            if !body.contains("vm.isTasksPopoverActive") {
                problems.append("hasAnyActivePopovers() leaves out vm.isTasksPopoverActive")
            }
        } else {
            problems.append("hasAnyActivePopovers() not found")
        }
        if !viewModel.contains("@Published var isTasksPopoverActive") {
            problems.append("KannuViewModel has no @Published isTasksPopoverActive")
        }
        return problems
    }

    /// The button's own modifiers — between the button that shows the checklist and its popover —
    /// include `.accessibilityLabel(` and `.hoverTooltip(`.
    static func buttonProblems(in source: String) -> [String] {
        guard let symbol = source.range(of: #"Image(systemName: "checklist")"#),
              let button = source.range(of: "Button(", options: .backwards, range: source.startIndex..<symbol.lowerBound) else {
            return ["no button shows the checklist symbol"]
        }
        let end = source.range(of: ".popover(", range: symbol.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let modifiers = source[button.lowerBound..<end]
        var problems: [String] = []
        if !modifiers.contains(".accessibilityLabel(") { problems.append("the button has no .accessibilityLabel") }
        if !modifiers.contains(".hoverTooltip(") { problems.append("the button has no .hoverTooltip") }
        return problems
    }

    /// In `KannuHeader`: inside the open, non-minimalistic header; inside `if enableTasks {`; after
    /// the timer button; before the Brain button.
    static func placementProblems(in header: String) -> [String] {
        guard let button = header.range(of: "TasksHeaderButton()") else { return ["the header shows no TasksHeaderButton()"] }
        var problems: [String] = []
        if let open = header.range(of: "if vm.notchState == .open && !enableMinimalisticUI {"),
           let region = block(after: "if vm.notchState == .open && !enableMinimalisticUI {", in: header),
           open.lowerBound < button.lowerBound, region.contains("TasksHeaderButton()") {
            // Inside.
        } else {
            problems.append("TasksHeaderButton() is not inside the open, non-minimalistic header")
        }
        if !(block(after: "if enableTasks {", in: header)?.contains("TasksHeaderButton()") ?? false) {
            problems.append("TasksHeaderButton() is not shown only with tasks on")
        }
        if let timer = header.range(of: "TimerPopover()"), timer.lowerBound < button.lowerBound {
            // After.
        } else {
            problems.append("TasksHeaderButton() is not after the timer button")
        }
        if let brain = header.range(of: "if Defaults[.settingsIconInNotch] {"), button.lowerBound < brain.lowerBound {
            // Before.
        } else {
            problems.append("TasksHeaderButton() is not before the Brain button")
        }
        return problems
    }

    /// `.help(` on a line that is not a comment, as "path:line" — the hook's own rule, which drops
    /// only lines that start with `//` or `*`.
    static func helpCalls(in sources: [String: String]) -> [String] {
        sources.flatMap { path, text -> [String] in
            text.components(separatedBy: "\n").enumerated().compactMap { offset, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard line.contains(".help("), !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { return nil }
                return "\(path):\(offset + 1)"
            }
        }.sorted()
    }

    /// Manage tasks…, Connect Jira…, Connect GitLab… and the Brain glyph open `.sources`, which is
    /// the Tasks › Sources deep link, opened through `showWindow(navigatingToAgentStatusHighlight:)`
    /// after the popover closes.
    static func deepLinkProblems(menu: String, popover: String) -> [String] {
        var problems: [String] = []
        for title in ["Manage tasks…", "Connect Jira…", "Connect GitLab…"] {
            if !(block(after: "Button(\"\(title)\")", in: menu)?.contains("openBrain(.sources)") ?? false) {
                problems.append("\(title) does not open Sources")
            }
        }
        if !menu.contains("case .sources: return SettingsDeepLink.tasksSourcesHighlightID") {
            problems.append(".sources is not SettingsDeepLink.tasksSourcesHighlightID")
        }
        if !(block(after: "func open()", in: menu)?.contains("showWindow(navigatingToAgentStatusHighlight: highlightID)") ?? false) {
            problems.append("TasksBrainDestination.open() does not use the deep link")
        }
        if let glyph = popover.range(of: #"Image(systemName: "brain")"#),
           let button = popover.range(of: "Button {", options: .backwards, range: popover.startIndex..<glyph.lowerBound),
           popover[button.upperBound..<glyph.lowerBound].contains("openBrain(.sources)") {
            // The glyph opens Sources.
        } else {
            problems.append("the Brain glyph does not open Sources")
        }
        if let open = block(after: "func openBrain(_ destination: TasksBrainDestination)", in: popover),
           let close = open.range(of: "close()"), let opens = open.range(of: "destination.open()"),
           close.lowerBound < opens.lowerBound {
            // Closes, then opens.
        } else {
            problems.append("openBrain does not close the popover first")
        }
        return problems
    }

    static func keychainUses(in sources: [String: String]) -> [String] {
        sources.flatMap { path, source in
            keychainAPIs.filter { source.contains($0) }.map { "\(path): \($0)" }
        }.sorted()
    }

    static func tickerProblems(in sources: [String: String]) -> [String] {
        sources.flatMap { path, source in
            tickers.filter { source.contains($0) }.map { "\(path): \($0)" }
        }.sorted()
    }

    // MARK: - Scanning

    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The balanced `{ … }` that the first `marker` opens (its own brace, when it ends with one), or nil.
    private static func block(after marker: String, in source: String) -> String? {
        guard let start = source.range(of: marker),
              let open = source[start.lowerBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        repeat {
            if source[index] == "{" { depth += 1 } else if source[index] == "}" { depth -= 1 }
            index = source.index(after: index)
        } while index < source.endIndex && depth > 0
        return String(source[open..<index])
    }
}
