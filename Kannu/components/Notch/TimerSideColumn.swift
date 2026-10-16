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
/// - **Tasks**, with tasks and the timer on: the task order (`TasksManager.activeTasks`), each row
///   with its key and title, "42m of 2h" and ▶;
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
    private typealias M = TimerComposerMetrics

    @EnvironmentObject private var vm: KannuViewModel
    /// The page picked, or the one the tab opened on (`shownPage(_:in:)` resolves it).
    let page: TimerSidePage
    /// Shows a page: `NotchTimerView.selectSidePage`, the one implementation.
    let select: (TimerSidePage) -> Void
    let tasksAvailable: Bool
    let presetsAvailable: Bool
    /// The tab's height budget (`NotchTimerView.maxTabContentHeight`).
    let budget: CGFloat
    let presets: [TimerPreset]
    let activePresetID: UUID?
    let startPreset: (TimerPreset) -> Void
    /// A task started from its ▶: its name wins over a typed session name.
    let taskStarted: () -> Void

    /// `@State`, so the token survives a re-render and the release names the token that was set.
    @State private var scrollSuppressionToken = UUID()
    @State private var isSuppressingScroll = false
    /// Whether the Presets list has scrolled past its first card (`SideListEdgeFades`).
    @State private var presetsScrolled = false

    /// The pages that exist, left to right.
    static func pages(tasksAvailable: Bool, presetsAvailable: Bool) -> [TimerSidePage] {
        TimerSidePage.allCases.filter { $0 == .tasks ? tasksAvailable : presetsAvailable }
    }

    /// The page the tab opens on. "Connected" means a host is set, as `TasksManager.isJiraConnected`
    /// and `isGitLabConnected` have it: Sync Jira and Sync GitLab only decide what is fetched, and a
    /// paused source's tasks stay listed. Read from the Defaults display copies only: no
    /// `TasksManager` and no Keychain, so opening the tab never builds or unlocks anything.
    static func initialPage(tasksAvailable: Bool, presetsAvailable: Bool) -> TimerSidePage {
        TimerSidePage.initial(
            tasksAvailable: tasksAvailable,
            presetsAvailable: presetsAvailable,
            jiraConnected: !Defaults[.jiraSiteHost].isEmpty,
            gitlabConnected: !Defaults[.gitlabHost].isEmpty
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

    private var pageHeight: CGFloat {
        M.sidePageHeight(budget: budget)
    }

    var body: some View {
        pageView
            .id(shownPage)
            .transition(.opacity)
            .frame(width: M.sideColumnWidth, alignment: .leading)
            .frame(maxHeight: budget, alignment: .top)
            // Hangs below the tab's bottom line, into the footer: an overlay takes no room.
            .overlay(alignment: .bottom) {
                if hasPager {
                    pager
                        .offset(y: M.sidePagerFooterOffset)
                }
            }
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
                        .foregroundStyle(Color.white.opacity(0.3))
                }
                Button {
                    select(item)
                } label: {
                    Text(item.title)
                        .foregroundStyle(item == shownPage ? Color.white : Color.white.opacity(0.4))
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
            TimerTasksPage(height: pageHeight, started: taskStarted)
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
                .background(Color.white.opacity(0.05))
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

/// The Tasks page: the task order as it stands (`TasksManager.activeTasks`, the connected baseline,
/// with no notch or Task list filter), so the first row is what the user ordered first. Appearing
/// refreshes a stale Jira or GitLab sync, as the Tasks popover does.
///
/// A view of its own, built only while the page is shown, so `TasksManager` exists only with tasks
/// on. It reads no secret: keys and titles are the sources' own text and render verbatim.
private struct TimerTasksPage: View {
    private typealias M = TimerComposerMetrics

    @ObservedObject private var manager = TasksManager.shared
    /// The page's height (`TimerComposerMetrics.sidePageHeight`).
    let height: CGFloat
    let started: () -> Void
    /// Whether the list has scrolled past its first row (`SideListEdgeFades`).
    @State private var isScrolled = false
    /// The task whose card has replaced the list (`TimerTaskDetail`); nil shows the rows. Cleared
    /// when that task leaves the list, so a deleted or resynced-away task never strands the card.
    @State private var expandedTaskID: UUID?
    /// The card's inline delete confirmation; reset whenever the card closes.
    @State private var confirmsDelete = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch manager.loadState {
            case .loading:
                statusRow(String(localized: "Loading tasks…"))
            case .failed:
                statusRow(String(localized: "Tasks could not be read"))
            case .ready:
                let tasks = manager.activeTasks
                if tasks.isEmpty {
                    statusRow(String(localized: "No tasks"))
                } else if let expanded = tasks.first(where: { $0.id == expandedTaskID }) {
                    TimerTaskDetail(
                        manager: manager,
                        task: expanded,
                        height: height,
                        confirmsDelete: $confirmsDelete,
                        close: collapse,
                        start: { start(expanded) }
                    )
                    .id(expanded.id)
                    .transition(.opacity)
                } else {
                    rows(tasks)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height, alignment: .top)
        .onChange(of: manager.activeTasks.map(\.id)) { _, ids in
            if let expandedTaskID, !ids.contains(expandedTaskID) {
                self.expandedTaskID = nil
                confirmsDelete = false
            }
        }
        // The latest order, as the Tasks popover does it: a source syncs only when its last sync is
        // over 5 minutes old and no rate limit runs, and never with the Keychain dialog.
        .onAppear {
            manager.syncJiraIfStale()
            manager.syncGitLabIfStale()
        }
    }

    private func rows(_ tasks: [TaskItem]) -> some View {
        let shownRows = max(tasks.count, M.sideTaskMinimumRows)
        let listHeight = min(height, M.sideTaskRowsHeight(count: shownRows))
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
                // Below only: the first row's top sits level with the composer's name field.
                .padding(.bottom, M.sideRowSpacing / 2)
                .sideListOffsetProbe()
            }
            .scrollIndicators(.never)
            .sideListScrollTracking(isScrolled: $isScrolled)

            SideListEdgeFades(showsTop: isScrolled)
        }
        .frame(height: listHeight)
    }

    /// Key and title on one line, "42m of 2h" under it, then ▶. The text is a button of its own:
    /// clicking it expands the task into its card, in the column's own frame.
    private func row(_ task: TaskItem, tooltipEdge: HoverTooltipEdge) -> some View {
        let progress = TaskTimeMath.progress(tracked: manager.trackedSeconds(of: task), estimate: task.effectiveEstimateSeconds)
        return HStack(spacing: 8) {
            Button {
                expand(task)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    // The title alone: a GitLab path key in front of it ate the whole line.
                    Text(verbatim: task.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    (Text(verbatim: [TaskDetailSummary.shortKey(for: task), progress.text].compactMap { $0 }.joined(separator: " · "))
                        + overText(progress.over))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
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

    /// Opens the task's card in place of the list; the page switch's animation and reduced-motion
    /// rule (`NotchTimerView.selectSidePage`).
    private func expand(_ task: TaskItem) {
        confirmsDelete = false
        if reduceMotion {
            expandedTaskID = task.id
        } else {
            withAnimation(.smooth(duration: 0.2)) { expandedTaskID = task.id }
        }
    }

    private func collapse() {
        confirmsDelete = false
        if reduceMotion {
            expandedTaskID = nil
        } else {
            withAnimation(.smooth(duration: 0.2)) { expandedTaskID = nil }
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

    private func statusRow(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: M.sideTaskRowHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
    }
}

/// The dark fades at a list's top and bottom edges, over the rows. The bottom one always says
/// "more below"; the top one appears only once rows have scrolled under it — at rest it darkened
/// the first row's top 16 pt, which read as a black gap above a misaligned list.
private struct SideListEdgeFades: View {
    let showsTop: Bool

    var body: some View {
        ZStack {
            if showsTop {
                LinearGradient(colors: [Color.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 16)
                    .alignmentGuide(.top) { d in d[.top] }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            }

            LinearGradient(colors: [.clear, Color.black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
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
    let height: CGFloat
    @Binding var confirmsDelete: Bool
    let close: () -> Void
    let start: () -> Void

    private static let horizontalPadding: CGFloat = 10
    private static let factColumnSpacing: CGFloat = 10
    /// Two columns across what the padding leaves of the column: 105 pt each.
    private static let factColumnWidth = (M.sideColumnWidth - 2 * horizontalPadding - factColumnSpacing) / 2

    var body: some View {
        let summary = TaskDetailSummary(task: task, tracked: manager.trackedSeconds(of: task), now: Date(), selfNames: Self.selfNames)
        VStack(alignment: .leading, spacing: 0) {
            // Drawn above the rows below it, so the × tooltip (opening downward) is never
            // painted over by the chips — siblings paint in order, zIndex decides between them.
            // No colour dot: the card's own tint is the colour, and a dot that draws nothing for
            // plain glass still took its width and indented the title past the chips.
            HStack(alignment: .top, spacing: 6) {
                Text(verbatim: summary.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            factGrid(summary.facts)
                .padding(.top, 6)
                // The flexible child: the grid gets the height the rows above and below leave.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            bottomRow(summary)
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 7)
        // Exactly the column's width and the page's height: no word on the card can widen it.
        .frame(width: M.sideColumnWidth, height: height, alignment: .topLeading)
        .background(TaskGlassBackground(color: manager.color(of: task), base: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// The connected accounts, so the user's own name never takes a fact.
    private static var selfNames: Set<String> {
        Set([Defaults[.gitlabAccountDisplayName], Defaults[.gitlabUsername], Defaults[.jiraAccountDisplayName]]
            .filter { !$0.isEmpty })
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
                .accessibilityLabel(Text(verbatim: "\(key), \(summary.status.name)"))
                .hoverTooltip(summary.status.name, edge: .below)
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
    /// a two-line title leaves room for only one, none when even that would crowd Start.
    private func factGrid(_ facts: [TaskDetailSummary.Fact]) -> some View {
        ViewThatFits(in: .vertical) {
            if facts.count > 2 {
                factRows(Array(facts.prefix(4)))
            }
            if !facts.isEmpty {
                factRows(Array(facts.prefix(2)))
            }
            Color.clear.frame(height: 0)
        }
    }

    private func factRows(_ facts: [TaskDetailSummary.Fact]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(stride(from: 0, to: facts.count, by: 2)), id: \.self) { first in
                HStack(spacing: Self.factColumnSpacing) {
                    FactCell(fact: facts[first], width: Self.factColumnWidth)
                    if first + 1 < facts.count {
                        FactCell(fact: facts[first + 1], width: Self.factColumnWidth)
                    }
                }
            }
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
                    timeText(summary)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
    private var browseURL: URL? {
        switch task.source {
        case .local: return nil
        case .jira: return manager.jiraBrowseURL(for: task)
        case .gitlab: return manager.gitlabBrowseURL(for: task)
        }
    }
}

/// A small capsule for the card's chip row: the house neutral chip (caption size, white 0.12), or
/// a tinted one for a state (tint text on a 0.15 wash). Exactly as wide as its text, unless it is
/// the chip allowed to give way (`truncates`), which shortens in the middle instead.
private struct SideChip: View {
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
            .background(Capsule().fill(tint?.opacity(0.15) ?? Color.white.opacity(0.12)))
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

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: fact.icon)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 12)
                .accessibilityHidden(true)
            Text(verbatim: fact.text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(fact.isAlert ? Color.orange : Color.secondary)
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// One preset on the Presets page. Moved here unchanged from `NotchTimerView`.
private struct TimerPresetCard: View {
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
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
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
                    .background(isActive ? preset.color.opacity(0.2) : Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isActive ? preset.color.opacity(0.12) : Color.white.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }
}
