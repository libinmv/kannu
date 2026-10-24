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

import Defaults
import Defaults
import SwiftUI

/// The timer tab's right-hand column, beside the composer, while no timer runs. It has up to two
/// pages (`TimerSidePage`):
///
/// - **Tasks**, with tasks and the timer on: a toolbar (search, the Show in notch filter, Refresh,
///   Time to log) level with the session name field, then the task order
///   (`TasksManager.activeTasks`), each row with its title, key, "42m of 2h" and ▶. The header's
///   Tasks button hides while this page can show (`TasksHeaderVisibility`);
/// - **Presets**, with Show presets in the notch tab on: the preset cards, as before.
///
/// The page fills the column from the session name field's line down to the tab's bottom line.
/// With both pages, small "Tasks · Presets" labels hang below that line, centred in the footer
/// (`TimerComposerMetrics.sidePagerFooterOffset`), as an overlay that takes no layout room, so
/// neither the tab nor the notch grows for them. With one page there are no labels.
///
/// `NotchTimerView` owns the selected page, seeds it from `initialPage` each time the tab appears,
/// and changes it (`select`) for a label click and for a two-finger swipe anywhere on the tab
/// (`HorizontalSwipeMonitor`), so there is one way a page changes.
///
/// The Tasks page is a view of its own, built only while it is shown, so `TasksManager` is never
/// created while tasks are off (the `TasksHeaderButton` pattern). Hovering the column holds the
/// notch's own scroll gesture off, or scrolling a list would blur or close the notch.
///
/// Both pages scroll in a `ScrollView` of a `LazyVStack`, never a `List`: a `List`'s table view
/// keeps the trackpad gesture from the tab's swipe monitor, and a swipe over it does not turn the
/// page (`presetsPage`; `TimerSideColumnRulesTests` holds the rule). The `ScrollView` scrolls only
/// vertically, and the monitor takes every sideways (horizontal-dominant) event before the view
/// under the pointer sees it, so the swipe works over the rows too.
///
/// Tooltips are `.hoverTooltip`; `.help` never renders in the notch (docs/REGRESSIONS.md entry 9).
struct TimerSideColumn: View {
    @Environment(\.notchForeground) private var notchForeground
    private typealias M = TimerComposerMetrics

    @EnvironmentObject private var vm: KannuViewModel
    /// The page picked, or the one the tab opened on (`shownPage(_:in:)` resolves it).
    let page: TimerSidePage
    /// Shows a page: `NotchTimerView.selectSidePage`, the one implementation.
    let select: (TimerSidePage) -> Void
    let tasksAvailable: Bool
    let presetsAvailable: Bool
    /// The tab's height budget (`NotchTimerView.maxTabContentHeight`): the labels hang from its
    /// bottom line.
    let budget: CGFloat
    /// The shown page's height, ending where the composer does (`TimerComposerMetrics.sidePageHeight`).
    let pageHeight: CGFloat
    /// The column's width, the golden split of the notch (`TimerComposerMetrics.sideColumnWidth`).
    let columnWidth: CGFloat
    let presets: [TimerPreset]
    let activePresetID: UUID?
    let startPreset: (TimerPreset) -> Void
    /// A task started from its ▶: its name wins over a typed session name.
    let taskStarted: () -> Void
    /// The pencil on a task's card: the left panel becomes the task form for it.
    let editTask: (UUID) -> Void

    /// `@State`, so the token survives a re-render and the release names the token that was set.
    @State private var scrollSuppressionToken = UUID()
    @State private var isSuppressingScroll = false
    /// Whether the Presets list has scrolled past its first card (`SideListEdgeFades`).
    @State private var presetsScrolled = false

    /// The pages that exist, left to right.
    static func pages(tasksAvailable: Bool, presetsAvailable: Bool) -> [TimerSidePage] {
        TimerSidePage.allCases.filter { $0 == .tasks ? tasksAvailable : presetsAvailable }
    }

    /// The page the tab opens on. "Connected" means a source's scope is set (`TaskSource.isConnected`):
    /// a Sync switch only decides what is fetched, and a paused source's tasks stay listed. Read from
    /// the Defaults display copies only: no `TasksManager` and no Keychain, so opening the tab never
    /// builds or unlocks anything.
    static func initialPage(tasksAvailable: Bool, presetsAvailable: Bool) -> TimerSidePage {
        TimerSidePage.initial(
            tasksAvailable: tasksAvailable,
            presetsAvailable: presetsAvailable,
            anySourceConnected: TaskSource.remoteSources.contains { $0.isConnected }
        )
    }

    /// The selected page, or the only one there is.
    static func shownPage(_ page: TimerSidePage, in pages: [TimerSidePage]) -> TimerSidePage {
        pages.contains(page) ? page : (pages.first ?? .presets)
    }

    private var pages: [TimerSidePage] {
        Self.pages(tasksAvailable: tasksAvailable, presetsAvailable: presetsAvailable)
    }

    private var shownPage: TimerSidePage {
        Self.shownPage(page, in: pages)
    }

    private var hasPager: Bool { pages.count > 1 }

    var body: some View {
        pageView
            .id(shownPage)
            .transition(.opacity)
            .frame(width: columnWidth, alignment: .leading)
            .frame(maxHeight: budget, alignment: .top)
            // Hangs below the tab's bottom line, into the footer: an overlay takes no room.
            .overlay(alignment: .bottom) {
                if hasPager {
                    pager
                        .offset(y: M.sidePagerFooterOffset)
                }
            }
            .ownsVerticalScroll()
            .onHover { hovering in
                updateScrollSuppression(hovering)
            }
            .onDisappear {
                updateScrollSuppression(false)
            }
    }

    // MARK: - Labels

    /// "Tasks · Presets", centred under the column: the shown page bright, the other dimmed.
    /// Clicking one shows it; VoiceOver reads the pair as a two-option picker.
    private var pager: some View {
        HStack(spacing: 5) {
            ForEach(Array(pages.enumerated()), id: \.element) { index, item in
                if index > 0 {
                    Text(verbatim: "·")
                        .foregroundStyle(notchForeground.opacity(0.3))
                }
                Button {
                    select(item)
                } label: {
                    Text(item.title)
                        .foregroundStyle(item == shownPage ? notchForeground : notchForeground.opacity(0.4))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .frame(height: M.sidePagerHeight)
        .accessibilityRepresentation {
            Picker(String(localized: "Timer column"), selection: pageSelection) {
                ForEach(pages) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var pageSelection: Binding<TimerSidePage> {
        Binding(get: { shownPage }, set: { select($0) })
    }

    // MARK: - Pages

    @ViewBuilder
    private var pageView: some View {
        switch shownPage {
        case .tasks:
            TimerTasksPage(height: pageHeight, width: columnWidth, started: taskStarted, edit: editTask)
        case .presets:
            presetsPage
        }
    }

    /// The preset cards, unchanged from before the column had pages. A `ScrollView` of a
    /// `LazyVStack`, as the Tasks page has it, never a `List`: a `List` is an `NSTableView` in an
    /// `NSScrollView`, which can follow a trackpad gesture in an event loop of its own once the
    /// gesture's first, often motionless, event reaches it (the swipe monitor hands that one back).
    /// A local monitor never sees the events such a loop takes, so a swipe over the cards did not
    /// turn the page. Each card keeps the 2 pt above and below that was its list row inset.
    @ViewBuilder
    private var presetsPage: some View {
        if presets.isEmpty {
            Text("Configure presets in Brain to see them here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(notchForeground.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            let computedHeight = CGFloat(presets.count) * 60 + 4
            let listHeight = min(pageHeight, computedHeight)
            ZStack {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(presets) { preset in
                            TimerPresetCard(preset: preset, isActive: activePresetID == preset.id) {
                                startPreset(preset)
                            }
                            // Below only: the first card's top sits level with the composer's
                            // name field, instead of 2 pt under a black band.
                            .padding(.bottom, 4)
                        }
                    }
                    .sideListOffsetProbe()
                }
                .scrollIndicators(.never)
                .sideListScrollTracking(isScrolled: $presetsScrolled)

                SideListEdgeFades(showsTop: presetsScrolled)
            }
            .frame(height: listHeight)
        }
    }

    private func updateScrollSuppression(_ hovering: Bool) {
        guard hovering != isSuppressingScroll else { return }
        isSuppressingScroll = hovering
        vm.setScrollGestureSuppression(hovering, token: scrollSuppressionToken)
    }
}

extension TimerSidePage {
    var title: String {
        switch self {
        case .tasks: return String(localized: "Tasks")
        case .presets: return String(localized: "Presets")
        }
    }
}

/// The Tasks page: the task list, with its icons in a rail in the gap beside it.
///
/// - **The rail** (`rail`), an overlay hung into the gap between the composer and the page, where
///   the divider was: search, which opens a field at the top of the page that narrows the list as
///   the user types (`TaskSearch`); the Show in notch filter (`TaskSourceMenu`, the popover's own,
///   with Show all, Connect and Manage tasks…); Refresh, while Jira or GitLab syncs, whose tooltip
///   says when each last synced; and Time to log, a clock with Kannu's yellow "needs your input"
///   dot, while an entry asks. An overlay takes no room, so the gap stays the divider's 41 pt and
///   nothing moves when the page changes.
/// - **The list**: the task order as it stands (`TasksManager.activeTasks`), narrowed by Show in
///   notch and the search, so the first row is what the user ordered first. The whole page tall,
///   ending where Start and Reset do. A row expands into its card (`TimerTaskDetail`), and the
///   clock opens the Time to log cards (`TimerLogTimePage`); the rail stays beside both.
///
/// Appearing refreshes a stale Jira or GitLab sync, as the Tasks popover does. Its text fields —
/// search, and a Time to log card's — hold the notch open while focused, each under a token of its
/// own, released when the focus goes, the page goes, or the notch's window stops being key.
///
/// A view of its own, built only while the page is shown, so `TasksManager` exists only with tasks
/// on. It reads no secret: keys and titles are the sources' own text and render verbatim.
private struct TimerTasksPage: View {
    @Environment(\.notchForeground) private var notchForeground
    private typealias M = TimerComposerMetrics

    @EnvironmentObject private var vm: KannuViewModel
    @ObservedObject private var manager = TasksManager.shared
    // Show in notch (`TaskSourceMenu`): what the list shows, read as the popover reads it.
    @ObservedObject private var preferences = TaskSourcePreferences.shared
    /// The page's height (`TimerComposerMetrics.sidePageHeight`): a card's and the Log page's.
    let height: CGFloat
    /// The column's width (`TimerComposerMetrics.sideColumnWidth`): the card's and the Log page's.
    let width: CGFloat
    let started: () -> Void
    /// Opens the left panel's task form on a task (`TimerTaskForm`).
    let edit: (UUID) -> Void
    /// Whether the list has scrolled past its first row (`SideListEdgeFades`).
    @State private var isScrolled = false
    /// The task whose card has replaced the list (`TimerTaskDetail`); nil shows the rows. Cleared
    /// when that task leaves the list, so a deleted or resynced-away task never strands the card.
    @State private var expandedTaskID: UUID?
    /// The card's inline delete confirmation; reset whenever the card closes.
    @State private var confirmsDelete = false
    /// The row under the pointer: its one hover slides its clipped title and caption together.
    @State private var hoveredRowID: UUID?
    /// What the search has typed; kept while a card is open, so closing it returns to the results.
    @State private var searchText = ""
    /// Whether the search field shows at the top of the page.
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool
    /// `@State`, so the release names the token that was set.
    @State private var searchEditingToken = UUID()
    /// Whether the Time to log cards have replaced the list.
    @State private var showsLogTime = false
    /// The entries whose card has a focused field; each holds the notch open under its own id.
    @State private var focusedDrafts: Set<UUID> = []
    /// A menu opened here (the filter, a Time to log card's ⋯) is a window of its own: the pointer
    /// leaves the notch to use it, so the notch stays open while a menu tracks.
    @State private var menuTrackingToken = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let maxLogCards = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch manager.loadState {
            case .loading:
                statusRow(String(localized: "Loading tasks…"))
            case .failed:
                statusRow(String(localized: "Tasks could not be read"))
            case .ready:
                readyContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height, alignment: .top)
        // Hung into the gap, centred on the divider's line; it takes no room.
        .overlay(alignment: .topLeading) {
            rail
                .offset(x: -M.railOffset)
        }
        .onChange(of: manager.activeTasks.map(\.id)) { _, ids in
            if let expandedTaskID, !ids.contains(expandedTaskID) {
                self.expandedTaskID = nil
                confirmsDelete = false
            }
        }
        // The last entry answered (or put off): back to the list.
        .onChange(of: asking.isEmpty) { _, isEmpty in
            if isEmpty { showsLogTime = false }
        }
        .onChange(of: searchFocused) { _, isFocused in
            vm.setAutoCloseSuppression(isFocused, token: searchEditingToken)
        }
        // A click into another app leaves a field focused in a window that is no longer key: drop
        // it, which lets the notch auto-close again.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard note.object is KannuWindow else { return }
            searchFocused = false
            releaseDraftFocus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            vm.setAutoCloseSuppression(true, token: menuTrackingToken)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            vm.setAutoCloseSuppression(false, token: menuTrackingToken)
        }
        // The latest order, as the Tasks popover does it: a source syncs only when its last sync is
        // over 5 minutes old and no rate limit runs, and never with the Keychain dialog.
        .onAppear {
            manager.syncAllIfStale()
        }
        // Closing the notch or switching tabs removes this view without a focus change.
        .onDisappear {
            vm.setAutoCloseSuppression(false, token: searchEditingToken)
            vm.setAutoCloseSuppression(false, token: menuTrackingToken)
            releaseDraftFocus()
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        let expanded = manager.activeTasks.first(where: { $0.id == expandedTaskID })
        let showsLog = expanded == nil && showsLogTime && !asking.isEmpty
        let isCovered = expanded != nil || showsLog
        // The list stays in the tree under a card or the Log page, hidden and inert, never rebuilt:
        // closing the card finds it scrolled exactly where it was. Swapped out, it came back at the
        // top (David: "not acceptable").
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: M.sideToolbarSpacing) {
                if isSearching {
                    // Drawn above the list, so its × tooltip opening downward is never painted over.
                    searchField
                        .frame(height: M.sideToolbarHeight)
                        .zIndex(1)
                }
                list
            }
            .opacity(isCovered ? 0 : 1)
            .allowsHitTesting(!isCovered)
            .accessibilityHidden(isCovered)

            if let expanded {
                TimerTaskDetail(
                    manager: manager,
                    task: expanded,
                    width: width,
                    height: height,
                    confirmsDelete: $confirmsDelete,
                    close: collapse,
                    start: { start(expanded) },
                    edit: { edit(expanded.id) }
                )
                .id(expanded.id)
                .transition(.opacity)
            } else if showsLog {
                TimerLogTimePage(asking: asking, maxCards: Self.maxLogCards, width: width, height: height, close: closeLogTime)
                    .environment(\.worklogFieldFocus, draftFocusChanged)
                    .transition(.opacity)
            }
        }
    }

    /// The whole page; under the search field while searching (`TimerComposerMetrics.sideListHeight`).
    private var listHeight: CGFloat {
        isSearching ? M.sideListHeight(pageHeight: height) : height
    }

    // MARK: - Show in notch and search

    /// A source that is not connected has no check item in the menu, so its kept tasks always show
    /// (`TaskSourcePreferences.hiddenInNotch`).
    private var isFiltered: Bool { preferences.isNarrowing }

    /// Show in notch over the connected baseline, as the popover has it. The task being timed always
    /// passes.
    private var notchFilter: TaskOrdering.Listed {
        TaskOrdering.viewFilter(hidden: preferences.hiddenInNotch, alwaysListed: manager.timing?.taskID)
    }

    /// Show all: every source back in the notch.
    private func showAllSources() {
        preferences.showAll()
    }

    private var shownTasks: [TaskItem] {
        TaskSearch.filter(TaskOrdering.active(manager.activeTasks, listed: notchFilter), query: searchText)
    }

    /// Search shows the list: an open card or the Log page closes first.
    private func openSearch() {
        confirmsDelete = false
        animate {
            expandedTaskID = nil
            showsLogTime = false
            isSearching = true
        }
        // After the field exists: focusing it in the same update finds nothing to focus.
        DispatchQueue.main.async { searchFocused = true }
    }

    /// The × and Escape: the search ends and the whole list comes back.
    private func closeSearch() {
        searchFocused = false
        searchText = ""
        animate { isSearching = false }
    }

    // MARK: - Time to log

    /// The entries asking now, as the popover's "Log time?" has them.
    private var asking: [WorklogDraft] {
        manager.openDrafts.filter(WorklogDrafts.isAskingNow)
    }

    /// The Log page shows ahead of the list but behind a card: an open card closes first.
    private func openLogTime() {
        searchFocused = false
        confirmsDelete = false
        animate {
            expandedTaskID = nil
            showsLogTime = true
        }
    }

    private func closeLogTime() {
        releaseDraftFocus()
        animate { showsLogTime = false }
    }

    /// A Time to log card's field gained or lost focus (`worklogFieldFocus`).
    private func draftFocusChanged(_ draftID: UUID, _ isFocused: Bool) {
        if isFocused {
            focusedDrafts.insert(draftID)
        } else {
            focusedDrafts.remove(draftID)
        }
        vm.setAutoCloseSuppression(isFocused, token: draftID)
    }

    private func releaseDraftFocus() {
        for draftID in focusedDrafts {
            vm.setAutoCloseSuppression(false, token: draftID)
        }
        focusedDrafts.removeAll()
    }

    // MARK: - Rail

    /// The icons in the gap between the composer and this page, centred on the divider's line
    /// (`NotchTimerView` hides its divider while this page shows): search, the filter, Refresh
    /// while Jira or GitLab syncs, and the Time to log clock while an entry asks. The first sits
    /// level with the session name field; items that come and go sit at the bottom, so search and
    /// the filter never move. Under them the divider's hairline runs to the page's bottom.
    ///
    /// Each slot draws above the ones under it, so a tooltip opening downward is never painted over.
    private var rail: some View {
        VStack(spacing: M.railSpacing) {
            railSlot {
                Button(action: toggleSearch) {
                    TimerRailIcon(systemName: "magnifyingglass", isActive: isSearching)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: isSearching ? String(localized: "Close search") : String(localized: "Search tasks")))
                .hoverTooltip(isSearching ? String(localized: "Close search") : String(localized: "Search tasks"), edge: .below)
            }
            .zIndex(4)
            railSlot {
                TaskSourceMenu(openBrain: { $0.open() }, style: .rail)
            }
            .zIndex(3)
            if !manager.syncStates.isEmpty {
                railSlot { refreshControl }
                    .zIndex(2)
            }
            if !asking.isEmpty {
                railSlot { logTimeButton }
                    .zIndex(1)
            }
            HStack(spacing: 0) {
                Divider()
            }
            .opacity(0.2)
            .frame(maxHeight: .infinity)
        }
        .frame(width: M.railButtonSize, height: height, alignment: .top)
    }

    /// One icon's slot: as tall as the session name field, the icon centred in it.
    private func railSlot<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: M.railButtonSize, height: M.railSlotHeight)
    }

    private func toggleSearch() {
        if isSearching {
            closeSearch()
        } else {
            openSearch()
        }
    }

    private func toggleLogTime() {
        if showsLogTime {
            closeLogTime()
        } else {
            openLogTime()
        }
    }

    /// The clock opens the cards; the dot says one waits for an answer (one being sent does not).
    private var logTimeButton: some View {
        let waiting = WorklogDrafts.waitingCount(manager.drafts)
        return Button(action: toggleLogTime) {
            TimerRailIcon(systemName: "clock", isActive: showsLogTime)
                .overlay(alignment: .topTrailing) {
                    if waiting > 0 {
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -2)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: Self.logTimeLabel(waiting: waiting)))
        .hoverTooltip(String(localized: "Time to log"), edge: .below)
    }

    static func logTimeLabel(waiting: Int) -> String {
        switch waiting {
        case ..<1: return String(localized: "Time to log")
        case 1: return String(localized: "Time to log, 1 entry waiting")
        default: return String(localized: "Time to log, \(waiting) entries waiting")
        }
    }

    /// Refresh, the popover's own rule: a spinner while either source syncs; otherwise the button,
    /// off while every source that syncs is rate limited. Redraws once when a limit ends, so it
    /// comes back on time; no polling. The click may ask macOS for a Keychain item, as the
    /// popover's does; a source that is off, syncing or rate limited is skipped by the manager.
    private var refreshControl: some View {
        TimelineView(.explicit(TaskSyncSummary.rateLimitEnds(manager.syncStates))) { context in
            let summary = TaskSyncSummary.tooltip(manager.syncStates, now: context.date)
            if manager.isAnySyncing {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: M.railButtonSize, height: M.railButtonSize)
                    .background(RailIconBackground())
                    .accessibilityLabel(Text(verbatim: String(localized: "Syncing tasks")))
                    .hoverTooltip(summary, edge: .below)
            } else {
                Button {
                    manager.refreshAll()
                } label: {
                    TimerRailIcon(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(!TaskSyncSummary.canRefresh(isReady: manager.isReady, manager.syncStates, at: context.date))
                .accessibilityLabel(Text(verbatim: String(localized: "Refresh tasks")))
                .accessibilityValue(Text(verbatim: summary))
                .hoverTooltip(summary, edge: .below)
            }
        }
    }

    /// At the top of the page while searching: the name field's look — the same height, fill and
    /// corners — so it lines up with the field across the tab. Escape or the × ends the search;
    /// Return only leaves the field.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(String(localized: "Search tasks"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
                .onExitCommand(perform: closeSearch)
            Button(action: closeSearch) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: String(localized: "Close search")))
            .hoverTooltip(String(localized: "Close search"), edge: .below)
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(notchForeground.opacity(0.08)))
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        let tasks = shownTasks
        if tasks.isEmpty {
            statusRow(emptyText, showsShowAll: isFiltered && !manager.activeTasks.isEmpty)
        } else {
            rows(tasks)
                .transition(.opacity)
        }
    }

    /// What an empty list means: nothing at all, nothing the search finds, or the filter hiding it all.
    private var emptyText: String {
        if manager.activeTasks.isEmpty { return String(localized: "No tasks") }
        if !searchText.allSatisfy(\.isWhitespace) { return String(localized: "No matching tasks") }
        return String(localized: "Nothing to show")
    }

    private func rows(_ tasks: [TaskItem]) -> some View {
        let shownRows = max(tasks.count, M.sideTaskMinimumRows)
        let rowsHeight = min(listHeight, M.sideTaskRowsHeight(count: shownRows))
        return ZStack {
            ScrollView(.vertical) {
                LazyVStack(spacing: M.sideRowSpacing) {
                    // The ScrollView clips its content (docs/TOOLTIPS.md rule 2): the first row's
                    // tooltip opens below, into the list; every other row's opens above, over the
                    // row before it, which is drawn first and so stays under the bubble.
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                        row(task, tooltipEdge: index == 0 ? .below : .above)
                    }
                }
                // Below only: the first row's top sits level with the session name field.
                .padding(.bottom, M.sideRowSpacing / 2)
                .sideListOffsetProbe()
            }
            .scrollIndicators(.never)
            .sideListScrollTracking(isScrolled: $isScrolled)

            SideListEdgeFades(showsTop: isScrolled)
        }
        .frame(height: rowsHeight)
    }

    /// Key and title on one line, "42m of 2h" under it, then ▶. The text is a button of its own:
    /// clicking it expands the task into its card, in the column's own frame.
    private func row(_ task: TaskItem, tooltipEdge: HoverTooltipEdge) -> some View {
        let progress = TaskTimeMath.progress(tracked: manager.trackedSeconds(of: task), estimate: task.effectiveEstimateSeconds)
        return HStack(spacing: 8) {
            Button {
                expand(task)
            } label: {
                // The title alone: a GitLab path key in front of it ate the whole line. Clipped,
                // both lines slide into view while the row is hovered — one hover for the row.
                let isHovered = hoveredRowID == task.id
                VStack(alignment: .leading, spacing: 1) {
                    HoverRevealText(task.title, font: .system(size: 12, weight: .semibold), isActive: isHovered)
                    HoverRevealText(
                        (Text(verbatim: [TaskDetailSummary.shortKey(for: task), progress.text].compactMap { $0 }.joined(separator: " · "))
                            + overText(progress.over))
                            .font(.system(size: 11, weight: .medium)),
                        isActive: isHovered
                    )
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        hoveredRowID = task.id
                    } else if hoveredRowID == task.id {
                        hoveredRowID = nil
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(verbatim: String(localized: "Shows the task's details")))
            Button {
                start(task)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(6)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!manager.isReady)
            .accessibilityLabel(Text(verbatim: String(localized: "Start timing \(task.title)")))
            .hoverTooltip(String(localized: "Start timing"), edge: tooltipEdge)
        }
        .padding(.horizontal, 10)
        .frame(height: M.sideTaskRowHeight)
        .background(TaskGlassBackground(color: manager.color(of: task)))
    }

    /// Opens the task's card in place of the list.
    private func expand(_ task: TaskItem) {
        confirmsDelete = false
        // The row under the pointer would go on sliding its text, out of sight under the card.
        hoveredRowID = nil
        animate { expandedTaskID = task.id }
    }

    private func collapse() {
        confirmsDelete = false
        animate { expandedTaskID = nil }
    }

    /// Every swap on the page — card, Log page, search — with the page switch's animation and
    /// reduced-motion rule (`NotchTimerView.selectSidePage`).
    private func animate(_ change: () -> Void) {
        if reduceMotion {
            change()
        } else {
            withAnimation(.smooth(duration: 0.2), change)
        }
    }

    /// " · 10m over", in orange, once a task is a minute or more past its estimate (as the popover).
    private func overText(_ over: Int?) -> Text {
        guard let over else { return Text(verbatim: "") }
        return Text(verbatim: " · ")
            + Text(verbatim: String(localized: "\(WorkDuration.format(over)) over")).foregroundStyle(.orange)
    }

    /// The task's name wins over a typed session name; when nothing starts, nothing else happens.
    private func start(_ task: TaskItem) {
        guard manager.start(task.id) else { return }
        started()
    }

    /// One quiet row in place of the list; "Show all" puts every source back when the filter is
    /// what empties it.
    private func statusRow(_ text: String, showsShowAll: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: text)
                .foregroundStyle(.secondary)
            if showsShowAll {
                Button(String(localized: "Show all"), action: showAllSources)
                    .buttonStyle(.link)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: M.sideTaskRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(notchForeground.opacity(0.05))
        )
    }
}

/// The Time to log cards in place of the task list, opened from the rail's clock: a "Log time?"
/// row level with the session name field, its × back to the list, then the cards (`LogTimeCards`, the popover's
/// own, so Log goes the one way it does everywhere) in a scrolling column, and "N more in Brain"
/// for the rest. The page closes itself when the last entry is answered (`TimerTasksPage`).
private struct TimerLogTimePage: View {
    private typealias M = TimerComposerMetrics

    let asking: [WorklogDraft]
    let maxCards: Int
    let width: CGFloat
    let height: CGFloat
    let close: () -> Void
    @State private var isScrolled = false

    var body: some View {
        VStack(alignment: .leading, spacing: M.sideToolbarSpacing) {
            HStack(spacing: 6) {
                Text("Log time?")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: M.sideToolbarHeight, height: M.sideToolbarHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: String(localized: "Back to tasks")))
                .hoverTooltip(String(localized: "Back to tasks"), edge: .below)
            }
            .frame(height: M.sideToolbarHeight)
            .zIndex(1)

            ZStack {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        LogTimeCards(asking: asking, maxCards: maxCards, openBrain: { $0.open() })
                    }
                    // The last card's answers clear the bottom fade.
                    .padding(.bottom, 16)
                    .sideListOffsetProbe()
                }
                .scrollIndicators(.never)
                .sideListScrollTracking(isScrolled: $isScrolled)

                SideListEdgeFades(showsTop: isScrolled)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }
}

/// The merge requests that close a GitLab issue, in place of its card, in the card's frame: a row
/// level with the session name field with Back (to the card) on the left and Close (to the list,
/// which kept its place) on the right; then the merge requests, each opening its page in the
/// browser. Loaded when it appears (`TasksManager.linkedMergeRequests`, which may ask for the
/// Keychain: the user clicked), kept by the manager until the task's next sync.
///
/// Takes the manager it is handed, like the card. Each row is one button whose label owns the
/// row's one hover (its clipped title slides), so it carries no tooltip: an arrow says it opens.
private struct TimerLinkedMRsPage: View {
    @Environment(\.notchForeground) private var notchForeground
    private typealias M = TimerComposerMetrics

    @ObservedObject var manager: TasksManager
    let task: TaskItem
    let width: CGFloat
    let height: CGFloat
    let back: () -> Void
    let close: () -> Void

    private enum Load: Equatable {
        case loading
        case done(TasksManager.LinkedMergeRequestsResult)
    }

    @State private var load: Load = .loading
    /// Try again bumps it, which runs the load again.
    @State private var attempt = 0
    @State private var isScrolled = false
    @State private var hoveredID: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: M.sideToolbarSpacing) {
            header
                .frame(height: M.sideToolbarHeight)
                .zIndex(1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .task(id: attempt) {
            load = .loading
            load = .done(await manager.linkedMergeRequests(for: task.id))
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: M.sideToolbarHeight, height: M.sideToolbarHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: String(localized: "Back to the task")))
            .hoverTooltip(String(localized: "Back"), edge: .below)

            Text("Linked merge requests")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: M.sideToolbarHeight, height: M.sideToolbarHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: String(localized: "Close")))
            .hoverTooltip(String(localized: "Close"), edge: .below)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch load {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
        case .done(.loaded(let items, let complete)):
            if items.isEmpty {
                note(String(localized: "No merge requests close this issue."))
            } else {
                mergeRequestRows(items, complete: complete)
            }
        case .done(.failed(let reason)):
            note(reason, retry: true)
        case .done(.needsKeychainApproval):
            note(String(localized: "macOS did not let Kannu read the saved GitLab token."), retry: true)
        case .done(.needsReconnect):
            note(String(localized: "To see them, reconnect GitLab in Brain › Tasks."))
        }
    }

    private func note(_ text: String, retry: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if retry {
                Button(String(localized: "Try Again")) { attempt += 1 }
                    .buttonStyle(.link)
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .padding(.horizontal, 10)
    }

    private func mergeRequestRows(_ items: [LinkedMergeRequest], complete: Bool) -> some View {
        ZStack {
            ScrollView(.vertical) {
                LazyVStack(spacing: M.sideRowSpacing) {
                    ForEach(items) { item in
                        row(item)
                    }
                    if !complete, let url = manager.gitlabBrowseURL(for: task) {
                        // GitLab has more than one page of them: the issue lists them all.
                        Button(String(localized: "More on GitLab")) { NSWorkspace.shared.open(url) }
                            .buttonStyle(.link)
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                    }
                }
                .padding(.bottom, M.sideRowSpacing / 2)
                .sideListOffsetProbe()
            }
            .scrollIndicators(.never)
            .sideListScrollTracking(isScrolled: $isScrolled)

            SideListEdgeFades(showsTop: isScrolled)
        }
    }

    /// The state as a dot, the title (sliding when clipped), "!12 · Merged · Kim Lee", and an arrow:
    /// a click opens it in the browser.
    private func row(_ item: LinkedMergeRequest) -> some View {
        let caption = [item.reference, Self.stateName(item.state), item.isDraft ? String(localized: "Draft") : nil, item.author]
            .compactMap { $0 }
            .joined(separator: " · ")
        return Button {
            if let url = item.webURL { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Self.stateColor(item.state))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HoverRevealText(item.title, font: .system(size: 12, weight: .semibold), isActive: hoveredID == item.id)
                    Text(verbatim: caption)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if item.webURL != nil {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: M.sideTaskRowHeight)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(notchForeground.opacity(0.06)))
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    hoveredID = item.id
                } else if hoveredID == item.id {
                    hoveredID = nil
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(item.webURL == nil)
        .accessibilityLabel(Text(verbatim: "\(item.title), \(caption)"))
        .accessibilityHint(Text(verbatim: String(localized: "Opens it in GitLab")))
    }

    static func stateName(_ state: LinkedMergeRequest.State?) -> String? {
        switch state {
        case .opened: return String(localized: "Open")
        case .merged: return String(localized: "Merged")
        case .closed: return String(localized: "Closed")
        case .locked: return String(localized: "Locked")
        case nil: return nil
        }
    }

    /// Open green, merged purple, closed red, as GitLab colours them; locked or unknown grey.
    static func stateColor(_ state: LinkedMergeRequest.State?) -> Color {
        switch state {
        case .opened: return .green
        case .merged: return .purple
        case .closed: return .red
        case .locked, nil: return .secondary
        }
    }
}

/// The dark fades at a list's top and bottom edges, over the rows. The bottom one always says
/// "more below"; the top one appears only once rows have scrolled under it — at rest it darkened
/// the first row's top 16 pt, which read as a black gap above a misaligned list.
private struct SideListEdgeFades: View {
    @Environment(\.notchFill) private var notchFill
    let showsTop: Bool

    var body: some View {
        ZStack {
            if showsTop {
                LinearGradient(colors: [(notchFill ?? .black).opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 16)
                    .alignmentGuide(.top) { d in d[.top] }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            }

            LinearGradient(colors: [.clear, (notchFill ?? .black).opacity(0.65)], startPoint: .top, endPoint: .bottom)
                .frame(height: 16)
                .alignmentGuide(.bottom) { d in d[.bottom] }
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }
}

/// How far a side list has scrolled, for `SideListEdgeFades`. A preference, not
/// `onScrollGeometryChange`: the deployment target is macOS 14.
private struct SideListOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private let sideListSpace = "sideList"

private extension View {
    /// On a ScrollView's content: reports where the content's top edge is in the list's space.
    func sideListOffsetProbe() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: SideListOffsetKey.self, value: proxy.frame(in: .named(sideListSpace)).minY)
        })
    }

    /// On the ScrollView: names the space the probe measures in, and flips `isScrolled` once rows
    /// have gone under the top edge (with a 1 pt allowance for bounce and rounding).
    func sideListScrollTracking(isScrolled: Binding<Bool>) -> some View {
        coordinateSpace(name: sideListSpace)
            .onPreferenceChange(SideListOffsetKey.self) { offset in
                let scrolled = offset < -1
                if scrolled != isScrolled.wrappedValue {
                    withAnimation(.easeInOut(duration: 0.15)) { isScrolled.wrappedValue = scrolled }
                }
            }
    }
}

/// One task, expanded in the column's own frame in place of the list, laid out like its ticket
/// page: the title first, a row of chips (the short key, where it stands, a draft, its labels), up
/// to four facts in a two-column grid (each an icon and a few words: due date, health, milestone,
/// weight, parent, who, checklist, linked MRs, comments, updated…), and a bottom row with Start,
/// its time and — for a local task — delete; for a Jira or GitLab task a link to open it, since
/// deleting one would only have the next sync bring it back. The × at the top right collapses it.
/// Delete confirms inline, in that bottom row: no modal, since alerts under the notch have
/// misbehaved (docs/REGRESSIONS.md entry 14).
///
/// **Contained, always.** The card is exactly the column's width and the page's height: it never
/// grows, whatever its words. A chip row too wide for it (a long label once pushed the × and the
/// open icon off the notch) drops labels, then truncates the key, through `ViewThatFits`; the
/// fact grid takes the height left over and shows two rows, one, or none to fit it.
///
/// Takes the manager it is handed: `TasksManager.shared` is read by `TimerTasksPage` alone, so
/// the manager exists only while the Tasks page shows. The words come from `TaskDetailSummary`.
private struct TimerTaskDetail: View {
    private typealias M = TimerComposerMetrics

    @ObservedObject var manager: TasksManager
    let task: TaskItem
    /// The column's width (`TimerComposerMetrics.sideColumnWidth`).
    let width: CGFloat
    let height: CGFloat
    @Binding var confirmsDelete: Bool
    let close: () -> Void
    let start: () -> Void
    /// The pencil: the left panel's task form, on this task.
    let edit: () -> Void
    /// The linked merge requests page, in place of the card (`TimerLinkedMRsPage`).
    @State private var showsLinkedMRs = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let horizontalPadding: CGFloat = 10
    private static let factColumnSpacing: CGFloat = 10
    /// Two columns across what the padding leaves of the column: 86 pt each in the narrowest notch.
    private var factColumnWidth: CGFloat {
        max(0, (width - 2 * Self.horizontalPadding - Self.factColumnSpacing) / 2)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsLinkedMRs {
                TimerLinkedMRsPage(
                    manager: manager,
                    task: task,
                    width: width,
                    height: height,
                    back: { showLinkedMRs(false) },
                    close: close
                )
                .transition(.opacity)
            } else {
                card
                    .transition(.opacity)
            }
        }
    }

    /// The linked page in, or the card back; the page switch's animation and reduced-motion rule.
    private func showLinkedMRs(_ shows: Bool) {
        if reduceMotion {
            showsLinkedMRs = shows
        } else {
            withAnimation(.smooth(duration: 0.2)) { showsLinkedMRs = shows }
        }
    }

    @ViewBuilder
    private var card: some View {
        let summary = TaskDetailSummary(task: task, tracked: manager.trackedSeconds(of: task), now: Date(), selfNames: TaskSource.selfNames)
        VStack(alignment: .leading, spacing: 0) {
            // Drawn above the rows below it, so the × tooltip (opening downward) is never
            // painted over by the chips — siblings paint in order, zIndex decides between them.
            // No colour dot: the card's own tint is the colour, and a dot that draws nothing for
            // plain glass still took its width and indented the title past the chips.
            HStack(alignment: .top, spacing: 6) {
                // Two lines; a longer title slides up into view while hovered, then settles.
                HoverRevealText(summary.title, font: .system(size: 13, weight: .semibold), lines: 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    edit()
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(5)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.top, -3)
                .padding(.trailing, -6)
                .accessibilityLabel(Text(verbatim: String(localized: "Edit Task")))
                .hoverTooltip(String(localized: "Edit Task"), edge: .below)
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(5)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.top, -3)
                .padding(.trailing, -5)
                .accessibilityLabel(Text(verbatim: String(localized: "Close")))
                .hoverTooltip(String(localized: "Close"), edge: .below)
            }
            .zIndex(2)
            // Above the fact grid, so the key pill's status tooltip (opening downward) is never
            // covered by it; below the title row, whose × tooltip opens over this row.
            chipRow(summary)
                .padding(.top, 5)
                .zIndex(1)
            factGrid(summary.facts, note: summary.note)
                .padding(.top, 6)
                // The flexible child: the grid gets the height the rows above and below leave.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            bottomRow(summary)
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 7)
        // Exactly the column's width and the page's height: no word on the card can widen it.
        .frame(width: width, height: height, alignment: .topLeading)
        .background(TaskGlassBackground(color: manager.color(of: task), base: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// The key (or "Local") coloured by where the task stands, a draft, then as many labels as fit
    /// and a "+N" for the rest. Tries every label first and gives way one label at a time; when
    /// even the key does not fit, it truncates in the middle.
    private func chipRow(_ summary: TaskDetailSummary) -> some View {
        let labels = summary.labels
        return ViewThatFits(in: .horizontal) {
            ForEach((0...labels.count).reversed(), id: \.self) { shown in
                chips(summary, labels: Array(labels.prefix(shown)), hidden: labels.count - shown, keyTruncates: false)
            }
            chips(summary, labels: [], hidden: labels.count, keyTruncates: true)
        }
    }

    private func chips(_ summary: TaskDetailSummary, labels: [String], hidden: Int, keyTruncates: Bool) -> some View {
        HStack(spacing: 4) {
            // The status is the key pill's colour, not a word of its own: yellow to do, green in
            // progress, red closed. The word is its tooltip and what VoiceOver reads.
            let key = summary.shortKey ?? String(localized: "Local")
            SideChip(key, tint: Self.phaseColor(summary.status.phase), monospaced: summary.shortKey != nil, truncates: keyTruncates)
                // A label, not a button: "Status: Open", never a bare "Open" that reads as an action.
                .accessibilityLabel(Text(verbatim: String(localized: "\(key), status \(summary.status.name)")))
                .hoverTooltip(String(localized: "Status: \(summary.status.name)"), edge: .below)
            if summary.isDraft {
                SideChip(String(localized: "Draft"))
            }
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                SideChip(label)
            }
            if hidden > 0 {
                SideChip("+\(hidden)")
                    .accessibilityLabel(Text(verbatim: String(localized: "\(hidden) more labels")))
            }
        }
    }

    /// Up to four facts, two per row, in the height left over: two rows when they fit, one when
    /// a two-line title leaves room for only one, none when even that would crowd Start. A
    /// never-timed local task's note comes after its facts and gives way before them.
    private func factGrid(_ facts: [TaskDetailSummary.Fact], note: String?) -> some View {
        ViewThatFits(in: .vertical) {
            if let note {
                VStack(alignment: .leading, spacing: 4) {
                    if !facts.isEmpty {
                        factRows(Array(facts.prefix(2)))
                    }
                    noteText(note)
                }
            }
            if facts.count > 2 {
                factRows(Array(facts.prefix(4)))
            }
            if !facts.isEmpty {
                factRows(Array(facts.prefix(2)))
            }
            if let note {
                noteText(note)
            }
            Color.clear.frame(height: 0)
        }
    }

    /// Muted, not an alert: nothing is wrong with a task that has not been started.
    private func noteText(_ note: String) -> some View {
        Text(verbatim: note)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func factRows(_ facts: [TaskDetailSummary.Fact]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(stride(from: 0, to: facts.count, by: 2)), id: \.self) { first in
                HStack(spacing: Self.factColumnSpacing) {
                    factCell(facts[first])
                    if first + 1 < facts.count {
                        factCell(facts[first + 1])
                    }
                }
            }
        }
    }

    /// A fact that opens something is a button: the linked merge requests open their page.
    @ViewBuilder
    private func factCell(_ fact: TaskDetailSummary.Fact) -> some View {
        switch fact.action {
        case .linkedMergeRequests:
            Button {
                showLinkedMRs(true)
            } label: {
                FactCell(fact: fact, width: factColumnWidth, opens: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: String(localized: "\(fact.text), show them")))
            .hoverTooltip(String(localized: "Show linked merge requests"), edge: .above)
        case nil:
            FactCell(fact: fact, width: factColumnWidth)
        }
    }

    /// The key pill's colour for where the task stands.
    static func phaseColor(_ phase: TaskDetailSummary.Phase) -> Color {
        switch phase {
        case .toDo: return .yellow
        case .inProgress: return .green
        case .closed: return .red
        }
    }

    /// "42m of 2h · 10m over", the overtime in orange, beside Start.
    private func timeText(_ summary: TaskDetailSummary) -> Text {
        var text = Text(verbatim: summary.time)
        if let overtime = summary.overtime {
            text = text + Text(verbatim: " · ") + Text(verbatim: overtime).foregroundStyle(.orange)
        }
        return text
    }

    @ViewBuilder
    private func bottomRow(_ summary: TaskDetailSummary) -> some View {
        if confirmsDelete {
            HStack(spacing: 6) {
                Text("Delete? Its recorded time goes too.")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button(String(localized: "Keep")) {
                    confirmsDelete = false
                }
                .buttonStyle(.bordered)
                Button(String(localized: "Delete"), role: .destructive) {
                    manager.delete(task.id)
                    close()
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        } else {
            HStack(spacing: 8) {
                Button {
                    start()
                } label: {
                    Label(String(localized: "Start"), systemImage: "play.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!manager.isReady)
                // Only once there is something to say: "No estimate" beside every untimed
                // GitLab issue was noise.
                if summary.showsTime {
                    HoverRevealText(timeText(summary).font(.system(size: 11, weight: .medium)))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                // Into the archive at once, any task: a remote task's delete. It leaves the task
                // order, so the card collapses on its own (`TimerTasksPage`'s onChange).
                Button {
                    manager.archive(task.id)
                } label: {
                    Image(systemName: "archivebox")
                        .font(.system(size: 11, weight: .medium))
                        .padding(5)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: String(localized: "Archive")))
                .hoverTooltip(String(localized: "Archive"), edge: .above)
                if summary.canDelete {
                    Button {
                        confirmsDelete = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                            .padding(5)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: String(localized: "Delete task")))
                    .hoverTooltip(String(localized: "Delete task"), edge: .above)
                } else if let label = summary.browseLabel, let url = browseURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .medium))
                            .padding(5)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: label))
                    .hoverTooltip(label, edge: .above)
                }
            }
        }
    }

    /// The issue's page on its own server; nil for a local task or an unverifiable URL.
    private var browseURL: URL? { manager.browseURL(for: task) }
}

/// A small capsule for the card's chip row: the house neutral chip (caption size, white 0.12), or
/// a tinted one for a state (tint text on a 0.15 wash). Exactly as wide as its text, unless it is
/// the chip allowed to give way (`truncates`), which shortens in the middle instead. Also the key
/// chip under a running task's name (`NotchTimerView`).
struct SideChip: View {
    @Environment(\.notchForeground) private var notchForeground
    let text: String
    var tint: Color? = nil
    var monospaced = false
    var truncates = false

    init(_ text: String, tint: Color? = nil, monospaced: Bool = false, truncates: Bool = false) {
        self.text = text
        self.tint = tint
        self.monospaced = monospaced
        self.truncates = truncates
    }

    var body: some View {
        let chip = Text(verbatim: text)
            .font(.system(size: 10, weight: .semibold, design: monospaced ? .monospaced : .default))
            .foregroundStyle(tint ?? Color.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint?.opacity(0.15) ?? notchForeground.opacity(0.12)))
        if truncates {
            chip.fixedSize(horizontal: false, vertical: true)
        } else {
            chip.fixedSize()
        }
    }
}

/// One cell of the card's fact grid: a small icon and a few words, one line, a fixed column width
/// so the two columns line up. Orange when the fact needs attention.
private struct FactCell: View {
    let fact: TaskDetailSummary.Fact
    let width: CGFloat
    /// It opens something: a chevron says so, and the button around it owns the one hover (its
    /// tooltip), so the text does not slide.
    var opens = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: fact.icon)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 12)
                .accessibilityHidden(true)
            if opens {
                HoverRevealText(fact.text, font: .system(size: 11, weight: .medium), isActive: false)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .accessibilityHidden(true)
            } else {
                // Clipped at the column's width, it slides into view while hovered.
                HoverRevealText(fact.text, font: .system(size: 11, weight: .medium))
            }
        }
        .foregroundStyle(fact.isAlert ? Color.orange : Color.secondary)
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// One preset on the Presets page. Moved here unchanged from `NotchTimerView`.
private struct TimerPresetCard: View {
    @Environment(\.notchForeground) private var notchForeground
    let preset: TimerPreset
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .fill(preset.color.gradient)
                    .frame(width: 30, height: 30)
                    .overlay(
                        Circle()
                            .stroke(notchForeground.opacity(0.3), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(preset.formattedDuration)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(preset.color)

                Spacer()

                Image(systemName: isActive ? "checkmark" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isActive ? preset.color : Color.secondary)
                    .padding(6)
                    .background(isActive ? preset.color.opacity(0.2) : notchForeground.opacity(0.08))
                    .clipShape(Circle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isActive ? preset.color.opacity(0.12) : notchForeground.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }
}
