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

    /// The preset cards, unchanged from before the column had pages.
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
                List {
                    ForEach(presets) { preset in
                        TimerPresetCard(preset: preset, isActive: activePresetID == preset.id) {
                            startPreset(preset)
                        }
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)

                SideListEdgeFades()
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
                } else {
                    rows(tasks)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height, alignment: .top)
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
                .padding(.vertical, M.sideRowSpacing / 2)
            }
            .scrollIndicators(.never)

            SideListEdgeFades()
        }
        .frame(height: listHeight)
    }

    /// Key and title on one line, "42m of 2h" under it, then ▶.
    private func row(_ task: TaskItem, tooltipEdge: HoverTooltipEdge) -> some View {
        let progress = TaskTimeMath.progress(tracked: manager.trackedSeconds(of: task), estimate: task.effectiveEstimateSeconds)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                (keyText(task) + Text(verbatim: task.title))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                (Text(verbatim: progress.text) + overText(progress.over))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
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
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    /// "PROJ-123 " in a quiet monospaced face, for a Jira or GitLab task; nothing for a local one.
    private func keyText(_ task: TaskItem) -> Text {
        guard let key = task.remote?.key else { return Text(verbatim: "") }
        return Text(verbatim: key)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            + Text(verbatim: " ")
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

/// The dark fades at a list's top and bottom edges, over the rows.
private struct SideListEdgeFades: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 16)
                .alignmentGuide(.top) { d in d[.top] }
                .frame(maxHeight: .infinity, alignment: .top)

            LinearGradient(colors: [.clear, Color.black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                .frame(height: 16)
                .alignmentGuide(.bottom) { d in d[.bottom] }
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
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
