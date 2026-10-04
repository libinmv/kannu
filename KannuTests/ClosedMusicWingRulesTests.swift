//
//  ClosedMusicWingRulesTests.swift
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

import XCTest

/// `ContentView.MusicLiveActivity` is not compiled into the logic target, so its layout is read
/// from source (the `TimerNamingRulesTests` idiom). The paired activity's badge used to be a
/// ZStack overlay nudged by `.offset`, covering a quarter of a 20 pt thumbnail; it must sit in the
/// art's HStack, and the wing's frame and the notch width must use one `ClosedMusicWingLayout`.
final class ClosedMusicWingRulesTests: XCTestCase {
    private static let contentView = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Kannu/ContentView.swift")

    private static func musicLiveActivity() throws -> String {
        let source = code(try String(contentsOf: contentView, encoding: .utf8))
        return try XCTUnwrap(body(ofFunction: "MusicLiveActivity", in: source), "MusicLiveActivity not found")
    }

    func testTheBadgeSitsBesideTheArtNeverOverIt() throws {
        let body = try Self.musicLiveActivity()
        XCTAssertTrue(body.contains(Self.artMarker), "the art's matched geometry was not found; this pin would be vacuous")
        XCTAssertFalse(Self.badgeCalls(in: body).isEmpty, "no badge found; this pin would be vacuous")
        XCTAssertEqual(Self.badgeOffenders(in: body), [])
    }

    func testTheWingAndTheNotchShareOneWidth() throws {
        XCTAssertEqual(Self.layoutProblems(in: try Self.musicLiveActivity()), [])
    }

    func testTheOverlayOffsetIsGone() throws {
        let source = try String(contentsOf: Self.contentView, encoding: .utf8)
        XCTAssertFalse(source.contains("badgeOverlayOffset"))
    }

    func testTheScannersCatchPlantedOffenders() {
        let oldShape = """
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                    .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                albumArtBadge(for: secondary, badgeSize: badgeDisplaySize)
                    .offset(x: badgeOffset.width, y: badgeOffset.height)
            }
            """
        let overlay = """
            Color.clear
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .overlay {
                    albumArtBadge(for: secondary, badgeSize: size)
                }
            """
        let background = """
            HStack {
                Color.clear
                    .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                    .background(albumArtBadge(for: secondary, badgeSize: size))
            }
            """
        let nudged = """
            HStack(spacing: 4) {
                Color.clear
                    .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                albumArtBadge(for: secondary, badgeSize: size)
                    .offset(x: -6, y: 0)
            }
            """
        let notBesideTheArt = """
            HStack(spacing: 4) {
                Text("elsewhere")
                albumArtBadge(for: secondary, badgeSize: size)
            }
            """
        for (name, planted) in [("old ZStack", oldShape), ("overlay", overlay), ("background", background),
                                ("offset", nudged), ("away from the art", notBesideTheArt)] {
            XCTAssertEqual(Self.badgeOffenders(in: Self.code(planted)).count, 1, name)
        }

        let newShape = Self.code("""
            let leftWing = ClosedMusicWingLayout(
                artSlotWidth: wingBaseWidth,
                contentHeight: notchContentHeight,
                hasPairedActivity: secondary != nil,
                inlineSneakPeekActive: inlineSneakPeekActive
            )
            let notchWidth = leftWing.width + effectiveCenterWidth + rightWingWidth + wingEdgeInset * 2
            HStack(alignment: .center, spacing: ClosedMusicWingLayout.badgeSpacing) {
                Color.clear
                    .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                    .frame(width: leftWing.artSlotWidth, height: notchContentHeight)
                // a comment with a { brace
                if leftWing.showsBadge, let secondary {
                    albumArtBadge(for: secondary, badgeSize: leftWing.badgeSize)
                        .id(secondary.id)
                }
            }
            .frame(width: leftWing.width, height: notchContentHeight, alignment: .leading)
            """)
        XCTAssertEqual(Self.badgeOffenders(in: newShape), [])
        XCTAssertEqual(Self.layoutProblems(in: newShape), [])

        let oldWidth = newShape.replacingOccurrences(of: "let notchWidth = leftWing.width", with: "let notchWidth = wingBaseWidth")
        XCTAssertEqual(Self.layoutProblems(in: oldWidth).count, 1)
        let oldFrame = newShape.replacingOccurrences(of: ".frame(width: leftWing.width", with: ".frame(width: wingBaseWidth")
        XCTAssertEqual(Self.layoutProblems(in: oldFrame).count, 1)
    }

    // MARK: - Scanning

    private static let artMarker = #"matchedGeometryEffect(id: "albumArt""#

    /// Each `albumArtBadge(` call that is a use, not the declaration.
    private static func badgeCalls(in text: String) -> [String.Index] {
        var found: [String.Index] = []
        var start = text.startIndex
        while let range = text.range(of: "albumArtBadge(", range: start..<text.endIndex) {
            if !text[text.startIndex..<range.lowerBound].hasSuffix("func ") { found.append(range.lowerBound) }
            start = range.upperBound
        }
        return found
    }

    /// One line per badge call that is not a plain child of an HStack holding the album art.
    private static func badgeOffenders(in text: String) -> [String] {
        badgeCalls(in: text).compactMap { call in
            let line = text[text.lineRange(for: call..<call)].trimmingCharacters(in: .whitespaces)
            if modifierChain(in: text, from: call).contains(".offset(") { return "nudged by .offset: " + line }
            guard let container = enclosingContainer(in: text, of: call) else { return "an argument, not a child: " + line }
            guard container.header.hasPrefix("HStack") else { return "inside \(container.header): " + line }
            guard container.block.contains(artMarker) else { return "not beside the album art: " + line }
            return nil
        }
    }

    /// The call and the modifiers chained after it (the following lines that start with ".").
    private static func modifierChain(in text: String, from call: String.Index) -> String {
        let callEnd = balancedEnd(in: text, from: text.range(of: "(", range: call..<text.endIndex)!.lowerBound, open: "(", close: ")")
        var end = callEnd
        var cursor = callEnd
        while cursor < text.endIndex {
            let lineRange = text.lineRange(for: cursor..<cursor)
            let next = lineRange.upperBound
            guard next < text.endIndex else { break }
            let nextLine = text[text.lineRange(for: next..<next)]
            guard nextLine.trimmingCharacters(in: .whitespaces).hasPrefix(".") else { break }
            end = text.lineRange(for: next..<next).upperBound
            cursor = next
        }
        return String(text[call..<end])
    }

    /// The nearest enclosing view block, skipping `if`/`else`/`switch` blocks; nil when the call is
    /// inside an argument list instead.
    private static func enclosingContainer(in text: String, of call: String.Index) -> (header: String, block: String)? {
        var index = call
        var parens = 0, braces = 0
        while index > text.startIndex {
            index = text.index(before: index)
            switch text[index] {
            case ")": parens += 1
            case "}": braces += 1
            case "(":
                if parens == 0 { return nil }
                parens -= 1
            case "{":
                if braces > 0 { braces -= 1; continue }
                let header = headerText(in: text, beforeBrace: index)
                if header.hasPrefix("if ") || header.hasPrefix("else") || header.hasPrefix("} else")
                    || header.hasPrefix("switch ") || header.hasPrefix("case ") {
                    continue
                }
                let blockEnd = balancedEnd(in: text, from: index, open: "{", close: "}")
                return (header, String(text[index..<blockEnd]))
            default: break
            }
        }
        return nil
    }

    /// The text that opens a block: its line up to the brace, from the line of the matching "("
    /// when the header's argument list spans lines.
    private static func headerText(in text: String, beforeBrace brace: String.Index) -> String {
        var start = text.lineRange(for: brace..<brace).lowerBound
        var header = text[start..<brace].trimmingCharacters(in: .whitespaces)
        if header.hasPrefix(")"), let close = text[start..<brace].firstIndex(of: ")") {
            var depth = 0
            var index = close
            while index > text.startIndex {
                if text[index] == ")" { depth += 1 } else if text[index] == "(" { depth -= 1; if depth == 0 { break } }
                index = text.index(before: index)
            }
            start = text.lineRange(for: index..<index).lowerBound
            header = text[start..<brace].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return header
    }

    private static func balancedEnd(in text: String, from open: String.Index, open opener: Character, close closer: Character) -> String.Index {
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == opener { depth += 1 } else if text[index] == closer {
                depth -= 1
                if depth == 0 { return text.index(after: index) }
            }
            index = text.index(after: index)
        }
        return text.endIndex
    }

    /// The wing's frame and the notch width read the same `ClosedMusicWingLayout`.
    private static func layoutProblems(in body: String) -> [String] {
        guard let match = body.range(of: #"let (\w+) = ClosedMusicWingLayout\("#, options: .regularExpression) else {
            return ["no ClosedMusicWingLayout"]
        }
        let name = body[match].dropFirst("let ".count).prefix { $0 != " " }
        var problems: [String] = []
        let notchLine = body.split(separator: "\n").first { $0.contains("let notchWidth =") }
        if notchLine == nil || !notchLine!.contains("\(name).width") || notchLine!.contains("wingBaseWidth") {
            problems.append("the notch width is not the layout's: \(notchLine.map(String.init) ?? "missing")")
        }
        if !body.contains(".frame(width: \(name).width") { problems.append("the wing's frame is not the layout's width") }
        if !body.contains("if \(name).showsBadge") { problems.append("the badge is not gated on the layout") }
        return problems
    }

    /// Source without whole-line comments.
    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The body of `func <name>(`, braces included.
    private static func body(ofFunction name: String, in text: String) -> String? {
        guard let declaration = text.range(of: "func \(name)("),
              let open = text.range(of: "(", range: declaration.lowerBound..<text.endIndex) else { return nil }
        let signatureEnd = balancedEnd(in: text, from: open.lowerBound, open: "(", close: ")")
        guard let brace = text[signatureEnd...].firstIndex(of: "{") else { return nil }
        return String(text[brace..<balancedEnd(in: text, from: brace, open: "{", close: "}")])
    }
}
