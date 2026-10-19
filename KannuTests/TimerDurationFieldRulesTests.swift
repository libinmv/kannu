//
//  TimerDurationFieldRulesTests.swift
//  KannuTests
//
//  Copyright (C) 2026 Kannu contributors
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import AppKit
import XCTest

/// The composer's duration boxes intermittently showed only the top half of their digits: a SwiftUI
/// `TextField` with 22 pt digits, rebuilt mid-animation, could be measured for the default font
/// (about 16 pt tall), and it sat under two clip masks. The boxes are `DurationDigitField` now —
/// font set at creation, the box's own size, digits centred — and nothing clips over them. The
/// views are not in the logic target, so the rule is read from the source; each scanner has a
/// planted-offender test.
final class TimerDurationFieldRulesTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let notchPath = "Kannu/components/Notch/NotchTimerView.swift"
    static let fieldPath = "Kannu/components/Notch/DurationDigitField.swift"

    private static func source(_ path: String) throws -> String {
        code(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))
    }

    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testTheDurationBoxIsTheWrapperUnderNoClip() throws {
        XCTAssertEqual(Self.fieldProblems(in: try Self.source(Self.notchPath)), [])
    }

    func testTheWrapperFixesItsFontAndSize() throws {
        let field = try Self.source(Self.fieldPath)
        XCTAssertTrue(field.contains("NSFont.monospacedSystemFont(ofSize: TimerComposerMetrics.fieldDigitSize"), "the font is set when the field is made")
        XCTAssertTrue(field.contains("CGSize(width: width, height: TimerComposerMetrics.fieldBoxHeight)"), "the size is the box's, never measured")
        XCTAssertTrue(field.contains("override func drawingRect(forBounds"), "the digits are centred in the box")
        XCTAssertTrue(field.contains("field.currentEditor() == nil"), "an update never fights the user's typing")
    }

    /// The digits fit their box with room to spare, whatever the field's own measuring does.
    func testTheDigitsFitTheirBox() {
        let font = NSFont.monospacedSystemFont(ofSize: TimerComposerMetrics.fieldDigitSize, weight: .semibold)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        XCTAssertLessThanOrEqual(ceil(lineHeight) + 4, TimerComposerMetrics.fieldBoxHeight)
    }

    func testTheScannerCatchesPlantedOffenders() {
        let good = """
            private struct DurationField: View {
                var body: some View {
                    DurationDigitField(value: $value, range: range, width: width, accessibilityLabel: label)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
                }
            }
            private var customTimerComposer: some View {
                Group { }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
            }

            """
        XCTAssertEqual(Self.fieldProblems(in: good), [])
        XCTAssertEqual(Self.fieldProblems(in: good.replacingOccurrences(of: "DurationDigitField(value: $value, range: range, width: width, accessibilityLabel: label)",
                                                                       with: "TextField(\"00\", text: binding)")),
                       ["the duration box is not DurationDigitField", "the duration box is a SwiftUI TextField again"])
        XCTAssertEqual(Self.fieldProblems(in: good.replacingOccurrences(of: ".background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))",
                                                                       with: ".background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 10))")),
                       ["a clip over the duration box"])
        XCTAssertEqual(Self.fieldProblems(in: good.replacingOccurrences(of: ".background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))",
                                                                       with: ".clipShape(RoundedRectangle(cornerRadius: 14))")),
                       ["a clip over the composer, around the duration boxes"])
        XCTAssertEqual(Self.fieldProblems(in: "struct Other {}"), ["no DurationField", "no customTimerComposer"])
    }

    // MARK: - Scanning

    private static func fieldProblems(in source: String) -> [String] {
        var problems: [String] = []
        if let field = declaration("private struct DurationField", in: source) {
            if !field.contains("DurationDigitField(") { problems.append("the duration box is not DurationDigitField") }
            if field.contains("TextField(") && !field.contains("DurationDigitField(") {
                problems.append("the duration box is a SwiftUI TextField again")
            }
            if field.contains(".clipShape(") { problems.append("a clip over the duration box") }
        } else {
            problems.append("no DurationField")
        }
        if let composer = declaration("private var customTimerComposer: some View", in: source) {
            if composer.contains(".clipShape(") { problems.append("a clip over the composer, around the duration boxes") }
        } else {
            problems.append("no customTimerComposer")
        }
        return problems
    }

    /// From `marker` through its balanced closing brace.
    private static func declaration(_ marker: String, in source: String) -> String? {
        guard let start = source.range(of: marker),
              let open = source[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[start.lowerBound...index]) }
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }
}
