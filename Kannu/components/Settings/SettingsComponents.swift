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
//
// The full construction rules live in docs/SETTINGS.md, and SettingsLayoutRulesTests enforces
// them against the sources — including that these components keep their .textSelection.

/// The numbers every Settings row is built from. One place, so two rows in one section cannot
/// disagree about how wide a slider is or how far a description sits under its title.
///
/// Read the content standard in docs/SETTINGS.md before adding one: a token earns its place by
/// appearing in more than one component, not by naming a value used once.
enum SettingsMetrics {
    /// Title to description inside a row's label.
    static let labelStack: CGFloat = 2
    /// Between the pieces of a row's trailing content (slider and value, value and stepper, buttons).
    static let rowContent: CGFloat = 8
    /// Between lines of a multi-line footer.
    static let footerStack: CGFloat = 6
    /// The whole trailing control column of a slider or stepper row — the slider and its readout.
    static let sliderWidth: CGFloat = 220
    /// The readout at the trailing edge of that column. A `minWidth`, so a long value still fits.
    static let valueColumn: CGFloat = 40
    /// The ready/not-ready dot in a status line.
    static let statusDot: CGFloat = 7
    /// Inside a card (a callout, an expanded detail panel) — the one place padding belongs.
    static let cardPadding: CGFloat = 12
    static let cardCornerRadius: CGFloat = 12
}

extension View {
    /// Secondary explanatory text: wraps, and can be selected and copied.
    ///
    /// Every secondary line in Settings goes through this — descriptions, footers, status lines,
    /// errors. Pass a `tint` only when the colour carries meaning (red for an error, orange for a
    /// partial result); the default secondary is what the rest of the surface uses.
    func settingsDescriptionStyle(tint: Color? = nil) -> some View {
        font(.subheadline)
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// A row title with an optional description under it.
struct SettingsRowLabel: View {
    private let title: Text
    private let description: Text?
    /// Nil is the ordinary secondary description. A colour here means the colour carries meaning —
    /// orange for a partial result, red for a failure — not decoration.
    private var descriptionTint: Color?

    init(_ title: LocalizedStringKey) {
        self.title = Text(title)
        description = nil
    }

    init(_ title: LocalizedStringKey, description: LocalizedStringKey) {
        self.title = Text(title)
        self.description = Text(description)
    }

    /// The description in a colour that means something.
    @_disfavoredOverload
    init(_ title: LocalizedStringKey, description: String, tint: Color?) {
        self.title = Text(title)
        self.description = Text(verbatim: description)
        descriptionTint = tint
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

    /// For a title already built as a `Text` — a localised key with a value interpolated into it,
    /// say — so the catalog key stays exactly as it is.
    init(_ title: Text, description: Text? = nil) {
        self.title = title
        self.description = description
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.labelStack) {
            title
            if let description {
                description.settingsDescriptionStyle(tint: descriptionTint)
            }
        }
    }
}

/// A row that only says something — a title with an explanation under it and no control, for a
/// state the user cannot act on here ("Blur is managed automatically"). It is a row, not a loose
/// `VStack`, so its leading edge lines up with the rows around it instead of running the full
/// width of the section.
struct SettingsNoteRow: View {
    private let label: SettingsRowLabel

    init(_ title: LocalizedStringKey, description: LocalizedStringKey) {
        label = SettingsRowLabel(title, description: description)
    }

    @_disfavoredOverload
    init(_ title: LocalizedStringKey, description: String) {
        label = SettingsRowLabel(title, description: description)
    }

    /// The description in a colour that means something (orange for a partial result).
    @_disfavoredOverload
    init(_ title: LocalizedStringKey, description: String, tint: Color?) {
        label = SettingsRowLabel(title, description: description, tint: tint)
    }

    @_disfavoredOverload
    init(verbatim title: String, description: String? = nil) {
        label = SettingsRowLabel(verbatim: title, description: description)
    }

    var body: some View {
        LabeledContent {
            EmptyView()
        } label: {
            label
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
            // `.labelsHidden()` is an ENVIRONMENT modifier: it reaches everything in the slot.
            // Right for a Toggle/Picker/Stepper (the row draws the title itself); wrong for a
            // Menu or a popover-anchoring button, whose label and item titles it erases — the
            // "Policy rules" menu read as dead this way. Those controls go in a raw
            // LabeledContent or a SettingsActionRow instead (docs/SETTINGS.md).
            control
                .labelsHidden()
                .toggleStyle(.switch)
        } label: {
            label
        }
    }
}

/// A slider row: the title (and optional description) on the leading side, the slider and its
/// current value trailing, at one width across Settings.
///
/// A row whose value already reads in its title passes `valueText: nil`; the readout column stays
/// reserved, so the slider bar itself is the same length as every other slider on the surface.
struct SettingsSliderRow<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    private let label: SettingsRowLabel
    private let accessibilityTitle: Text
    private let valueText: Text?
    @Binding private var value: Value
    private let range: ClosedRange<Value>
    private let step: Value.Stride?

    init(_ title: LocalizedStringKey, value: Binding<Value>, in range: ClosedRange<Value>,
         step: Value.Stride? = nil, valueText: Text?) {
        label = SettingsRowLabel(title)
        accessibilityTitle = Text(title)
        self.valueText = valueText
        _value = value
        self.range = range
        self.step = step
    }

    init(_ title: LocalizedStringKey, description: LocalizedStringKey, value: Binding<Value>,
         in range: ClosedRange<Value>, step: Value.Stride? = nil, valueText: Text?) {
        label = SettingsRowLabel(title, description: description)
        accessibilityTitle = Text(title)
        self.valueText = valueText
        _value = value
        self.range = range
        self.step = step
    }

    /// For a title, or a description, built at run time — including a title that carries the value.
    @_disfavoredOverload
    init(verbatim title: String, description: String? = nil, value: Binding<Value>,
         in range: ClosedRange<Value>, step: Value.Stride? = nil, valueText: Text?) {
        label = SettingsRowLabel(verbatim: title, description: description)
        accessibilityTitle = Text(verbatim: title)
        self.valueText = valueText
        _value = value
        self.range = range
        self.step = step
    }

    /// For a title built as a `Text` elsewhere (a localised key with the value interpolated in).
    init(title: Text, value: Binding<Value>, in range: ClosedRange<Value>,
         step: Value.Stride? = nil, valueText: Text?) {
        label = SettingsRowLabel(title, description: nil)
        accessibilityTitle = title
        self.valueText = valueText
        _value = value
        self.range = range
        self.step = step
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: SettingsMetrics.rowContent) {
                slider
                    .labelsHidden()
                if let valueText {
                    valueText
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(minWidth: SettingsMetrics.valueColumn, alignment: .trailing)
                } else {
                    // The readout column stays reserved so every slider bar is the same length.
                    Color.clear
                        .frame(width: SettingsMetrics.valueColumn, height: 0)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: SettingsMetrics.sliderWidth)
        } label: {
            label
        }
    }

    @ViewBuilder
    private var slider: some View {
        if let step {
            Slider(value: $value, in: range, step: step) { accessibilityTitle }
        } else {
            Slider(value: $value, in: range) { accessibilityTitle }
        }
    }
}

/// A stepper row: the title (and optional description) on the leading side, the current value and
/// the stepper trailing, in the same column a slider row uses.
struct SettingsStepperRow<Value: Strideable>: View {
    private let label: SettingsRowLabel
    private let accessibilityTitle: Text
    private let valueText: Text
    @Binding private var value: Value
    private let range: ClosedRange<Value>
    private let step: Value.Stride

    init(_ title: LocalizedStringKey, value: Binding<Value>, in range: ClosedRange<Value>,
         step: Value.Stride = 1, valueText: Text) {
        label = SettingsRowLabel(title)
        accessibilityTitle = Text(title)
        self.valueText = valueText
        _value = value
        self.range = range
        self.step = step
    }

    init(_ title: LocalizedStringKey, description: LocalizedStringKey, value: Binding<Value>,
         in range: ClosedRange<Value>, step: Value.Stride = 1, valueText: Text) {
        label = SettingsRowLabel(title, description: description)
        accessibilityTitle = Text(title)
        self.valueText = valueText
        _value = value
        self.range = range
        self.step = step
    }

    /// For a title, or a description, built at run time.
    @_disfavoredOverload
    init(verbatim title: String, description: String? = nil, value: Binding<Value>,
         in range: ClosedRange<Value>, step: Value.Stride = 1, valueText: Text) {
        label = SettingsRowLabel(verbatim: title, description: description)
        accessibilityTitle = Text(verbatim: title)
        self.valueText = valueText
        _value = value
        self.range = range
        self.step = step
    }

    /// For a title built as a `Text` elsewhere.
    init(title: Text, value: Binding<Value>, in range: ClosedRange<Value>,
         step: Value.Stride = 1, valueText: Text) {
        label = SettingsRowLabel(title, description: nil)
        accessibilityTitle = title
        self.valueText = valueText
        _value = value
        self.range = range
        self.step = step
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: SettingsMetrics.rowContent) {
                valueText
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(minWidth: SettingsMetrics.valueColumn, alignment: .trailing)
                Stepper(value: $value, in: range, step: step) { accessibilityTitle }
                    .labelsHidden()
            }
            // The same trailing column a slider row uses, so a section holding both bounds its
            // label column at one width and their descriptions wrap the same way.
            .frame(width: SettingsMetrics.sliderWidth, alignment: .trailing)
        } label: {
            label
        }
    }
}

/// A Section header. Selectable — a header is explanatory text, not a control label — so the
/// section's name can be copied like everything else around it. Use it for every
/// `Section { … } header: { … }` in Settings; `SettingsLayoutRulesTests` rejects a raw `Text`
/// there.
struct SettingsSectionHeader: View {
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
            .textSelection(.enabled)
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

/// Several footer lines under one group, at one spacing. Wrap `SettingsFooter`s in it rather than
/// hand-rolling a `VStack`, so two sections cannot space their footers differently.
struct SettingsFooterStack<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.footerStack) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                HStack(spacing: SettingsMetrics.rowContent) { buttons }
            } label: {
                label
            }
        } else {
            HStack(spacing: SettingsMetrics.rowContent) {
                Spacer(minLength: 0)
                buttons
            }
        }
    }
}

/// The "…" button that holds a row's less frequent actions. Never inside a `SettingsRow`
/// control slot — the row's `.labelsHidden()` environment erases the menu's label and its
/// items' titles; use a raw `LabeledContent` (the `analysisRow` shape) instead.
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
        HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.footerStack) {
            Circle()
                .fill(isReady ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: SettingsMetrics.statusDot, height: SettingsMetrics.statusDot)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .settingsDescriptionStyle()
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}

/// An error line under a control: red, selectable. Routed through the shared description style so
/// it is the same size as every other secondary line and moves with them.
struct SettingsErrorText: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(verbatim: text)
            .settingsDescriptionStyle(tint: .red)
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
