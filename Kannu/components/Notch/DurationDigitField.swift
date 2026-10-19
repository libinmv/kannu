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

/// One of the timer composer's Hours, Minutes and Seconds boxes: an `NSTextField` of our own, not
/// SwiftUI's `TextField`.
///
/// SwiftUI's field sized itself from its text, and when the composer was rebuilt mid-animation
/// (switching tabs, a timer stopping, the task form closing) it could take the height of the
/// default 13 pt font, about 16 pt, while drawing 22 pt digits: only their top half showed. Here
/// the font is set when the field is made, the size is the box's (`sizeThatFits`), and the cell
/// centres the digits in it, so no animation can measure it wrong. What it shows and accepts is
/// `TimerDurationDigits`.
struct DurationDigitField: NSViewRepresentable {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let width: CGFloat
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> DigitTextField {
        let field = DigitTextField(frame: NSRect(x: 0, y: 0, width: width, height: TimerComposerMetrics.fieldBoxHeight))
        field.font = NSFont.monospacedSystemFont(ofSize: TimerComposerMetrics.fieldDigitSize, weight: .semibold)
        field.alignment = .center
        field.textColor = .white
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderAttributedString = NSAttributedString(
            string: "00",
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.35), .font: field.font as Any]
        )
        field.stringValue = TimerDurationDigits.text(value)
        field.setAccessibilityLabel(accessibilityLabel)
        field.delegate = context.coordinator
        return field
    }

    /// The value changed from outside (Reset, a preset, the stored duration): the box follows. While
    /// the user types, their text stays unless it no longer says the value.
    func updateNSView(_ field: DigitTextField, context: Context) {
        context.coordinator.parent = self
        let shown = TimerDurationDigits.text(value)
        if field.currentEditor() == nil {
            if field.stringValue != shown { field.stringValue = shown }
        } else if TimerDurationDigits.value(of: field.stringValue, in: range) != value {
            field.stringValue = shown
        }
    }

    /// The box's size, always: never measured from the text.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DigitTextField, context: Context) -> CGSize? {
        CGSize(width: width, height: TimerComposerMetrics.fieldBoxHeight)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DurationDigitField

        init(_ parent: DurationDigitField) {
            self.parent = parent
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            if let rewritten = TimerDurationDigits.rewriteWhileEditing(field.stringValue, in: parent.range) {
                field.stringValue = rewritten
            }
            let number = TimerDurationDigits.value(of: field.stringValue, in: parent.range)
            if parent.value != number { parent.value = number }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            field.stringValue = TimerDurationDigits.text(parent.value)
        }
    }
}

/// The box's field: its cell centres the digits, and the caret is white on the dark box.
final class DigitTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { CenteredDigitCell.self }
        set {}
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = .white
        }
        return became
    }
}

/// Draws, and edits, the text centred vertically in the box: an `NSTextFieldCell` puts it at the
/// top. One override places both, since the field editor is laid out in the same rect.
final class CenteredDigitCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let base = super.drawingRect(forBounds: rect)
        let height = cellSize(forBounds: rect).height
        guard height < base.height else { return base }
        return NSRect(x: base.minX, y: base.minY + (base.height - height) / 2, width: base.width, height: height)
    }
}
