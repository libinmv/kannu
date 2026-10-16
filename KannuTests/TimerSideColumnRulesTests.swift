//
//  TimerSideColumnRulesTests.swift
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

/// The timer tab's side column is a view, not in the logic target, so its wiring is read from the
/// source (the `TimerNamingRulesTests` idiom):
///
/// - `NotchTimerView` never touches `TasksManager`: the Tasks page is a child view of its own, and
///   only it reads `TasksManager.shared`, so the manager is never built while tasks are off;
/// - a task's ▶ does nothing more when `start` fails;
/// - every scroll-suppression token is `@State`: a plain `let` is minted again on each re-render, so
///   the release names a token that was never set and the notch's scroll gesture stays off;
/// - "connected", for the page the tab opens on, is a host being set: the column never reads Sync
///   Jira or Sync GitLab, which only decide what is fetched;
/// - the Tasks page refreshes a stale Jira or GitLab sync when it appears, as the popover does;
/// - the column has no "All tasks ›" link into Brain any more;
/// - the page swipe sits behind the whole tab (`NotchTimerView`), not the column, reaches down into
///   the footer, and stands aside over the ruler, whose own sideways scroll sets the minutes;
/// - it stands aside by geometry first: the ruler's `ScrollWheelMonitor` owns the sideways scroll
///   and registers its view, and the swipe's monitor checks the pointer against the owners' live
///   frames before it offers an event, so the hover-derived `isSuspended` (a `@State`, one re-render
///   late) is only the second guard;
/// - the column hosts no `List`: a `List`'s scroll view keeps the trackpad gesture from the tab's
///   swipe monitor, so a swipe over its rows (the preset cards, once) does not turn the page;
/// - "Tasks · Presets" is a bottom overlay pushed into the footer, never part of the column's stack;
/// - the numbers `TimerComposerMetrics` mirrors from the open notch still match their sources;
/// - no `.help(` in the touched notch files (docs/REGRESSIONS.md entry 9).
///
/// Each detector has a planted-offender test, so a scanner that stops matching fails instead of
/// passing vacuously.
final class TimerSideColumnRulesTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root
    static let notchTimerPath = "Kannu/components/Notch/NotchTimerView.swift"
    static let sideColumnPath = "Kannu/components/Notch/TimerSideColumn.swift"
    static let swipeMonitorPath = "Kannu/components/Notch/HorizontalSwipeMonitor.swift"
    static let rulerPath = "Kannu/components/Timer/RulerTimerPicker.swift"
    static let headerPath = "Kannu/components/Notch/KannuHeader.swift"
    static let contentViewPath = "Kannu/ContentView.swift"
    static let sizesPath = "Kannu/sizing/matters.swift"

    private static func raw(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - The rules, on the real sources

    func testNotchTimerViewNeverTouchesTasksManager() throws {
        XCTAssertEqual(Self.tasksManagerUses(in: Self.code(try Self.raw(Self.notchTimerPath))), [])
    }

    func testOnlyTheTasksPageReadsTheManager() throws {
        let source = Self.code(try Self.raw(Self.sideColumnPath))
        XCTAssertEqual(Self.managerOwnerProblems(in: source), [])
    }

    func testATaskStartsOnlyWhenTheManagerSaysItDid() throws {
        let source = Self.code(try Self.raw(Self.sideColumnPath))
        XCTAssertTrue(source.contains("guard manager.start(task.id) else { return }"),
                      "a failed start must do nothing else (the typed name stays)")
    }

    func testScrollSuppressionTokensAreState() throws {
        for path in [Self.sideColumnPath, Self.rulerPath] {
            XCTAssertEqual(Self.tokenProblems(in: Self.code(try Self.raw(path))), [], path)
        }
    }

    func testConnectedMeansAHostIsSetNotThatSyncIsOn() throws {
        let source = Self.code(try Self.raw(Self.sideColumnPath))
        XCTAssertTrue(source.contains("Defaults[.jiraSiteHost]") && source.contains("Defaults[.gitlabHost]"),
                      "the column no longer reads the hosts: the scan is vacuous")
        XCTAssertEqual(Self.syncSwitchReads(in: source), [])
    }

    func testTheTasksPageRefreshesAStaleSyncOnAppear() throws {
        let source = Self.code(try Self.raw(Self.sideColumnPath))
        XCTAssertTrue(source.contains("manager.syncJiraIfStale()"), "the Tasks page shows a stale Jira order")
        XCTAssertTrue(source.contains("manager.syncGitLabIfStale()"), "the Tasks page shows a stale GitLab order")
    }

    func testTheTouchedNotchFilesNeverUseHelp() throws {
        for path in [Self.sideColumnPath, Self.swipeMonitorPath, Self.notchTimerPath, Self.headerPath, Self.rulerPath] {
            XCTAssertEqual(Self.helpCalls(in: try Self.raw(path)), [], "\(path): .help never renders in the notch")
        }
    }

    /// "All tasks ›" is gone: the header's Tasks button shows on the same tab.
    func testTheColumnHasNoAllTasksLink() throws {
        XCTAssertEqual(Self.allTasksLinkProblems(in: Self.code(try Self.raw(Self.sideColumnPath))), [])
    }

    func testTheSwipeCoversTheWholeTab() throws {
        XCTAssertEqual(Self.swipeHostProblems(
            notch: Self.code(try Self.raw(Self.notchTimerPath)),
            column: Self.code(try Self.raw(Self.sideColumnPath))
        ), [])
    }

    func testTheRulerKeepsItsSidewaysScroll() throws {
        XCTAssertEqual(Self.rulerExclusionProblems(
            notch: Self.code(try Self.raw(Self.notchTimerPath)),
            ruler: Self.code(try Self.raw(Self.rulerPath)),
            monitor: Self.code(try Self.raw(Self.swipeMonitorPath))
        ), [])
    }

    /// Two local monitors run in no promised order, and only consuming an event keeps it from the
    /// other, so the swipe must decide "over the ruler" from the ruler's live frame, at event time,
    /// not from a hover that reaches it through `@State` and a re-render.
    func testTheSwipeYieldsToTheRulerByGeometry() throws {
        XCTAssertEqual(Self.rulerGeometryProblems(
            ruler: Self.code(try Self.raw(Self.rulerPath)),
            monitor: Self.code(try Self.raw(Self.swipeMonitorPath))
        ), [])
    }

    /// A `List`'s scroll view (an `NSTableView`) keeps the trackpad gesture from the tab's swipe
    /// monitor, so a swipe over the preset cards did not turn the page. The pages are `ScrollView`s.
    func testTheColumnHostsNoList() throws {
        XCTAssertEqual(Self.listUses(in: Self.code(try Self.raw(Self.sideColumnPath))), [])
    }

    /// The labels hang in the footer as an overlay, so the tab never grows for them.
    func testThePagerHangsInTheFooter() throws {
        XCTAssertEqual(Self.pagerPlacementProblems(in: Self.code(try Self.raw(Self.sideColumnPath))), [])
    }

    /// `TimerComposerMetrics` mirrors a few numbers from the views and the open notch so its tests
    /// can add them up; each must still be what the source says.
    func testTheMetricsMirrorTheirSources() throws {
        XCTAssertEqual(Self.mirrorProblems(
            contentView: try Self.raw(Self.contentViewPath),
            sizes: try Self.raw(Self.sizesPath),
            notch: Self.code(try Self.raw(Self.notchTimerPath))
        ), [])
    }

    // MARK: - The scanners catch planted offenders

    func testTheTasksManagerScannerCatchesPlantedOffenders() {
        let good = Self.code("""
            // TasksManager in a comment is prose
            TimerSideColumn(page: $sidePage)
            """)
        XCTAssertEqual(Self.tasksManagerUses(in: good), [])
        XCTAssertEqual(Self.tasksManagerUses(in: Self.code("_ = TasksManager.shared.start(id)")).count, 1)
    }

    func testTheOwnerScannerCatchesPlantedOffenders() {
        let good = """
            struct TimerSideColumn: View {
                var body: some View { TimerTasksPage() }
            }

            private struct TimerTasksPage: View {
                @ObservedObject private var manager = TasksManager.shared
            }
            """
        XCTAssertEqual(Self.managerOwnerProblems(in: good), [])
        let eager = good.replacingOccurrences(of: "struct TimerSideColumn: View {",
                                              with: "struct TimerSideColumn: View {\n    @ObservedObject var m = TasksManager.shared")
        XCTAssertEqual(Self.managerOwnerProblems(in: eager).count, 1)
        let missing = good.replacingOccurrences(of: "TasksManager.shared", with: "Other.shared")
        XCTAssertEqual(Self.managerOwnerProblems(in: missing).count, 1, "no reader at all is vacuous")
    }

    func testTheTokenScannerCatchesPlantedOffenders() {
        XCTAssertEqual(Self.tokenProblems(in: "    @State private var scrollSuppressionToken = UUID()"), [])
        XCTAssertEqual(Self.tokenProblems(in: "    private let scrollSuppressionToken = UUID()").count, 1)
        XCTAssertEqual(Self.tokenProblems(in: "    private var scrollSuppressionToken = UUID()").count, 1)
        XCTAssertEqual(Self.tokenProblems(in: "    vm.set(true, token: scrollSuppressionToken)").count, 1,
                       "no declaration at all is vacuous")
    }

    func testTheSyncSwitchScannerCatchesPlantedOffenders() {
        let good = Self.code("""
            // Defaults[.jiraEnabled] in a comment is prose
            jiraConnected: !Defaults[.jiraSiteHost].isEmpty,
            """)
        XCTAssertEqual(Self.syncSwitchReads(in: good), [])
        let planted = Self.code("""
            jiraConnected: !Defaults[.jiraSiteHost].isEmpty && Defaults[.jiraEnabled],
            gitlabConnected: !Defaults[.gitlabHost].isEmpty && Defaults[.gitlabEnabled]
            @Default(.jiraEnabled) private var jiraEnabled
            """)
        XCTAssertEqual(Self.syncSwitchReads(in: planted).count, 3)
    }

    func testTheHelpScannerCatchesPlantedOffenders() {
        let planted = """
            // .help("in a comment") is prose
            /// `.help(...)` in a doc comment is prose
            Text("x").help("Never renders")
            """
        XCTAssertEqual(Self.helpCalls(in: planted), ["3"])
    }

    func testTheAllTasksScannerCatchesPlantedOffenders() {
        let good = Self.code("""
            // "All tasks" and TasksBrainDestination in a comment are prose
            statusRow(String(localized: "No tasks"))
            """)
        XCTAssertEqual(Self.allTasksLinkProblems(in: good), [])
        XCTAssertEqual(Self.allTasksLinkProblems(in: "    TasksBrainDestination.taskList.open()").count, 1)
        XCTAssertEqual(Self.allTasksLinkProblems(in: "    Text(\"All tasks ›\")").count, 1)
    }

    func testTheSwipeHostScannerCatchesPlantedOffenders() {
        let notch = """
                .background { if hasPageSwipe { HorizontalSwipeMonitor(current: shownSidePage, onSwipe: selectSidePage)
                    .padding(.bottom, -TimerComposerMetrics.pageSwipeFooterReach)
                    .allowsHitTesting(false) } }
            """
        let column = "    pageView.overlay(alignment: .bottom) { pager }"
        XCTAssertEqual(Self.swipeHostProblems(notch: notch, column: column), [])
        XCTAssertEqual(Self.swipeHostProblems(notch: column, column: column), ["NotchTimerView does not host HorizontalSwipeMonitor"])
        XCTAssertEqual(Self.swipeHostProblems(notch: notch, column: notch), ["TimerSideColumn still hosts HorizontalSwipeMonitor"])
        let short = notch.replacingOccurrences(of: ".padding(.bottom, -TimerComposerMetrics.pageSwipeFooterReach)", with: "")
        XCTAssertEqual(Self.swipeHostProblems(notch: short, column: column), ["the page swipe does not reach into the footer"])
    }

    func testTheListScannerCatchesPlantedOffenders() {
        let good = Self.code("""
            // List { in a comment is prose
            ScrollView(.vertical) { LazyVStack(spacing: 0) { ForEach(presets) { _ in } } }
            SideListEdgeFades()
            .listStyle(.plain)
            let listHeight = min(pageHeight, computedHeight)
            ClipboardItemsList()
            """)
        XCTAssertEqual(Self.listUses(in: good), [])
        XCTAssertEqual(Self.listUses(in: "        List {").count, 1)
        XCTAssertEqual(Self.listUses(in: "        List{").count, 1)
        XCTAssertEqual(Self.listUses(in: "        List(presets) { preset in").count, 1)
        XCTAssertEqual(Self.listUses(in: "        ZStack { List(selection: $picked) {").count, 1)
    }

    func testThePagerPlacementScannerCatchesPlantedOffenders() {
        let good = """
                pageView
                    .frame(maxHeight: budget, alignment: .top)
                    .overlay(alignment: .bottom) {
                        if hasPager {
                            pager
                                .offset(y: M.sidePagerFooterOffset)
                        }
                    }
            private var pager: some View {
                HStack { }
                .frame(height: M.sidePagerHeight)
            }
            """
        XCTAssertEqual(Self.pagerPlacementProblems(in: good), [])
        let plant: (String, String) -> String = { target, replacement in
            let planted = good.replacingOccurrences(of: target, with: replacement)
            XCTAssertNotEqual(planted, good, "the plant did not take: \(target)")
            return planted
        }
        XCTAssertEqual(Self.pagerPlacementProblems(in: plant(".overlay(alignment: .bottom)", ".overlay(alignment: .top)")),
                       ["the labels are not a bottom overlay of the column"])
        XCTAssertEqual(Self.pagerPlacementProblems(in: plant(".offset(y: M.sidePagerFooterOffset)", "")),
                       ["the labels are not offset into the footer by sidePagerFooterOffset"])
        XCTAssertEqual(Self.pagerPlacementProblems(in: plant(".frame(height: M.sidePagerHeight)", "")),
                       ["the label row is not sidePagerHeight tall"])
        let stacked = plant("pageView\n", "VStack { pager\n pageView }\n")
        XCTAssertEqual(Self.pagerPlacementProblems(in: stacked), ["pager is used outside the footer overlay"])
    }

    func testTheRulerExclusionScannerCatchesPlantedOffenders() {
        let notch = """
                    startAction: startCustomTimer,
                    onScrollAreaHover: { isOverRuler = $0 }
                HorizontalSwipeMonitor(current: shownSidePage, isSuspended: isOverRuler, onSwipe: selectSidePage)
            """
        let ruler = """
                var onScrollAreaHover: (Bool) -> Void = { _ in }
                .onHover { hovering in
                    updateScrollGestureSuppression(hovering)
                    onScrollAreaHover(hovering)
                }
            """
        let monitor = """
                ScrollWheelMonitor(yieldsToOwners: true) { event in
                    guard !isSuspended else { return false }
                    if event.momentumPhase == [] {
                        if let page = tracker.handle(event, current: current) {
            """
        XCTAssertEqual(Self.rulerExclusionProblems(notch: notch, ruler: ruler, monitor: monitor), [])
        let unsuspended = notch.replacingOccurrences(of: "isSuspended: isOverRuler, ", with: "")
        XCTAssertEqual(Self.rulerExclusionProblems(notch: unsuspended, ruler: ruler, monitor: monitor),
                       ["the page swipe is not suspended over the ruler"])
        let unwired = notch.replacingOccurrences(of: "onScrollAreaHover: { isOverRuler = $0 }", with: "")
        XCTAssertEqual(Self.rulerExclusionProblems(notch: unwired, ruler: ruler, monitor: monitor),
                       ["NotchTimerView does not track the ruler hover"])
        let silent = ruler.replacingOccurrences(of: "onScrollAreaHover(hovering)", with: "")
        XCTAssertEqual(Self.rulerExclusionProblems(notch: notch, ruler: silent, monitor: monitor),
                       ["the ruler's .onHover does not report onScrollAreaHover"])
        let unguarded = monitor.replacingOccurrences(of: "guard !isSuspended else { return false }", with: "")
        XCTAssertEqual(Self.rulerExclusionProblems(notch: notch, ruler: ruler, monitor: unguarded),
                       ["HorizontalSwipeMonitor does not honour isSuspended before it counts a swipe"])
        let late = monitor
            .replacingOccurrences(of: "guard !isSuspended else { return false }", with: "")
            .replacingOccurrences(of: "current: current) {", with: "current: current) {\n    guard !isSuspended else { return false }")
        XCTAssertNotEqual(late, monitor)
        XCTAssertEqual(Self.rulerExclusionProblems(notch: notch, ruler: ruler, monitor: late),
                       ["HorizontalSwipeMonitor does not honour isSuspended before it counts a swipe"])
    }

    func testTheRulerGeometryScannerCatchesPlantedOffenders() {
        let ruler = """
                ScrollWheelMonitor(ownsSidewaysScroll: true) { event in
                    guard event.isHorizontalTrackpadScroll else { return false }
            """
        let monitor = """
                func installMonitor(on view: NSView) {
                    if ownsSidewaysScroll { ScrollWheelMonitor.sidewaysScrollOwners.add(view) }
                    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak view] event in
                        guard self.shouldOffer(event, view: view) else { return event }
                        return self.onScroll(event) ? nil : event
                    }
                }
                func removeMonitor() {
                    if let observedView { ScrollWheelMonitor.sidewaysScrollOwners.remove(observedView) }
                }
                private func shouldOffer(_ event: NSEvent, view: NSView) -> Bool {
                    if yieldsToOwners && Self.isPoint(windowPoint, overAnOwnerIn: window) { return false }
                    return true
                }
                static func isPoint(_ windowPoint: NSPoint, over view: NSView) -> Bool {
            struct HorizontalSwipeMonitor: View {
                var body: some View {
                    ScrollWheelMonitor(yieldsToOwners: true) { event in
                        guard !isSuspended else { return false }
            """
        XCTAssertEqual(Self.rulerGeometryProblems(ruler: ruler, monitor: monitor), [])
        let disowned = ruler.replacingOccurrences(of: "ScrollWheelMonitor(ownsSidewaysScroll: true) {", with: "ScrollWheelMonitor {")
        XCTAssertEqual(Self.rulerGeometryProblems(ruler: disowned, monitor: monitor),
                       ["the ruler's monitor does not own the sideways scroll"])
        let unyielding = monitor.replacingOccurrences(of: "ScrollWheelMonitor(yieldsToOwners: true) {", with: "ScrollWheelMonitor {")
        XCTAssertEqual(Self.rulerGeometryProblems(ruler: ruler, monitor: unyielding),
                       ["the page swipe's monitor does not yield to the ruler"])
        let unregistered = monitor.replacingOccurrences(of: "if ownsSidewaysScroll { ScrollWheelMonitor.sidewaysScrollOwners.add(view) }", with: "")
        XCTAssertEqual(Self.rulerGeometryProblems(ruler: ruler, monitor: unregistered),
                       ["an owner's view is never registered"])
        // The guard dropped: the swipe's own view becomes an owner, and its yield kills it tab-wide.
        let greedy = monitor.replacingOccurrences(of: "if ownsSidewaysScroll { ScrollWheelMonitor.sidewaysScrollOwners.add(view) }", with: "ScrollWheelMonitor.sidewaysScrollOwners.add(view)")
        XCTAssertNotEqual(greedy, monitor)
        XCTAssertEqual(Self.rulerGeometryProblems(ruler: ruler, monitor: greedy),
                       ["every monitor's view is registered as an owner"])
        let leaking = monitor.replacingOccurrences(of: "if let observedView { ScrollWheelMonitor.sidewaysScrollOwners.remove(observedView) }", with: "")
        XCTAssertEqual(Self.rulerGeometryProblems(ruler: ruler, monitor: leaking),
                       ["an owner's view is never unregistered"])
        let geometryLine = "if yieldsToOwners && Self.isPoint(windowPoint, overAnOwnerIn: window) { return false }"
        let blind = monitor.replacingOccurrences(of: geometryLine, with: "")
        XCTAssertEqual(Self.rulerGeometryProblems(ruler: ruler, monitor: blind),
                       ["ScrollWheelMonitor does not check the owners' frames before it offers an event"])
        // The check outside shouldOffer (here, in a later helper) is not before the offer.
        let elsewhere = blind.replacingOccurrences(of: "over view: NSView) -> Bool {", with: "over view: NSView) -> Bool {\n    \(geometryLine)")
        XCTAssertNotEqual(elsewhere, blind)
        XCTAssertEqual(Self.rulerGeometryProblems(ruler: ruler, monitor: elsewhere),
                       ["ScrollWheelMonitor does not check the owners' frames before it offers an event"])
        // The condition kept but the event not handed back: the swipe consumes the ruler's scroll.
        let toothless = monitor.replacingOccurrences(of: geometryLine, with: "if yieldsToOwners && Self.isPoint(windowPoint, overAnOwnerIn: window) { }")
        XCTAssertNotEqual(toothless, monitor)
        XCTAssertEqual(Self.rulerGeometryProblems(ruler: ruler, monitor: toothless),
                       ["ScrollWheelMonitor does not check the owners' frames before it offers an event"])
        // The check after the `return true` that offers the event is never reached.
        let late = blind.replacingOccurrences(of: "return true", with: "return true\n    \(geometryLine)")
        XCTAssertNotEqual(late, blind)
        XCTAssertEqual(Self.rulerGeometryProblems(ruler: ruler, monitor: late),
                       ["ScrollWheelMonitor does not check the owners' frames before it offers an event"])
        let hasty = monitor
            .replacingOccurrences(of: "guard self.shouldOffer(event, view: view) else { return event }\n", with: "")
            .replacingOccurrences(of: "return self.onScroll(event) ? nil : event", with: "return self.onScroll(event) ? nil : event\n    guard self.shouldOffer(event, view: view) else { return event }")
        XCTAssertNotEqual(hasty, monitor)
        XCTAssertEqual(Self.rulerGeometryProblems(ruler: ruler, monitor: hasty),
                       ["ScrollWheelMonitor offers an event before shouldOffer has checked it"])
    }

    func testTheMirrorScannerCatchesPlantedOffenders() {
        let contentView = "    .padding([.horizontal, .bottom], vm.notchState == .open ? 12 : 0)\n    return activeCornerRadiusInsets.opened.bottom - 5"
        let sizes = "    return 640\nlet cornerRadiusInsets = (opened: (top: 19, bottom: 24), closed: (top: 6, bottom: 14))"
        let notch = Self.metricsTheNotchUses.map { "x(\($0))" }.joined(separator: "\n")
        XCTAssertEqual(Self.mirrorProblems(contentView: contentView, sizes: sizes, notch: notch), [])
        XCTAssertEqual(Self.mirrorProblems(contentView: contentView.replacingOccurrences(of: "? 12", with: "? 16"), sizes: sizes, notch: notch).count, 1)
        XCTAssertEqual(Self.mirrorProblems(contentView: contentView, sizes: sizes.replacingOccurrences(of: "bottom: 24", with: "bottom: 30"), notch: notch).count, 1)
        XCTAssertEqual(Self.mirrorProblems(contentView: contentView, sizes: sizes.replacingOccurrences(of: "return 640", with: "return 600"), notch: notch).count, 1)
        XCTAssertEqual(Self.mirrorProblems(contentView: contentView, sizes: sizes, notch: ".padding(.vertical, 6)").count,
                       Self.metricsTheNotchUses.count)
    }

    // MARK: - Scanning

    /// The source without comment lines.
    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("/*")
            }
            .joined(separator: "\n")
    }

    private static func tasksManagerUses(in code: String) -> [String] {
        code.split(separator: "\n").filter { $0.contains("TasksManager") }.map(String.init)
    }

    /// `TasksManager.shared` is read, and only inside `TimerTasksPage`, the view built only while the
    /// Tasks page shows. Top-level declarations start at column 0.
    private static func managerOwnerProblems(in code: String) -> [String] {
        var owner = ""
        var readers: [String] = []
        for line in code.split(separator: "\n") {
            if let first = line.first, !first.isWhitespace, line.contains("struct ") || line.contains("extension ") {
                owner = String(line)
            }
            if line.contains("TasksManager.shared") { readers.append(owner) }
        }
        if readers.isEmpty { return ["nothing reads TasksManager.shared: the scan is vacuous"] }
        return readers.filter { !$0.contains("struct TimerTasksPage") }.map { "read outside TimerTasksPage: \($0)" }
    }

    /// Every `scrollSuppressionToken` declaration is `@State var`, and there is one.
    private static func tokenProblems(in code: String) -> [String] {
        let declarations = code.split(separator: "\n").filter {
            $0.contains("scrollSuppressionToken") && ($0.contains(" let ") || $0.contains(" var "))
        }
        if declarations.isEmpty { return ["no scrollSuppressionToken declaration"] }
        return declarations.filter { !($0.contains("@State") && $0.contains(" var ")) }.map(String.init)
    }

    /// Lines that read Sync Jira or Sync GitLab. Those switches only decide what is fetched; whether
    /// a source is connected, for the page the tab opens on, is whether its host is set.
    private static func syncSwitchReads(in code: String) -> [String] {
        code.split(separator: "\n")
            .filter { $0.contains(".jiraEnabled") || $0.contains(".gitlabEnabled") }
            .map(String.init)
    }

    /// Code lines that link to Brain's Task list or say "All tasks": the link is gone.
    private static func allTasksLinkProblems(in code: String) -> [String] {
        code.split(separator: "\n")
            .filter { $0.contains("TasksBrainDestination") || $0.contains("All tasks") }
            .map(String.init)
    }

    /// The page swipe sits behind the whole tab (`NotchTimerView`), not behind the column alone.
    /// Its area reaches down into the footer (`pageSwipeFooterReach`), where the labels hang.
    private static func swipeHostProblems(notch: String, column: String) -> [String] {
        var problems: [String] = []
        if let host = notch.range(of: "HorizontalSwipeMonitor(") {
            let end = notch.range(of: "}", range: host.upperBound..<notch.endIndex)?.lowerBound ?? notch.endIndex
            if !notch[host.upperBound..<end].contains(".padding(.bottom, -TimerComposerMetrics.pageSwipeFooterReach)") {
                problems.append("the page swipe does not reach into the footer")
            }
        } else {
            problems.append("NotchTimerView does not host HorizontalSwipeMonitor")
        }
        if column.contains("HorizontalSwipeMonitor(") { problems.append("TimerSideColumn still hosts HorizontalSwipeMonitor") }
        return problems
    }

    /// "Tasks · Presets" is a bottom overlay of the column, pushed into the footer by
    /// `sidePagerFooterOffset` and `sidePagerHeight` tall, and `pager` is used nowhere else: in the
    /// column's own stack it would take room, and the tab (and the notch) would grow.
    private static func pagerPlacementProblems(in column: String) -> [String] {
        var problems: [String] = []
        let overlay = column.range(of: ".overlay(alignment: .bottom) {").map { start -> Substring in
            let open = column.index(before: start.upperBound)
            var depth = 0
            var index = open
            repeat {
                if column[index] == "{" { depth += 1 } else if column[index] == "}" { depth -= 1 }
                index = column.index(after: index)
            } while index < column.endIndex && depth > 0
            return column[open..<index]
        }
        guard let overlay else { return ["the labels are not a bottom overlay of the column"] }
        if !overlay.contains(".offset(y: M.sidePagerFooterOffset)") {
            problems.append("the labels are not offset into the footer by sidePagerFooterOffset")
        }
        if !column.contains(".frame(height: M.sidePagerHeight)") {
            problems.append("the label row is not sidePagerHeight tall")
        }
        let declarations = wordCount("var pager", in: column[...])
        let overlayUses = wordCount("pager", in: overlay)
        if wordCount("pager", in: column[...]) - declarations != overlayUses || overlayUses == 0 {
            problems.append("pager is used outside the footer overlay")
        }
        return problems
    }

    /// Code lines that build a SwiftUI `List` (`List {` or `List(`): the word `List` on its own, not
    /// part of a longer name such as `SideListEdgeFades`, followed by a brace or a parenthesis.
    private static func listUses(in code: String) -> [String] {
        code.split(separator: "\n").filter { line in
            var searchStart = line.startIndex
            while let found = line.range(of: "List", range: searchStart..<line.endIndex) {
                searchStart = found.upperBound
                if found.lowerBound > line.startIndex {
                    let before = line[line.index(before: found.lowerBound)]
                    if before.isLetter || before.isNumber || before == "_" { continue }
                }
                let next = line[found.upperBound...].first { !$0.isWhitespace }
                if next == "{" || next == "(" { return true }
            }
            return false
        }.map(String.init)
    }

    /// How often `word` appears with no identifier character either side (`hasPager` is not `pager`).
    private static func wordCount(_ word: String, in text: Substring) -> Int {
        let isIdentifierCharacter = { (c: Character) in c.isLetter || c.isNumber || c == "_" }
        var count = 0
        var searchStart = text.startIndex
        while let found = text.range(of: word, range: searchStart..<text.endIndex) {
            let before = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : " "
            let after = found.upperBound < text.endIndex ? text[found.upperBound] : " "
            if !isIdentifierCharacter(before) && !isIdentifierCharacter(after) { count += 1 }
            searchStart = found.upperBound
        }
        return count
    }

    /// Over the ruler, a sideways scroll sets minutes: the ruler reports its hover from `.onHover`,
    /// `NotchTimerView` keeps it in `isOverRuler`, and the swipe is suspended while it is true:
    /// `HorizontalSwipeMonitor` hands the event back before its tracker counts anything.
    private static func rulerExclusionProblems(notch: String, ruler: String, monitor: String) -> [String] {
        var problems: [String] = []
        let honoured = monitor.range(of: "ScrollWheelMonitor(yieldsToOwners: true) { event in").flatMap { closure -> Bool? in
            guard let guardLine = monitor.range(of: "guard !isSuspended else { return false }", range: closure.upperBound..<monitor.endIndex),
                  let handle = monitor.range(of: "tracker.handle(", range: closure.upperBound..<monitor.endIndex) else { return nil }
            return guardLine.lowerBound < handle.lowerBound
        } ?? false
        if !notch.contains("isSuspended: isOverRuler") { problems.append("the page swipe is not suspended over the ruler") }
        if !notch.contains("onScrollAreaHover: { isOverRuler = $0 }") { problems.append("NotchTimerView does not track the ruler hover") }
        let reports = ruler.range(of: ".onHover { hovering in").flatMap { hover in
            ruler.range(of: "}", range: hover.upperBound..<ruler.endIndex).map { ruler[hover.upperBound..<$0.lowerBound] }
        }
        if !(ruler.contains("var onScrollAreaHover: (Bool) -> Void") && (reports?.contains("onScrollAreaHover(hovering)") ?? false)) {
            problems.append("the ruler's .onHover does not report onScrollAreaHover")
        }
        if !honoured { problems.append("HorizontalSwipeMonitor does not honour isSuspended before it counts a swipe") }
        return problems
    }

    /// The swipe stands aside over the ruler by geometry, read at event time: the ruler's monitor
    /// owns the sideways scroll and registers its view (only an owner's) while installed; the swipe's
    /// monitor yields to the owners; and `shouldOffer` hands back an event over an owner's frame,
    /// ahead of the `return true` that lets the handler offer it to `onScroll`.
    private static func rulerGeometryProblems(ruler: String, monitor: String) -> [String] {
        var problems: [String] = []
        if !ruler.contains("ScrollWheelMonitor(ownsSidewaysScroll: true) {") {
            problems.append("the ruler's monitor does not own the sideways scroll")
        }
        let swipe = monitor.range(of: "struct HorizontalSwipeMonitor").map { monitor[$0.upperBound...] } ?? ""
        if !swipe.contains("ScrollWheelMonitor(yieldsToOwners: true) {") {
            problems.append("the page swipe's monitor does not yield to the ruler")
        }
        // Registered under the guard, exactly: an unguarded `add(view)` would register the swipe's
        // own view, which its yield would then find under the pointer on every event, tab-wide.
        let install = body(of: "installMonitor", in: monitor)
        if !(install?.contains("if ownsSidewaysScroll { ScrollWheelMonitor.sidewaysScrollOwners.add(view) }") ?? false) {
            problems.append(install?.contains("sidewaysScrollOwners.add(") == true
                ? "every monitor's view is registered as an owner"
                : "an owner's view is never registered")
        }
        if !(body(of: "removeMonitor", in: monitor)?.contains("sidewaysScrollOwners.remove(") ?? false) {
            problems.append("an owner's view is never unregistered")
        }
        // The whole statement, handing the event back, and ahead of the `return true` that offers it.
        let yields = body(of: "shouldOffer", in: monitor).flatMap { offer -> Bool? in
            guard let check = offer.range(of: "if yieldsToOwners && Self.isPoint(windowPoint, overAnOwnerIn: window) { return false }"),
                  let offered = offer.range(of: "return true") else { return nil }
            return check.lowerBound < offered.lowerBound
        } ?? false
        if !yields {
            problems.append("ScrollWheelMonitor does not check the owners' frames before it offers an event")
        }
        let checkedFirst = monitor.range(of: "addLocalMonitorForEvents").flatMap { install -> Bool? in
            guard let offerCall = monitor.range(of: "self.onScroll(event)", range: install.upperBound..<monitor.endIndex) else { return nil }
            return monitor[install.upperBound..<offerCall.lowerBound].contains("shouldOffer(")
        } ?? false
        if !checkedFirst { problems.append("ScrollWheelMonitor offers an event before shouldOffer has checked it") }
        return problems
    }

    /// The text from `func <name>(` up to the next `func`, or nil when there is no such function.
    private static func body(of name: String, in code: String) -> Substring? {
        guard let start = code.range(of: "func \(name)(") else { return nil }
        let end = code.range(of: "func ", range: start.upperBound..<code.endIndex)?.lowerBound ?? code.endIndex
        return code[start.upperBound..<end]
    }

    /// What `NotchTimerView` must take from the metrics rather than spell out.
    static let metricsTheNotchUses = [
        "TimerComposerMetrics.tabHorizontalPadding", "TimerComposerMetrics.tabVerticalPadding",
        "TimerComposerMetrics.tabColumnSpacing", "TimerComposerMetrics.stackedFieldWidth",
        "TimerComposerMetrics.durationRowSpacing",
    ]

    /// The numbers `TimerComposerMetrics` mirrors from `ContentView` and matters.swift, and the ones
    /// `NotchTimerView` takes from it.
    private static func mirrorProblems(contentView: String, sizes: String, notch: String) -> [String] {
        typealias M = TimerComposerMetrics
        var problems: [String] = []
        if !contentView.contains(".padding([.horizontal, .bottom], vm.notchState == .open ? \(Int(M.openNotchBottomPadding)) : 0)") {
            problems.append("the open notch's bottom padding is not openNotchBottomPadding")
        }
        if !(contentView.contains("activeCornerRadiusInsets.opened.bottom - 5")
             && sizes.contains("(opened: (top: 19, bottom: \(Int(M.openNotchSideInset + 5)))")) {
            problems.append("the open notch's side inset is not openNotchSideInset")
        }
        if !sizes.contains("return \(Int(M.smallestOpenNotchWidth))") {
            problems.append("the narrowest open notch is not smallestOpenNotchWidth")
        }
        problems += metricsTheNotchUses.filter { !notch.contains($0) }.map { "NotchTimerView does not use \($0)" }
        return problems
    }

    /// Line numbers of `.help(` on a line that is not a comment (the pre-commit hook's rule).
    private static func helpCalls(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard line.contains(".help("), !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { return nil }
            return String(index + 1)
        }
    }
}
