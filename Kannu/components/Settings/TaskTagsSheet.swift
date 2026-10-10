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

/// Add Tags on a task, one tag at a time: the task's tags as pills (a click removes one), a field,
/// and under it what the field would add — "#name" for a tag already in use, "Create tag “name”"
/// for a new one, or a few tags in use while the field is empty (`TaskTagEditing.suggestions`).
/// Return adds the highlighted line (`TaskTagEditing.returnPick`) and clears the field for the next
/// tag. Done adds any text still typed the same way, then saves the tags through
/// `TasksManager.setTags` and the colours picked here through `setTagColors`; Cancel, or Escape,
/// keeps both as they were.
///
/// Each pill leads with its tag's colour swatch, which opens the presets. The first tag gives the
/// task its colour (`TaskColoring.color`), so the pills reorder: drag one onto another to take its
/// place (`TaskTagEditing.moving`), or right-click it — Move to Front, Move Left, Move Right — the
/// same three moves VoiceOver offers as the pill's actions. A task's integration is never one of its
/// tags, so it never shows as a pill here.
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
    /// Colours picked in this sheet, keyed by `TaskColoring.key(for:)`: staged until Done.
    @State private var colorPicks: [String: TaskColor] = [:]
    /// The pill a dragged tag is over.
    @State private var dropTarget: String?
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
                    ForEach(Array(tags.enumerated()), id: \.element) { index, tag in
                        pill(tag, at: index)
                    }
                }
                Text("The first tag sets the task's colour.")
                    .settingsDescriptionStyle()
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
                    TasksManager.shared.setTagColors(keptColorPicks)
                    dismiss()
                }
                .keyboardShortcut(isTyping ? nil : .defaultAction)
            }
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(width: 380)
        .onAppear { fieldIsFocused = true }
    }

    // MARK: - Pills

    /// One tag: its colour swatch, then the chip that removes it, washed in the tag's colour. Drag it
    /// onto another pill to take that pill's place; the right-click menu and the matching VoiceOver
    /// actions move it too.
    private func pill(_ tag: String, at index: Int) -> some View {
        let tagColor = color(of: tag)
        return HStack(spacing: SettingsMetrics.iconGap) {
            TaskColorPickerButton(
                selection: colorBinding(for: tag),
                accessibilityLabel: String(localized: "Colour of tag \(tag): \(tagColor.localizedName)")
            )
            SettingsTagChip(tag, tint: tagColor.tint) { tags = TaskTagEditing.removing(tag, from: tags) }
        }
        .overlay {
            if dropTarget == tag {
                Capsule()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .draggable(tag)
        .dropDestination(for: String.self) { items, _ in
            dropTarget = nil
            // Only a tag on this task moves; text dragged in from elsewhere changes nothing.
            guard let dropped = items.first else { return false }
            let moved = TaskTagEditing.moving(dropped, to: index, in: tags)
            guard moved != tags else { return false }
            tags = moved
            return true
        } isTargeted: { isTargeted in
            if isTargeted {
                dropTarget = tag
            } else if dropTarget == tag {
                dropTarget = nil
            }
        }
        .contextMenu {
            Button("Move to Front") { tags = TaskTagEditing.movingToFront(tag, in: tags) }
                .disabled(index == 0)
            Button("Move Left") { tags = TaskTagEditing.moving(tag, to: index - 1, in: tags) }
                .disabled(index == 0)
            Button("Move Right") { tags = TaskTagEditing.moving(tag, to: index + 1, in: tags) }
                .disabled(index == tags.count - 1)
        }
        // The same moves as named actions, so VoiceOver reaches them on the pill itself. `moving`
        // clamps, so a move past either end leaves the order as it is.
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Move to Front")) { tags = TaskTagEditing.movingToFront(tag, in: tags) }
        .accessibilityAction(named: Text("Move Left")) { tags = TaskTagEditing.moving(tag, to: index - 1, in: tags) }
        .accessibilityAction(named: Text("Move Right")) { tags = TaskTagEditing.moving(tag, to: index + 1, in: tags) }
    }

    /// The tag's colour as this sheet has it: picked here, or else saved.
    private func color(of tag: String) -> TaskColor {
        colorPicks[TaskColoring.key(for: tag)] ?? TasksManager.shared.tagColor(for: tag)
    }

    private func colorBinding(for tag: String) -> Binding<TaskColor> {
        Binding(
            get: { color(of: tag) },
            set: { colorPicks[TaskColoring.key(for: tag)] = $0 }
        )
    }

    /// The colours picked here for tags the task still carries: a pill removed before Done takes
    /// its pick with it, so Done never colours a tag it did not keep.
    private var keptColorPicks: [String: TaskColor] {
        let kept = Set(tags.map(TaskColoring.key(for:)))
        return colorPicks.filter { kept.contains($0.key) }
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
