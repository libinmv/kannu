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

// Settings rows laid out the way System Settings lays them out: the title with its description
// underneath on the leading side, the control on the trailing side, footers under the group.
//
// Explanatory text (descriptions, footers, values, statuses) can be selected and copied. Control
// labels never can: a selectable Text inside a Toggle, Picker, Button or Menu label swallows the
// click meant for the control. That is why a row with a description hides the control's own
// label (it stays the accessibility label) and draws the title beside it instead.

extension View {
    /// Secondary explanatory text: wraps, and can be selected and copied.
    func settingsDescriptionStyle() -> some View {
        font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// A row title with an optional description under it.
struct SettingsRowLabel: View {
    private let title: Text
    private let description: Text?

    init(_ title: LocalizedStringKey) {
        self.title = Text(title)
        description = nil
    }

    init(_ title: LocalizedStringKey, description: LocalizedStringKey) {
        self.title = Text(title)
        self.description = Text(description)
    }

    /// For descriptions built at run time (already localised), such as a mode's explanation.
    @_disfavoredOverload
    init(_ title: LocalizedStringKey, description: String) {
        self.title = Text(title)
        self.description = Text(verbatim: description)
    }

    /// For titles built at run time (already localised).
    @_disfavoredOverload
    init(verbatim title: String, description: String? = nil) {
        self.title = Text(verbatim: title)
        self.description = description.map { Text(verbatim: $0) }
    }

    /// For a description that depends on state, or none.
    init(_ title: LocalizedStringKey, description: Text?) {
        self.title = Text(title)
        self.description = description
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
            if let description {
                description.settingsDescriptionStyle()
            }
        }
    }
}

/// A title and description on the leading side, the control on the trailing side. Pass the control
/// with its usual label — the row hides it on screen and VoiceOver keeps reading it.
///
///     SettingsRow("Look for secrets", description: "Flags API keys…") {
///         Defaults.Toggle("Look for secrets", key: .detectSecrets)
///     }
struct SettingsRow<Control: View>: View {
    private let label: SettingsRowLabel
    private let control: Control

    init(_ title: LocalizedStringKey, @ViewBuilder control: () -> Control) {
        label = SettingsRowLabel(title)
        self.control = control()
    }

    init(_ title: LocalizedStringKey, description: LocalizedStringKey, @ViewBuilder control: () -> Control) {
        label = SettingsRowLabel(title, description: description)
        self.control = control()
    }

    @_disfavoredOverload
    init(_ title: LocalizedStringKey, description: String, @ViewBuilder control: () -> Control) {
        label = SettingsRowLabel(title, description: description)
        self.control = control()
    }

    @_disfavoredOverload
    init(verbatim title: String, description: String? = nil, @ViewBuilder control: () -> Control) {
        label = SettingsRowLabel(verbatim: title, description: description)
        self.control = control()
    }

    /// For a description that depends on state, or none.
    init(_ title: LocalizedStringKey, description: Text?, @ViewBuilder control: () -> Control) {
        label = SettingsRowLabel(title, description: description)
        self.control = control()
    }

    var body: some View {
        LabeledContent {
            // A grouped Form draws a Toggle as a switch only when the Toggle is the row itself;
            // nested in LabeledContent it would fall back to a checkbox.
            control
                .labelsHidden()
                .toggleStyle(.switch)
        } label: {
            label
        }
    }
}

/// Text under a group of rows. Selectable, leading-aligned like System Settings.
struct SettingsFooter: View {
    private let text: Text

    init(_ text: LocalizedStringKey) {
        self.text = Text(text)
    }

    @_disfavoredOverload
    init(_ text: String) {
        self.text = Text(verbatim: text)
    }

    var body: some View {
        text
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

/// One or more buttons on the trailing side of a row, with an optional title and description on
/// the leading side — never a lone button hanging on the left.
struct SettingsActionRow<Buttons: View>: View {
    private let label: SettingsRowLabel?
    private let buttons: Buttons

    init(@ViewBuilder buttons: () -> Buttons) {
        label = nil
        self.buttons = buttons()
    }

    init(_ title: LocalizedStringKey, @ViewBuilder buttons: () -> Buttons) {
        label = SettingsRowLabel(title)
        self.buttons = buttons()
    }

    init(_ title: LocalizedStringKey, description: LocalizedStringKey, @ViewBuilder buttons: () -> Buttons) {
        label = SettingsRowLabel(title, description: description)
        self.buttons = buttons()
    }

    @_disfavoredOverload
    init(_ title: LocalizedStringKey, description: String?, @ViewBuilder buttons: () -> Buttons) {
        label = description.map { SettingsRowLabel(title, description: $0) } ?? SettingsRowLabel(title)
        self.buttons = buttons()
    }

    var body: some View {
        if let label {
            LabeledContent {
                HStack(spacing: 8) { buttons }
            } label: {
                label
            }
        } else {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                buttons
            }
        }
    }
}

/// The "…" button that holds a row's less frequent actions.
struct SettingsMoreMenu<Items: View>: View {
    private let accessibilityLabel: Text
    private let items: Items

    init(accessibilityLabel: Text = Text("More"), @ViewBuilder items: () -> Items) {
        self.accessibilityLabel = accessibilityLabel
        self.items = items()
    }

    var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: "ellipsis.circle")
                .imageScale(.large)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(accessibilityLabel)
    }
}

/// A read-only value on the trailing side of a row (a path, a date, a count): secondary,
/// selectable, and shortened in the middle when it does not fit.
struct SettingsValueText: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(verbatim: text)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

/// A status line: a small dot (green when ready, grey otherwise) and selectable text.
struct SettingsStatusText: View {
    private let text: String
    private let isReady: Bool

    init(_ text: String, isReady: Bool) {
        self.text = text
        self.isReady = isReady
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(isReady ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .settingsDescriptionStyle()
        }
    }
}

/// An error line under a control: red, selectable.
struct SettingsErrorText: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(verbatim: text)
            .font(.subheadline)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// "Copy for agent": puts a request about a finding on the clipboard, then reads "Copied" for two
/// seconds without changing width (the hidden label keeps the size), so the row never reflows.
struct CopyForAgentButton: View {
    private let copy: () -> Void
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    init(copy: @escaping () -> Void) {
        self.copy = copy
    }

    var body: some View {
        Button {
            copy()
            copied = true
            resetTask?.cancel()
            resetTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            Text("Copy for agent")
                .opacity(copied ? 0 : 1)
                .overlay { if copied { Text("Copied") } }
        }
        .accessibilityLabel(copied ? Text("Copied") : Text("Copy for agent"))
        .help("Copies a request about this finding, ready to paste into your agent. Nothing is sent.")
        .onDisappear { resetTask?.cancel() }
    }
}
