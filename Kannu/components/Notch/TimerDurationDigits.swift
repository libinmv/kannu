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

import Foundation

/// What the timer composer's Hours, Minutes and Seconds boxes show and accept
/// (`DurationDigitField`): two digits at rest, digits only while typing, never past the range.
///
/// Typing works like a clock's display: the box holds as many digits as its largest value has, and
/// a new digit typed at the end pushes the first one out, so typing 5 into "00" reads "05".
///
/// Pure, in the logic target.
enum TimerDurationDigits {
    /// "05", "10": the box at rest.
    static func text(_ value: Int) -> String {
        String(format: "%02d", value)
    }

    /// The ASCII digits only: another script's digits would not read as a number.
    static func digits(in text: String) -> String {
        text.filter { $0.isASCII && $0.isNumber }
    }

    /// The number the text stands for, kept inside `range`; nothing typed is the range's start.
    static func value(of text: String, in range: ClosedRange<Int>) -> Int {
        min(max(range.lowerBound, Int(digits(in: text)) ?? range.lowerBound), range.upperBound)
    }

    /// While the user types: nil leaves their text alone; otherwise the text the box should show —
    /// digits only, no more of them than the largest value has (the last ones typed), and the
    /// largest value when the number is past it.
    static func rewriteWhileEditing(_ text: String, in range: ClosedRange<Int>) -> String? {
        var kept = digits(in: text)
        let width = String(range.upperBound).count
        if kept.count > width {
            kept = String(kept.suffix(width))
        }
        if let number = Int(kept), number > range.upperBound {
            kept = Self.text(range.upperBound)
        }
        return kept == text ? nil : kept
    }
}
