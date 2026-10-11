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

/// The notch's Tasks popover, opened by `TasksHeaderButton` (the `TimerPopover` pattern):
///
/// - a header with the source menu (`TaskSourceMenu`), Refresh with what each source's last sync
///   found, and a Brain glyph that opens Brain › Tasks at Sources;
/// - **Now**: the task being timed, with its live time, Pause and Stop;
/// - **Log time?**: the Time to log cards still asking (`WorklogDraftCard`, the very card Brain
///   shows, so Log goes the same one way it does there);
/// - **Up next**: Add a task… (a local task, at the top of the order), then the task order, at
///   most `TaskOrdering.upNextLimit` rows, each with its key, title, "42m of 2h" and ▶; or an
///   empty state;
/// - **Show all in Brain**.
///
/// Live time ticks through a `TimelineView`, once a second, only while the Now card is on screen
/// and running; the manager never publishes every second. Appearing asks each source for a sync
/// only when its last one is stale, and never with the Keychain dialog (`syncJiraIfStale`). This
/// view reads no secret: titles and keys are the sources' own text and render verbatim.
struct TasksPopover: View {
    @ObservedObject private var manager = TasksManager.shared
    @Default(.enableTimerFeature) private var enableTimerFeature
    @Default(.showLocalTasks) private var showLocalTasks
    @Default(.jiraEnabled) private var jiraEnabled
    @Default(.gitlabEnabled) private var gitlabEnabled
    @Default(.jiraSiteHost) private var jiraSiteHost
    @Default(.gitlabHost) private var gitlabHost
    @State private var newTitle = ""
    /// Closes the popover: `TasksHeaderButton` owns whether it is shown.
    let close: () -> Void

    /// Log time? cards shown; the rest wait in Brain › Tasks › Time to log.
    private static let maxCards = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            switch manager.loadState {
            case .loading:
                loadingRow
            case .failed(let reason):
                failureRow(reason)
            case .ready:
                readyContent
            }

            Divider()
                .padding(.horizontal, -8)

            Button("Show all in Brain") { openBrain(.taskList) }
                .buttonStyle(.link)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(16)
        .frame(width: 320)
        // The header's own font and grey reach into a popover's content; start from the defaults.
        .font(.body)
        .foregroundStyle(.primary)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .cornerRadius(12)
        )
        .onAppear {
            manager.syncJiraIfStale()
            manager.syncGitLabIfStale()
        }
        .onChange(of: jiraEnabled) { _, isOn in
            if isOn { manager.syncJiraIfStale() }
        }
        .onChange(of: gitlabEnabled) { _, isOn in
            if isOn { manager.syncGitLabIfStale() }
        }
    }

    /// Closes the popover, then opens Brain › Tasks at `destination`.
    private func openBrain(_ destination: TasksBrainDestination) {
        close()
        destination.open()
    }

    // MARK: - Header

    private var header: some View {
        // Redraws once when a rate limit ends, so Refresh comes back on time; no polling.
        TimelineView(.explicit(rateLimitEnds)) { context in
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tasks")
                        .font(.system(size: 14, weight: .semibold))
                    ForEach(syncLines(at: context.date), id: \.self) { line in
                        Text(verbatim: line)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                TaskSourceMenu(openBrain: openBrain)
                if manager.isJiraSyncOn || manager.isGitLabSyncOn {
                    refreshButton(at: context.date)
                }
                Button {
                    openBrain(.sources)
                } label: {
                    Image(systemName: "brain")
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Manage tasks in Brain")
                .hoverTooltip(String(localized: "Manage tasks in Brain"), edge: .below)
            }
        }
    }

    private var rateLimitEnds: [Date] {
        [manager.jiraSync.rateLimitEnd, manager.gitlabSync.rateLimitEnd].compactMap { $0 }.sorted()
    }

    /// "Jira · Synced 10:42", "GitLab · Offline": one line per source that is synced.
    private func syncLines(at date: Date) -> [String] {
        var lines: [String] = []
        if manager.isJiraSyncOn {
            lines.append(String(localized: "Jira · \(manager.jiraSync.shortCaption(now: date))"))
        }
        if manager.isGitLabSyncOn {
            lines.append(String(localized: "GitLab · \(manager.gitlabSync.shortCaption(now: date))"))
        }
        return lines
    }

    @ViewBuilder
    private func refreshButton(at date: Date) -> some View {
        if manager.isJiraSyncing || manager.isGitLabSyncing {
            ProgressView()
                .controlSize(.small)
                .frame(width: 20, height: 20)
        } else {
            // The user asked: each source may ask macOS for its Keychain item, and a source that
            // is off, syncing or rate limited is skipped by the manager.
            Button {
                manager.refreshJira()
                manager.refreshGitLab()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .disabled(!canRefresh(at: date))
            .accessibilityLabel("Refresh tasks")
            .hoverTooltip(String(localized: "Refresh Jira and GitLab"), edge: .below)
        }
    }

    private func canRefresh(at date: Date) -> Bool {
        guard manager.isReady else { return false }
        return canRefresh(manager.jiraSync, isOn: manager.isJiraSyncOn, at: date)
            || canRefresh(manager.gitlabSync, isOn: manager.isGitLabSyncOn, at: date)
    }

    private func canRefresh(_ state: SourceSyncState, isOn: Bool, at date: Date) -> Bool {
        guard isOn else { return false }
        return state.rateLimitEnd.map { $0 <= date } ?? true
    }

    // MARK: - Loading

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading tasks…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func failureRow(_ reason: String) -> some View {
        Text(verbatim: String(localized: "Couldn't read the task list, so it can't change. \(reason)"))
            .font(.system(size: 11))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Ready

    @ViewBuilder
    private var readyContent: some View {
        let timed = timedTask
        let asking = manager.openDrafts.filter(WorklogDrafts.isAskingNow)
        let cards = Array(asking.prefix(Self.maxCards))
        let rows = TaskOrdering.upNextRows(showingNow: timed != nil, cards: cards.count)
        let waitingNext = TaskOrdering.upNext(manager.activeTasks, excluding: manager.timing?.taskID, limit: .max)

        if let timed, let timing = manager.timing {
            nowSection(timed, isPaused: timing.isPaused)
        }
        if !cards.isEmpty {
            logTimeSection(cards, more: asking.count - cards.count)
        }
        if showLocalTasks || !waitingNext.isEmpty || timed == nil {
            upNextSection(Array(waitingNext.prefix(rows)), total: waitingNext.count, showsEmptyState: waitingNext.isEmpty && timed == nil)
        }
    }

    private var timedTask: TaskItem? {
        guard let id = manager.timing?.taskID else { return nil }
        return manager.tasks.first { $0.id == id }
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    /// The source's key ("PROJ-123", "group/app!12") over the title; both verbatim.
    private func taskName(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if let key = task.remote?.key {
                Text(verbatim: key)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(verbatim: task.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
        }
    }

    // MARK: - Now

    private func nowSection(_ task: TaskItem, isPaused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Now")
            VStack(alignment: .leading, spacing: 8) {
                taskName(task)
                if isPaused {
                    nowTime(task, at: Date(), isPaused: true)
                } else {
                    // Once a second, and only while this card is on screen.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        nowTime(task, at: context.date, isPaused: false)
                    }
                }
                HStack(spacing: 8) {
                    Button {
                        if isPaused {
                            manager.resumeTiming()
                        } else {
                            manager.pauseTiming()
                        }
                    } label: {
                        Label(isPaused ? String(localized: "Resume") : String(localized: "Pause"),
                              systemImage: isPaused ? "play.fill" : "pause.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        manager.stopTiming()
                    } label: {
                        Label(String(localized: "Stop"), systemImage: "stop.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// All the time recorded on the task, as a running clock, then "42m of 2h" and "10m over".
    private func nowTime(_ task: TaskItem, at date: Date, isPaused: Bool) -> some View {
        let tracked = manager.trackedSeconds(of: task, now: date)
        let progress = TaskTimeMath.progress(tracked: tracked, estimate: task.effectiveEstimateSeconds)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: WorkDuration.clock(tracked))
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundStyle(progress.over == nil ? Color.primary : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: isPaused ? String(localized: "Paused · \(progress.text)") : progress.text)
                if let over = progress.over {
                    Text(verbatim: String(localized: "\(WorkDuration.format(over)) over"))
                        .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Log time?

    private func logTimeSection(_ cards: [WorklogDraft], more: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Log time?")
            ForEach(cards) { draft in
                WorklogDraftCard(draft: draft)
                    .labeledContentStyle(StackedCardStyle())
                    .controlSize(.small)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if more > 0 {
                Button(more == 1 ? String(localized: "1 more in Brain") : String(localized: "\(more) more in Brain")) {
                    openBrain(.timeToLog)
                }
                .buttonStyle(.link)
                .font(.system(size: 12, weight: .medium))
            }
        }
    }

    // MARK: - Up next

    private func upNextSection(_ tasks: [TaskItem], total: Int, showsEmptyState: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("Up next")
                Spacer(minLength: 0)
                if total > tasks.count {
                    Text(verbatim: String(localized: "\(tasks.count) of \(total)"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            if showLocalTasks {
                addTaskField
            }
            if !enableTimerFeature && !tasks.isEmpty {
                Text("Turn on the timer in Brain to time tasks.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsEmptyState {
                emptyState
            }
            ForEach(tasks) { task in
                upNextRow(task)
            }
        }
    }

    /// A local task, added at the top of the order. Return adds it; nothing here sends anything.
    private var addTaskField: some View {
        HStack(spacing: 8) {
            TextField(String(localized: "Add a task…"), text: $newTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addTask)
            Button(action: addTask) {
                Image(systemName: "plus")
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .disabled(!manager.isReady || TaskItem.cleanedTitle(newTitle) == nil)
            .accessibilityLabel("Add task")
            .hoverTooltip(String(localized: "Add to the top"), edge: .above)
        }
    }

    private func addTask() {
        if manager.addTask(title: newTitle, estimateSeconds: nil) {
            newTitle = ""
        }
    }

    private func upNextRow(_ task: TaskItem) -> some View {
        let progress = TaskTimeMath.progress(tracked: manager.trackedSeconds(of: task), estimate: task.effectiveEstimateSeconds)
        let caption = [task.remote?.key, progress.text].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: task.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                (Text(verbatim: caption) + overText(progress.over))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                manager.start(task.id)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(6)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!enableTimerFeature || !manager.isReady)
            .accessibilityLabel(Text(verbatim: String(localized: "Start timing \(task.title)")))
            .hoverTooltip(String(localized: "Start timing"), edge: .above)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    /// " · 10m over", in orange, once a task is a minute or more past its estimate.
    private func overText(_ over: Int?) -> Text {
        guard let over else { return Text(verbatim: "") }
        return Text(verbatim: " · ")
            + Text(verbatim: String(localized: "\(WorkDuration.format(over)) over")).foregroundStyle(.orange)
    }

    private var emptyState: some View {
        let connected = !jiraSiteHost.isEmpty || !gitlabHost.isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: connected ? String(localized: "Nothing to do") : String(localized: "No tasks yet"))
                .font(.system(size: 13, weight: .semibold))
            Text(emptyMessage(connected: connected))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !connected {
                Button("Connect Jira or GitLab…") { openBrain(.sources) }
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func emptyMessage(connected: Bool) -> LocalizedStringKey {
        switch (connected, showLocalTasks) {
        case (false, true):
            return "Connect Jira or GitLab, or add a task above."
        case (false, false):
            return "Connect Jira or GitLab, or turn on Local."
        case (true, true):
            return "No open tasks. Add one above."
        case (true, false):
            return "No open tasks in the sources that are on."
        }
    }
}

/// The Time to log card, stacked to fit the popover: what would be logged on top, then the length,
/// the comment and the answers, trailing. In Brain the same card is a Form row.
private struct StackedCardStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
            configuration.content
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
