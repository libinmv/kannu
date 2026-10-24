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

/// What the timer tab's task form is for: a new task (the New Task button beside the session name
/// field), or one task's edit (the pencil on its expanded card, on the running card, or beside a
/// task picked in the session bar).
enum TimerTaskFormMode: Hashable {
    case add
    case edit(UUID)
}

/// The timer tab's task form, in place of the session name field and the composer, in their frame
/// (`TimerComposerMetrics.taskFormHeight`, under the composer's own height, so the notch never
/// grows): the title and a × where the New task button was; the estimate and tags; a local task's
/// reminder; then Add and Add & Start, or Save.
///
/// A Jira or GitLab task's title shows but is the server's (`TaskFormDraft`), and reminders are for
/// local tasks. Nothing is saved until Add or Save. What was typed is kept while the form is closed
/// (`KeptTaskFormDrafts`): the notch closing, another task's form opening and the × on a new task
/// all keep it; the × or Escape on an edit leaves without saving and drops it.
///
/// The bar and a new task's title are one text: New Task opens on the session bar's text
/// (`TaskFormDraft.newTask`), and the title goes back to the bar as it is typed, so however the form
/// closes the bar holds it. Typing a title offers tasks already in the list (`TimerTaskSuggestions`):
/// picking one opens its edit instead, so no second task is made.
///
/// A view of its own, built only while shown; `NotchTimerView` reaches the task list only through
/// this form's statics (`startFromForm`, `startNamed`, `prepareForTypedStart`), so it never names it.
/// While a field has focus, or one of its menus tracks, it holds the notch open under tokens of its
/// own, released when the focus goes, the form goes, or the notch's window stops being key.
struct TimerTaskForm: View {
    @Environment(\.notchForeground) private var notchForeground
    private typealias M = TimerComposerMetrics

    @EnvironmentObject private var vm: KannuViewModel
    @ObservedObject private var manager = TasksManager.shared
    let mode: TimerTaskFormMode
    /// Switches the form to another task's edit: a task picked from the title's typed search.
    let open: (TimerTaskFormMode) -> Void
    let close: () -> Void
    /// A task started from Add & Start: its name wins over a typed session name.
    let started: () -> Void

    @State private var draft: TaskFormDraft
    @FocusState private var focused: Field?
    /// `@State`, so the release names the token that was set.
    @State private var editingToken = UUID()
    @State private var menuTrackingToken = UUID()
    /// The pointer is on the tag chips: they stay while a click lands, even if the field lets go of
    /// focus on the way.
    @State private var chipsHovered = false
    /// The title's typed search (a new task only). Closed on the opening title, so the matches
    /// just seen under the session bar do not open again at once.
    @State private var titleSuggestions: TaskSuggestionState

    private enum Field: Hashable { case title, estimate, tags, reminder }

    init(mode: TimerTaskFormMode, open: @escaping (TimerTaskFormMode) -> Void, close: @escaping () -> Void,
         started: @escaping () -> Void) {
        self.mode = mode
        self.open = open
        self.close = close
        self.started = started
        let manager = TasksManager.shared
        let opening: TaskFormDraft
        switch mode {
        case .add:
            opening = TaskFormDraft.newTask(bar: TimerManager.shared.typedSessionName, kept: manager.keptFormDraft(editing: nil))
        case .edit(let id):
            let task = manager.tasks.first { $0.id == id }
            opening = manager.keptFormDraft(editing: id) ?? task.map(TaskFormDraft.init(editing:)) ?? TaskFormDraft()
        }
        _draft = State(initialValue: opening)
        _titleSuggestions = State(initialValue: TaskSuggestionState(closedOn: opening.title))
    }

    /// The title's typed search shows: a new task's title being typed, while the field has focus or
    /// the pointer is on the list (nothing else focused), until Esc, Return, Tab or a pick closes it.
    private var wantsTitleSuggestions: Bool {
        titleSuggestions.wantsToShow(enabled: draft.isNew && draft.canEditTitle, typed: draft.title,
                                     fieldFocused: focused == .title, otherFieldFocused: focused != nil && focused != .title)
    }

    /// The list has rows, so it covers the rows under the title (never the buttons).
    private var showsTitleSuggestions: Bool {
        titleSuggestions.shows(enabled: draft.isNew && draft.canEditTitle, typed: draft.title,
                               fieldFocused: focused == .title, otherFieldFocused: focused != nil && focused != .title)
    }

    private var editedTask: TaskItem? {
        guard case .edit(let id) = mode else { return nil }
        return manager.activeTasks.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: M.taskFormRowSpacing) {
            titleRow
                .frame(height: M.nameFieldHeight)
                .zIndex(3)
            // The estimate and the tags in the golden ratio, 1 : φ. The title's typed search hangs
            // from the title's bottom edge over this row and the next; covered first, then the list
            // on top: the other order hides the list too.
            GoldenRow(spacing: M.taskFormRowSpacing) {
                estimateField
                tagsField
            }
            .frame(height: M.taskFormRowHeight)
            .coveredBySuggestions(showsTitleSuggestions)
            .overlay(alignment: .top) {
                if wantsTitleSuggestions {
                    TimerTaskSuggestions(typed: draft.title, state: $titleSuggestions, pick: pickTitleSuggestion)
                        .offset(y: -M.taskFormRowSpacing)
                }
            }
            .zIndex(2)
            // While tags are typed, the tags in use take the reminder's row.
            Group {
                if showsTagChips {
                    tagChips
                } else {
                    reminderRow
                }
            }
            .coveredBySuggestions(showsTitleSuggestions)
            .frame(height: M.taskFormRowHeight)
            .zIndex(1)
            buttonRow
        }
        .frame(height: M.taskFormHeight, alignment: .top)
        .onAppear {
            if case .edit(let id) = mode, editedTask == nil {
                manager.forgetFormDraft(editing: id)
                close()
                return
            }
            // The bar and a new task's title are one text: the opening draft is kept at once (a bar
            // text that is not the kept title becomes its title), and the bar shows the title.
            if draft.isNew {
                manager.keepFormDraft(draft)
                TimerManager.shared.typedSessionName = TaskFormDraft.barText(draft.title)
            }
            // After the field exists: focusing it in the same update finds nothing to focus.
            let first: Field = draft.canEditTitle ? .title : .tags
            DispatchQueue.main.async { focused = first }
        }
        .onChange(of: focused) { previous, field in
            vm.setAutoCloseSuppression(field != nil, token: editingToken)
            // Leaving the estimate: "90m" reads back as "1h 30m".
            if previous == .estimate, field != .estimate { draft.settleEstimateText() }
            // Into another field: the title's list goes (a click on it keeps it while hovered).
            if previous == .title, field != nil, field != .title { titleSuggestions.close(on: draft.title) }
        }
        // What is typed is kept as it is typed, so closing the notch or opening another task's form
        // loses nothing (`KeptTaskFormDrafts`).
        .onChange(of: draft) { _, typed in manager.keepFormDraft(typed) }
        // A new task's title goes back to the session bar as it is typed: however the form closes,
        // the bar holds it.
        .onChange(of: draft.title) { _, title in
            titleSuggestions.textChanged(to: title)
            if draft.isNew { TimerManager.shared.typedSessionName = TaskFormDraft.barText(title) }
        }
        // A preset clicked while the estimate cannot be read starts nothing: the estimate takes
        // focus, uncovered once the title's list closes.
        .onChange(of: manager.estimateFocusRequests) { _, _ in
            guard draft.isNew else { return }
            titleSuggestions.close(on: draft.title)
            DispatchQueue.main.async { focused = .estimate }
        }
        .suggestionListKeys(isActive: showsTitleSuggestions, move: { titleSuggestions.move($0) }, tab: {
            // Tab goes on to the estimate, uncovered once the list closes.
            titleSuggestions.close(on: draft.title)
            DispatchQueue.main.async { focused = .estimate }
            return true
        })
        // The task left the list (done, deleted, archived, resynced away) while being edited.
        .onChange(of: manager.activeTasks.map(\.id)) { _, ids in
            if case .edit(let id) = mode, !ids.contains(id) {
                manager.forgetFormDraft(editing: id)
                close()
            }
        }
        // A click into another app leaves a field focused in a window that is no longer key: drop
        // it, which lets the notch auto-close again.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard note.object is KannuWindow else { return }
            focused = nil
        }
        // The estimate menu is a window of its own: the pointer leaves the notch to use it.
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            vm.setAutoCloseSuppression(true, token: menuTrackingToken)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            vm.setAutoCloseSuppression(false, token: menuTrackingToken)
        }
        .onDisappear {
            vm.setAutoCloseSuppression(false, token: editingToken)
            vm.setAutoCloseSuppression(false, token: menuTrackingToken)
        }
    }

    // MARK: - Rows

    /// The session name field's place and look; the × where the New task button was.
    private var titleRow: some View {
        HStack(spacing: M.nameFieldSpacing) {
            Group {
                if draft.canEditTitle {
                    HStack(spacing: 4) {
                        TextField(String(localized: "What needs doing?"), text: $draft.title)
                            .textFieldStyle(.plain)
                            .foregroundColor(notchForeground)
                            .tint(notchForeground)
                            .focused($focused, equals: .title)
                            .onSubmit(submitTitle)
                            .onExitCommand(perform: exitTitle)
                            .accessibilityLabel(Text("Task title"))
                        if !draft.title.isEmpty {
                            clearButton(label: String(localized: "Clear Title")) {
                                draft.title = ""
                                focused = .title
                            }
                        }
                    }
                } else {
                    Text(verbatim: draft.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(Text(verbatim: String(localized: "Task title, \(draft.title)")))
                }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(notchForeground.opacity(0.08)))

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(notchForeground.opacity(0.85))
                    .frame(width: M.nameFieldHeight, height: M.nameFieldHeight)
                    .background(notchForeground.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: closeLabel))
            .hoverTooltip(closeLabel, edge: .below)
        }
    }

    /// The ×'s tooltip and label: a new task's form only closes (what was typed stays); an edit's
    /// leaves without saving.
    private var closeLabel: String {
        draft.isNew ? String(localized: "Close") : String(localized: "Close Without Saving")
    }

    /// The × beside the title, and Escape: a new task's form closes and keeps what was typed; an
    /// edit closes without saving and drops its draft.
    private func dismiss() {
        if case .edit(let id) = mode { manager.forgetFormDraft(editing: id) }
        close()
    }

    /// Escape in the title: the typed search's list first, then the form (`answerEscape`).
    private func exitTitle() {
        switch titleSuggestions.answerEscape(showing: showsTitleSuggestions) {
        case .closeList: titleSuggestions.close(on: draft.title)
        case .pick, .passOn: dismiss()
        }
    }

    /// Return in the title: the row the arrows highlighted, else Add or Save (`answerReturn`).
    private func submitTitle() {
        switch titleSuggestions.answerReturn(showing: showsTitleSuggestions) {
        case .pick(let row):
            pickTitleSuggestion(row)
        case .closeList, .passOn:
            titleSuggestions.close(on: draft.title)
            submit()
        }
    }

    /// A task picked from the title's typed search opens its edit, so no second task is made; the
    /// rest of what was typed stays kept for the next New Task, and the bar's text, used up as a
    /// search, goes. The New row keeps adding.
    private func pickTitleSuggestion(_ row: TaskSuggestionState.Row) {
        switch row {
        case .task(let id, _):
            var rest = draft
            rest.title = ""
            manager.keepFormDraft(rest)
            TimerManager.shared.typedSessionName = ""
            open(.edit(id))
        case .newTask:
            titleSuggestions.close(on: draft.title)
            focused = .title
        }
    }

    /// The small ⓧ at the end of a text box that empties it, the way a search field's does. Never
    /// takes focus, so a click does not release the notch on its way.
    private func clearButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(Text(verbatim: label))
        .hoverTooltip(label, edge: .below)
    }

    /// Typed, in minutes, hours or days ("45", "1.5h", "2d 3h", a day being a workday), with the
    /// presets one click away on the chevron. While focused it shows what it understood ("= 19h");
    /// text it cannot read turns orange, and Add waits until it is fixed.
    private var estimateField: some View {
        HStack(spacing: 4) {
            TextField(draft.estimatePrompt, text: Binding(get: { draft.estimateText }, set: { draft.typeEstimate($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(draft.estimateReading == .unreadable ? .orange : notchForeground)
                .tint(notchForeground)
                .focused($focused, equals: .estimate)
                .onSubmit(submit)
                .onExitCommand(perform: dismiss)
                .accessibilityLabel(Text("Estimate"))
                .hoverTooltip(String(localized: "Type 45m, 1.5h or 2d 3h"), edge: .below)
            if focused == .estimate, let echo = draft.estimateEcho {
                Text(verbatim: echo)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Menu {
                Button(String(localized: "No estimate")) { draft.chooseEstimate(nil) }
                ForEach(draft.estimateMenuChoices, id: \.self) { seconds in
                    Button(WorkDuration.format(seconds)) { draft.chooseEstimate(seconds) }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("Estimate presets"))
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(notchForeground.opacity(0.08)))
    }

    private var tagsField: some View {
        HStack(spacing: 4) {
            TextField(String(localized: "Tags, comma separated"), text: $draft.tagsText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(notchForeground)
                .tint(notchForeground)
                .focused($focused, equals: .tags)
                .onSubmit(submit)
                .onExitCommand(perform: dismiss)
                .accessibilityLabel(Text("Tags"))
            if !draft.tagsText.isEmpty {
                clearButton(label: String(localized: "Clear Tags")) {
                    draft.tagsText = ""
                    focused = .tags
                }
            }
        }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(notchForeground.opacity(0.08)))
    }

    /// A local task's reminder: "Add a reminder", or the date and time, a ×, and the bell that turns
    /// this task's notification on or off (saved with the rest on Save). A field date picker, never
    /// the compact one: its calendar is a popover window, and the notch would close under it. While
    /// macOS blocks Kannu's notifications the bell turns orange, or, with no reminder yet, an orange
    /// slashed bell says so. Inset like the fields' text above it, so the row's first glyph lines up
    /// with theirs.
    private var reminderRow: some View {
        reminderContent
            .padding(.horizontal, 10)
    }

    @ViewBuilder
    private var reminderContent: some View {
        if draft.canSchedule {
            HStack(spacing: 6) {
                if draft.reminder != nil {
                    Image(systemName: draft.notifies ? "bell.fill" : "bell.slash.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    DatePicker(String(localized: "Reminder"), selection: reminderBinding, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .controlSize(.small)
                        .focused($focused, equals: .reminder)
                        .fixedSize()
                    Button {
                        draft.reminder = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: String(localized: "Remove reminder")))
                    .hoverTooltip(String(localized: "Remove reminder"), edge: .below)
                } else {
                    Button {
                        draft.reminder = TaskFormDraft.defaultReminder(now: Date(), calendar: .current)
                    } label: {
                        Label(String(localized: "Add a reminder"), systemImage: "bell")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                if draft.reminder != nil {
                    notificationToggle
                } else if manager.remindersBlocked {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .frame(width: 20, height: 20)
                        .accessibilityLabel(Text(verbatim: String(localized: "Notifications are off for Kannu")))
                        .hoverTooltip(String(localized: "Notifications are off for Kannu"), edge: .below)
                }
            }
        } else {
            Text("Reminders are for local tasks.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// This task's reminder notification, on or off; only this task's, saved with the form. Its
    /// tooltip and label name what a click does and flip with it (docs/TOOLTIPS.md). Orange while it
    /// is on but macOS denies Kannu's notifications, so it cannot show; VoiceOver hears why.
    private var notificationToggle: some View {
        let blocked = draft.notifies && manager.notificationsDenied
        let label = draft.notifies ? String(localized: "Mute Reminder") : String(localized: "Unmute Reminder")
        return Button {
            draft.notifies.toggle()
        } label: {
            Image(systemName: draft.notifies ? "bell" : "bell.slash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(blocked ? Color.orange : draft.notifies ? notchForeground.opacity(0.85) : Color.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(Text(verbatim: blocked ? String(localized: "Notifications are off for Kannu") : ""))
        .hoverTooltip(label, edge: .below)
    }

    // MARK: - Tags in use

    /// Brain's suggestions for the tag being typed, among every task's tags (`TaskFacets.tags`).
    private var tagPicks: [TaskTagEditing.Suggestion] {
        draft.tagSuggestions(existing: TaskFacets.tags(in: manager.tasks))
    }

    private var showsTagChips: Bool {
        (focused == .tags || chipsHovered) && !tagPicks.isEmpty
    }

    /// The tags in use for what is being typed, as chips with their colours, in one row: the ones
    /// that do not fit are left off the end, never wrapped. Inset like the fields' text.
    private var tagChips: some View {
        let picks = tagPicks
        return ViewThatFits(in: .horizontal) {
            ForEach((1...max(1, picks.count)).reversed(), id: \.self) { shown in
                HStack(spacing: 6) {
                    ForEach(Array(picks.prefix(shown)), id: \.self) { pick in
                        tagChip(pick)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        // The row's one hover; the chips carry no tooltip.
        .onHover { chipsHovered = $0 }
    }

    /// One tag in use (its colour dot; none for plain glass, so no empty gap), or the typed text as
    /// a new tag (a +). A click completes it into the field and keeps the field's focus.
    private func tagChip(_ pick: TaskTagEditing.Suggestion) -> some View {
        Button {
            draft.completeTag(pick.tag)
            focused = .tags
        } label: {
            HStack(spacing: 4) {
                switch pick {
                case .use(let tag):
                    if let tint = manager.tagColor(for: tag).tint {
                        Circle()
                            .fill(tint)
                            .frame(width: 7, height: 7)
                    }
                    Text(verbatim: tag)
                case .create(let tag):
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                    Text(verbatim: tag)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(notchForeground.opacity(0.9))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(notchForeground.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(Text(verbatim: String(localized: "Add tag \(pick.tag)")))
    }

    private var reminderBinding: Binding<Date> {
        Binding(
            get: { draft.reminder ?? TaskFormDraft.defaultReminder(now: Date(), calendar: .current) },
            set: { draft.reminder = $0 }
        )
    }

    /// The composer's Start and Reset, in their look: Add & Start green, Add grey; Save green. Add
    /// and Add & Start in the golden ratio, 1 : φ; Save alone fills the row.
    private var buttonRow: some View {
        GoldenRow(spacing: 10) {
            if draft.isNew {
                formButton(String(localized: "Add"), systemImage: "plus", prominent: false) { add(andStart: false) }
                formButton(String(localized: "Add & Start"), systemImage: "play.fill", prominent: true) { add(andStart: true) }
            } else {
                formButton(String(localized: "Save"), systemImage: "checkmark", prominent: true, action: save)
            }
        }
    }

    private func formButton(_ title: String, systemImage: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        let disabled = !manager.isReady || !draft.canSave
        return Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: M.buttonFontSize, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : notchForeground.opacity(0.9))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: M.buttonHeight)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(prominent ? Self.startColor.opacity(disabled ? 0.5 : 1) : notchForeground.opacity(0.16))
                )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(notchForeground.opacity(prominent ? 0.15 : 0), lineWidth: 1)
        )
        .opacity(disabled ? 0.7 : 1)
        .disabled(disabled)
    }

    /// The composer's Start green (`NotchTimerView.startButtonColor`).
    private static let startColor = Color(red: 0.142, green: 0.633, blue: 0.265)

    // MARK: - Saving

    /// Return in a field: Add for a new task, Save for an edit.
    private func submit() {
        if draft.isNew {
            add(andStart: false)
        } else {
            save()
        }
    }

    /// A local task at the top of the order, with its tags and reminder (`TasksManager.addTask(from:)`).
    /// The bar held its title, so the bar empties. Add & Start starts it the way its ▶ would; when
    /// nothing starts, the form still closes on the added task.
    private func add(andStart: Bool) {
        guard let id = manager.addTask(from: draft) else { return }
        TimerManager.shared.typedSessionName = ""
        guard andStart, manager.start(id) else {
            close()
            return
        }
        started()
    }

    /// Only what changed (`TasksManager.applyEdits`). A draft that cannot be saved, or whose task
    /// is gone, is dropped, and the form closes, as before.
    private func save() {
        guard case .edit(let id) = mode else {
            close()
            return
        }
        if !manager.applyEdits(draft, to: id) { manager.forgetFormDraft(editing: id) }
        close()
    }
}

// MARK: - The timer tab's ways into the task list

extension TimerTaskForm {
    /// A preset clicked while the form shows starts what the form shows, timed for the preset's
    /// length as the user's own block (it never follows the estimate). A new task is added as
    /// typed; an edit is saved when it can be (else it stays kept, and nothing is saved), and that
    /// task is timed while it is in the list. An edit never falls through to the bar.
    @MainActor static func startFromForm(_ mode: TimerTaskFormMode, duration: TimeInterval,
                                         preset: TimerPreset?) -> TimerFormStart {
        guard Defaults[.enableTasks] else { return .fallThrough }
        let manager = TasksManager.shared
        switch mode {
        case .add:
            let kept = manager.keptFormDraft(editing: nil)
            let outcome = TimerFormStart.forNewTask(kept)
            if outcome == .held { manager.requestEstimateFocus() }
            guard outcome == .started, let kept, let id = manager.addTask(from: kept) else {
                return outcome == .started ? .fallThrough : outcome
            }
            TimerManager.shared.typedSessionName = ""
            manager.startBlock(id, duration: duration, preset: preset)
            return .started
        case .edit(let id):
            let task = manager.activeTasks.first { $0.id == id }
            guard TimerFormStart.forEdit(taskInList: task != nil) == .started, let task else { return .gone }
            // An untouched form keeps no draft: the task as it reads.
            let draft = manager.keptFormDraft(editing: id) ?? TaskFormDraft(editing: task)
            if draft.canSave { manager.applyEdits(draft, to: id) }
            manager.startBlock(id, duration: duration, preset: preset)
            return .started
        }
    }

    /// A session started from the session bar, as `TimerTypedStart.route` says (David,
    /// 2026-10-23): a task picked from the bar's typed search is timed (if it is gone, `otherwise`,
    /// the plain named session, starts: a dead pick never makes or reuses a task); the New row's
    /// pick always makes a new task; plain typed text reuses the first local task with that title or
    /// makes one. Each is the user's own block. `otherwise` also runs when tasks are off or nothing
    /// can start.
    @MainActor static func startNamed(_ route: TimerTypedStart, typed: String, duration: TimeInterval,
                                      preset: TimerPreset?, otherwise: @escaping () -> Void) {
        guard Defaults[.enableTasks] else { return otherwise() }
        let manager = TasksManager.shared
        switch route {
        case .pickedTask(let taskID):
            if !manager.startBlock(taskID, duration: duration, preset: preset) { otherwise() }
        case .typed(let reuse):
            manager.startTyped(typed, reuse: reuse, duration: duration, preset: preset, otherwise: otherwise)
        case .plain:
            otherwise()
        }
    }

    /// Builds the task list ahead of a typed start, so the first one after launch need not wait for
    /// the file. Only for a name typed with tasks on; never because the tab appeared.
    @MainActor static func prepareForTypedStart() {
        guard Defaults[.enableTasks], Defaults[.enableTimerFeature] else { return }
        _ = TasksManager.shared
    }
}
