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

import SwiftUI

/// Add Tags on a task, one tag at a time: the task's tags as chips (a click removes one), a field,
/// and under it what the field would add — "#name" for a tag already in use, "Create tag “name”"
/// for a new one, or a few tags in use while the field is empty (`TaskTagEditing.suggestions`).
/// Return adds the highlighted line (`TaskTagEditing.returnPick`) and clears the field for the next
/// tag. Done adds any text still typed the same way, then saves through `TasksManager.setTags`;
/// Cancel, or Escape, keeps the tags as they were.
///
/// The suggestion list follows the Brain search bar's (`SettingsSidebarSearchBar`): plain buttons,
/// one per line, and Return picks the highlighted one. Tags are the user's own and render verbatim; they stay
/// on this Mac. A sheet pads its own content; a Form row never does.
struct TaskTagsSheet: View {
    private let taskID: UUID
    private let title: String
    /// Every tag in use, on any task: what the suggestions are drawn from.
    private let existing: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var tags: [String]
    @State private var text = ""
    @State private var hovered: TaskTagEditing.Suggestion?
    @FocusState private var fieldIsFocused: Bool

    init(taskID: UUID, title: String, current: [String], existing: [String]) {
        self.taskID = taskID
        self.title = title
        self.existing = existing
        _tags = State(initialValue: TaskItem.cleanedTags(current))
    }

    private var isFull: Bool { tags.count >= TaskItem.maxTags }
    private var isTyping: Bool { TaskTagEditing.cleaned(text) != nil }
    private var suggestions: [TaskTagEditing.Suggestion] {
        TaskTagEditing.suggestions(for: text, existing: existing, current: tags)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowContent) {
            VStack(alignment: .leading, spacing: SettingsMetrics.labelStack) {
                Text("Tags")
                    .font(.headline)
                Text(verbatim: title)
                    .settingsDescriptionStyle()
            }

            if tags.isEmpty {
                Text("No tags yet. Tags stay on this Mac.")
                    .settingsDescriptionStyle()
            } else {
                SettingsFlowLayout {
                    ForEach(tags, id: \.self) { tag in
                        SettingsTagChip(tag) { tags = TaskTagEditing.removing(tag, from: tags) }
                    }
                }
            }

            TextField("Add a tag", text: $text, prompt: Text("Add a tag"))
                .labelsHidden()
                .focused($fieldIsFocused)
                .disabled(isFull)
                .onSubmit(addReturnPick)

            if isFull {
                Text("\(TaskItem.maxTags) tags is the most")
                    .settingsDescriptionStyle()
            } else if !suggestions.isEmpty {
                suggestionList
            }

            HStack(spacing: SettingsMetrics.rowContent) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // While a tag is being typed, Return adds it (the field's submit), never Done. A
                // click on Done adds what Return would first, so the last tag typed is never lost.
                Button("Done") {
                    addReturnPick()
                    TasksManager.shared.setTags(tags, for: taskID)
                    dismiss()
                }
                .keyboardShortcut(isTyping ? nil : .defaultAction)
            }
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(width: 380)
        .onAppear { fieldIsFocused = true }
    }

    // MARK: - Suggestions

    private var suggestionList: some View {
        let shown = suggestions
        return VStack(alignment: .leading, spacing: SettingsMetrics.labelStack) {
            ForEach(shown, id: \.self) { suggestion in
                Button {
                    pick(suggestion)
                } label: {
                    suggestionLabel(suggestion)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The line Return would pick, and the one under the pointer, in the accent colour.
                .foregroundStyle(isHighlighted(suggestion, in: shown) ? Color.accentColor : Color.primary)
                .onHover { isOver in
                    if isOver {
                        hovered = suggestion
                    } else if hovered == suggestion {
                        hovered = nil
                    }
                }
                if suggestion != shown.last {
                    Divider()
                }
            }
        }
    }

    private func suggestionLabel(_ suggestion: TaskTagEditing.Suggestion) -> Text {
        switch suggestion {
        case .use(let tag): return Text(verbatim: "#\(tag)")
        case .create(let tag): return Text("Create tag “\(tag)”")
        }
    }

    private func isHighlighted(_ suggestion: TaskTagEditing.Suggestion, in shown: [TaskTagEditing.Suggestion]) -> Bool {
        if let hovered { return hovered == suggestion }
        return TaskTagEditing.returnPick(for: text, in: shown) == suggestion
    }

    /// Return: a tag in use that starts with the text, or else the text as a new tag
    /// (`TaskTagEditing.returnPick`). With the field empty the quick picks need a click, so Return
    /// never adds a tag nobody typed.
    private func addReturnPick() {
        guard let picked = TaskTagEditing.returnPick(for: text, in: suggestions) else { return }
        pick(picked)
    }

    private func pick(_ suggestion: TaskTagEditing.Suggestion) {
        tags = TaskTagEditing.adding(suggestion.tag, to: tags)
        text = ""
        hovered = nil
        fieldIsFocused = !isFull
    }
}
