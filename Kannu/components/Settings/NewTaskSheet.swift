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

/// New Task's draft, held by the tab (`TasksSettings`) so Cancel keeps what was typed for the next
/// New Task. Kept in `@State`, never `@StateObject`: the tab must not observe it, so typing redraws
/// the sheet alone, not the page under it.
@MainActor
final class NewTaskDraft: ObservableObject {
    @Published var draft = TaskFormDraft()
}

/// New Task, from Add a task on All tasks and Local tasks: everything the notch's task form takes
/// (David, 2026-10-24: "we want all capabilties that we give for tasks in notch") — a title, a typed
/// estimate, tags with the ones in use offered as chips, a reminder with its notification on or
/// off — then Add, or Add & Start while the timer is on. The notch's own rules (`TaskFormDraft`),
/// saved through `TasksManager.insertTask`, so a task half-typed in the notch stays as it is.
///
/// Return adds from the title or the estimate. While a tag is being typed it completes the tag
/// instead (`TaskTagEditing.returnPick`), as in the Tags sheet; a second Return adds. A sheet pads its
/// own content; a Form row never does.
struct NewTaskSheet: View {
    @ObservedObject var newTask: NewTaskDraft
    /// All tasks' filters, so a new task they would hide opens on its own page instead of vanishing.
    let listFilter: TaskFilter
    /// Opens a task's page: the new one when the filters hide it, or the one a typed title repeats.
    let open: (UUID) -> Void
    @ObservedObject private var manager = TasksManager.shared
    @Default(.enableTimerFeature) private var enableTimerFeature
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Field?

    private enum Field: Hashable {
        case title
        case tags
    }

    /// As wide as the Connect sheets: room for the estimate and the tags side by side.
    private static let width: CGFloat = 420

    private var draft: TaskFormDraft { newTask.draft }
    private var canAdd: Bool { manager.isReady && draft.canSave }
    /// A tag half-typed: Return completes it, so Add gives up the Return key meanwhile.
    private var isTypingTag: Bool { focused == .tags && !draft.tagFragment.isEmpty }
    private var tagOffers: [TaskTagEditing.Suggestion] {
        draft.tagSuggestions(existing: TaskFacets.tags(in: manager.tasks))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowContent) {
            VStack(alignment: .leading, spacing: SettingsMetrics.labelStack) {
                Text("New Task")
                    .font(.headline)
                Text("A local task, added on top of your list. Cancel keeps what you typed.")
                    .settingsDescriptionStyle()
            }

            TextField("Title", text: $newTask.draft.title, prompt: Text("What needs doing?"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: .title)
                .onSubmit { add(andStart: false) }
            if let existing = TaskItem.reusable(titled: draft.title, in: manager.tasks) {
                HStack(spacing: SettingsMetrics.rowContent) {
                    Text(verbatim: String(localized: "“\(existing.title)” is already in your list."))
                        .settingsDescriptionStyle()
                    Button("Show Task") {
                        dismiss()
                        open(existing.id)
                    }
                }
            }

            // The notch's order and proportions: the estimate 1, the tags φ.
            GoldenRow(spacing: SettingsMetrics.rowContent) {
                TaskEstimateField(draft: $newTask.draft, onSubmit: { add(andStart: false) })
                TextField("Tags", text: $newTask.draft.tagsText, prompt: Text("Tags, comma separated"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .tags)
                    .onSubmit(submitTags)
                    .help(Text("The first tag sets the task's colour"))
            }
            if !tagOffers.isEmpty {
                tagOfferChips
            }

            reminder

            HStack(spacing: SettingsMetrics.rowContent) {
                if draft != TaskFormDraft() {
                    Button("Clear All") {
                        newTask.draft = TaskFormDraft()
                        focused = .title
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if enableTimerFeature {
                    Button {
                        add(andStart: true)
                    } label: {
                        Label("Add & Start", systemImage: "play.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canAdd)
                }
                Button("Add") { add(andStart: false) }
                    .keyboardShortcut(isTypingTag ? nil : .defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(width: Self.width)
        .onAppear {
            // macOS's answer may have changed since the list last asked: the note follows it.
            manager.checkReminderPermission()
            // A reminder kept from an earlier New Task that has passed since: the next whole hour.
            newTask.draft.movePassedReminder(now: Date(), calendar: .current)
            focused = .title
        }
    }

    // MARK: - Tags

    /// The tags in use for what is being typed, in their colours, then the typed text as a new tag;
    /// the one Return would take is ringed. A click completes it into the field.
    private var tagOfferChips: some View {
        let offers = tagOffers
        let returnPick = TaskTagEditing.returnPick(for: draft.tagFragment, in: offers)
        return SettingsFlowLayout {
            ForEach(offers, id: \.self) { offer in
                switch offer {
                case .use(let tag):
                    SettingsTagChip(adding: tag, kind: .use, tint: manager.tagColor(for: tag).tint,
                                    isHighlighted: offer == returnPick) { complete(offer) }
                case .create(let tag):
                    SettingsTagChip(adding: tag, kind: .create, isHighlighted: offer == returnPick) { complete(offer) }
                }
            }
        }
    }

    /// Return in the tags: completes the tag being typed, or adds the task once none is.
    private func submitTags() {
        if let pick = TaskTagEditing.returnPick(for: draft.tagFragment, in: tagOffers) {
            complete(pick)
        } else {
            add(andStart: false)
        }
    }

    private func complete(_ offer: TaskTagEditing.Suggestion) {
        newTask.draft.completeTag(offer.tag)
        focused = .tags
    }

    // MARK: - Reminder

    /// "Remind me" starts at the next whole hour, as the notch's "Add a reminder" does; Notify is
    /// its notification, on for a new task, as the notch's bell is.
    @ViewBuilder
    private var reminder: some View {
        HStack(spacing: SettingsMetrics.rowContent) {
            Toggle("Remind me", isOn: Binding(
                get: { draft.reminder != nil },
                set: { newTask.draft.reminder = $0 ? TaskFormDraft.defaultReminder(now: Date(), calendar: .current) : nil }
            ))
            .toggleStyle(.checkbox)
            if draft.reminder != nil {
                DatePicker("Remind me at", selection: Binding(
                    get: { draft.reminder ?? TaskFormDraft.defaultReminder(now: Date(), calendar: .current) },
                    set: { newTask.draft.reminder = $0 }
                ), in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
            }
        }
        if draft.reminder != nil {
            Toggle("Notify me when it's due", isOn: $newTask.draft.notifies)
                .toggleStyle(.checkbox)
            if draft.notifies {
                ReminderPermissionNote()
            }
        }
    }

    // MARK: - Add

    /// The task on top of the list, then, for Add & Start, timed as its ▶ would. The draft empties
    /// for the next New Task. When All tasks' filters would hide it, its page opens, so it never
    /// seems to vanish; the filters stay as the user set them.
    private func add(andStart: Bool) {
        // A reminder that passed while the sheet stood open: the next whole hour, as on reopening,
        // so Add never saves one that can no longer notify.
        var adding = draft
        adding.movePassedReminder(now: Date(), calendar: .current)
        guard canAdd, let id = manager.insertTask(from: adding) else { return }
        newTask.draft = TaskFormDraft()
        let started = andStart && enableTimerFeature && manager.start(id)
        // Timing's first session opens when the timer's start arrives, a run-loop turn from now:
        // judge the task as it will be then, In Progress, or a To Do filter loses it a moment later.
        let hidden = manager.tasks.first { $0.id == id }.map { task in
            var probe = task
            if started { probe.segments = TaskTimeMath.opening(probe.segments, at: Date()) }
            return !TaskFacets.matches(probe, filter: listFilter)
        } ?? false
        dismiss()
        if hidden { open(id) }
    }
}
