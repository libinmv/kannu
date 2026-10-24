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

import AppKit
import SwiftUI

/// The typed search's list, under the timer tab's session bar and a new task's title (David,
/// 2026-10-23: "dynamic typed search … user can select that or make new"). Two tasks at most, the
/// same title first (`TaskSearch.suggestions`), then `New task "…"`; nothing at all when no task
/// matches, so a plain session's name leaves the composer alone.
///
/// It reads `TasksManager`, so `NotchTimerView` never has to: the host passes what is typed and
/// keeps the list's state (`TaskSuggestionState`), and draws the list only with tasks on. Rows come
/// from the tasks the notch lists. The list has no background of its own: what it lies over is
/// covered (`coveredBySuggestions`), so it reads on any notch skin.
struct TimerTaskSuggestions: View {
    @Environment(\.notchForeground) private var notchForeground
    @ObservedObject private var manager = TasksManager.shared
    @ObservedObject private var preferences = TaskSourcePreferences.shared
    private typealias M = TimerComposerMetrics

    let typed: String
    @Binding var state: TaskSuggestionState
    let pick: (TaskSuggestionState.Row) -> Void

    @State private var hoveredRow: TaskSuggestionState.Row?
    /// The New row's + takes a colour dot's width (`TaskColorDot`, 10 pt), so the text lines up.
    private static let markWidth: CGFloat = 10

    /// The rows for what is typed, among the tasks the notch lists; none until the file is read.
    private var found: [TaskSuggestionState.Row] {
        guard manager.isReady else { return [] }
        let listed = TaskOrdering.active(manager.activeTasks, listed: TaskOrdering.viewFilter(
            hidden: preferences.hiddenInNotch, alwaysListed: manager.timing?.taskID))
        return TaskSuggestionState.rows(for: TaskSearch.suggestions(listed, typed: typed), typed: typed)
    }

    var body: some View {
        // Drawn from the state's rows, which the host's cover reads too: the list and what it
        // covers change in the same pass.
        VStack(spacing: 0) {
            ForEach(Array(state.rows.enumerated()), id: \.element) { index, row in
                rowButton(row, isHighlighted: index == state.highlighted)
            }
        }
        .padding(M.suggestionListPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        // Held while hovered, so a click lands even if the field lets go of focus on the way.
        .onHover { state.isHovered = $0 }
        .onChange(of: found, initial: true) { _, rows in
            let appeared = state.rows.isEmpty && !rows.isEmpty
            state.show(rows)
            if appeared { announce(Self.countAnnouncement(rows)) }
        }
        .onChange(of: state.highlighted) { _, _ in
            if let row = state.highlightedRow { announce(label(row)) }
        }
        // Never a stale row or hover flag the next time it shows.
        .onDisappear {
            state.show([])
            state.isHovered = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Matching tasks"))
    }

    private func rowButton(_ row: TaskSuggestionState.Row, isHighlighted: Bool) -> some View {
        Button {
            pick(row)
        } label: {
            HStack(spacing: 6) {
                rowContent(row)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: M.suggestionRowHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(notchForeground.opacity(isHighlighted ? 0.16 : hoveredRow == row ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Never takes the field's focus, so the field keeps typing and the notch stays open.
        .focusable(false)
        .onHover { hovering in
            if hovering {
                hoveredRow = row
            } else if hoveredRow == row {
                hoveredRow = nil
            }
        }
        .accessibilityLabel(Text(verbatim: label(row)))
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    @ViewBuilder
    private func rowContent(_ row: TaskSuggestionState.Row) -> some View {
        switch row {
        case .task(let id, let title):
            let task = manager.tasks.first { $0.id == id }
            if let task {
                TaskColorDot(color: manager.color(of: task))
                if let key = TaskDetailSummary.shortKey(for: task) {
                    SideChip(key, monospaced: true, truncates: true)
                }
            }
            Text(verbatim: title)
                .foregroundStyle(notchForeground)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if let task, let progress = progressText(task) {
                Text(verbatim: progress)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        case .newTask(let name):
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: Self.markWidth)
                .accessibilityHidden(true)
            Text(verbatim: String(localized: "New task “\(name)”"))
                .foregroundStyle(notchForeground)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    /// "42m of 2h", or "42m tracked"; nothing for a task with neither time nor an estimate.
    private func progressText(_ task: TaskItem) -> String? {
        let tracked = manager.trackedSeconds(of: task)
        guard tracked > 0 || task.effectiveEstimateSeconds != nil else { return nil }
        return TaskTimeMath.progress(tracked: tracked, estimate: task.effectiveEstimateSeconds).text
    }

    /// What VoiceOver reads for a row, and announces when the keyboard highlights it.
    private func label(_ row: TaskSuggestionState.Row) -> String {
        switch row {
        case .task(let id, let title):
            guard let task = manager.tasks.first(where: { $0.id == id }) else { return title }
            let key = TaskDetailSummary.shortKey(for: task).map { String(localized: "Task \($0)") }
            return [title, key, progressText(task)].compactMap { $0 }.joined(separator: ", ")
        case .newTask(let name):
            return String(localized: "New task “\(name)”")
        }
    }

    private static func countAnnouncement(_ rows: [TaskSuggestionState.Row]) -> String {
        let tasks = rows.filter { if case .task = $0 { return true } else { return false } }.count
        return tasks == 1 ? String(localized: "1 matching task") : String(localized: "\(tasks) matching tasks")
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}

/// The colour of the task picked in the session bar, before its name. Glass draws nothing but
/// keeps the frame.
struct TimerTaskPickDot: View {
    @ObservedObject private var manager = TasksManager.shared
    let taskID: UUID

    var body: some View {
        if let task = manager.tasks.first(where: { $0.id == taskID }) {
            TaskColorDot(color: manager.color(of: task))
        }
    }
}

/// After the picked task's name in the session bar: its short key and "42m of 2h". When the task
/// leaves the list (done, archived, resynced away), `lost` runs and the host drops the pick. A
/// rename is not followed: the session is named by the task's current title when it starts.
struct TimerTaskPickInfo: View {
    @ObservedObject private var manager = TasksManager.shared
    let taskID: UUID
    let lost: () -> Void

    private var task: TaskItem? {
        manager.activeTasks.first { $0.id == taskID }
    }

    var body: some View {
        HStack(spacing: 4) {
            if let task {
                if let key = TaskDetailSummary.shortKey(for: task) {
                    SideChip(key, monospaced: true, truncates: true)
                        .accessibilityLabel(Text(verbatim: String(localized: "Task \(key)")))
                }
                let tracked = manager.trackedSeconds(of: task)
                if tracked > 0 || task.effectiveEstimateSeconds != nil {
                    Text(verbatim: TaskTimeMath.progress(tracked: tracked, estimate: task.effectiveEstimateSeconds).text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .onAppear(perform: check)
        .onChange(of: manager.activeTasks.map(\.id)) { _, _ in check() }
    }

    private func check() {
        guard manager.isReady, task == nil else { return }
        lost()
    }
}

extension View {
    /// What the typed search's list lies over while it shows: hidden, inert, disabled (so a hidden
    /// field takes neither Tab nor a click) and out of VoiceOver's way, but kept in the tree, so its
    /// fields are never rebuilt.
    func coveredBySuggestions(_ covered: Bool) -> some View {
        opacity(covered ? 0 : 1)
            .allowsHitTesting(!covered)
            .disabled(covered)
            .accessibilityHidden(covered)
    }

    /// ↑, ↓ and Tab for the typed search's list while it shows. A focused text field's editor takes
    /// these keys before SwiftUI sees them, so a local key monitor reads them instead: only while
    /// `isActive`, only in Kannu's notch window while it is key, and never while an input method is
    /// composing (marked text), whose candidates the arrows move. `move` says whether the list took
    /// an arrow, and `tab` (which closes the list) whether it took the Tab; a key not taken goes on
    /// to the field.
    func suggestionListKeys(isActive: Bool, move: @escaping (Int) -> Bool, tab: @escaping () -> Bool) -> some View {
        modifier(SuggestionListKeys(isActive: isActive, move: move, tab: tab))
    }
}

private struct SuggestionListKeys: ViewModifier {
    let isActive: Bool
    let move: (Int) -> Bool
    let tab: () -> Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { update(isActive) }
            .onChange(of: isActive) { _, active in update(active) }
            .onDisappear { update(false) }
    }

    private func update(_ active: Bool) {
        if active, monitor == nil {
            let move = move, tab = tab
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let down: UInt16 = 125, up: UInt16 = 126, tabKey: UInt16 = 48
                guard [down, up, tabKey].contains(event.keyCode),
                      let window = event.window, window is KannuWindow, window.isKeyWindow,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
                if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
                if event.keyCode == tabKey { return tab() ? nil : event }
                return move(event.keyCode == down ? 1 : -1) ? nil : event
            }
        } else if !active, let token = monitor {
            NSEvent.removeMonitor(token)
            monitor = nil
        }
    }
}
