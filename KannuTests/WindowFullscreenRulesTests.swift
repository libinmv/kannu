//
//  WindowFullscreenRulesTests.swift
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

/// Windows meant to overlay every space must say so completely: `.canJoinAllSpaces` without
/// `.fullScreenAuxiliary` produces a window that exists, is ordered in, and is invisible the
/// moment any app goes native fullscreen — the exact "running, but not visible" failure shape
/// of 2026-09-30 (see also REGRESSIONS' 2026-09-30 addendum for the stranded-spaces variant).
/// AppKit windows cannot be constructed in this logic-only target, so the pairing is read from
/// the source, the same way `ModalPresentationRulesTests` polices `runModal`.
final class WindowFullscreenRulesTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Kannu", isDirectory: true)

    private static func swiftSources() throws -> [(path: String, source: String)] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var sources: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            sources.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return sources
    }

    /// Every `collectionBehavior = [ … ]` assignment's bracket list, tolerant of line breaks.
    /// Reads, e.g. `collectionBehavior.contains(...)`, are not assignments and are skipped.
    static func behaviorAssignments(in source: String) -> [String] {
        var lists: [String] = []
        var remainder = Substring(source)
        while let hit = remainder.range(of: "collectionBehavior") {
            remainder = remainder[hit.upperBound...]
            guard let open = remainder.firstIndex(of: "[") else { break }
            let between = remainder[..<open]
            // An assignment puts only `=` and whitespace between the property and its list.
            guard between.count <= 4, between.contains("=") else { continue }
            guard let close = remainder[open...].firstIndex(of: "]") else { break }
            lists.append(String(remainder[remainder.index(after: open)..<close]))
            remainder = remainder[remainder.index(after: close)...]
        }
        return lists
    }

    func testEveryAllSpacesWindowAlsoJoinsFullscreenSpaces() throws {
        var checked = 0
        for (path, source) in try Self.swiftSources() {
            for list in Self.behaviorAssignments(in: source) where list.contains("canJoinAllSpaces") {
                checked += 1
                XCTAssertTrue(list.contains("fullScreenAuxiliary"),
                              "\(path): collectionBehavior joins all spaces without .fullScreenAuxiliary — that window is invisible whenever an app is fullscreen")
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 10, "the scanner stopped seeing Kannu's all-spaces windows; fix the scan, not the rule")
    }

    func testTheNotchAndClipboardWindowsDeclareTheirBehavior() throws {
        let sources = Dictionary(uniqueKeysWithValues: try Self.swiftSources())
        for file in ["KannuWindow.swift", "ClipboardPanel.swift"] {
            let source = try XCTUnwrap(sources[file], "\(file) is gone; update this list")
            let lists = Self.behaviorAssignments(in: source).filter { $0.contains("canJoinAllSpaces") }
            XCTAssertFalse(lists.isEmpty, "\(file) no longer assigns an all-spaces collectionBehavior")
        }
    }

    // MARK: - The scanner's own failure modes, so a regex that rots fails loudly

    func testTheScannerCatchesAMissingFlag() {
        let bad = "window.collectionBehavior = [.canJoinAllSpaces, .stationary]"
        let lists = Self.behaviorAssignments(in: bad)
        XCTAssertEqual(lists.count, 1)
        XCTAssertFalse(lists[0].contains("fullScreenAuxiliary"))
    }

    func testTheScannerSkipsReadsAndSeesMultilineAssignments() {
        let read = "if window.collectionBehavior.contains(.canJoinAllSpaces) { }"
        XCTAssertTrue(Self.behaviorAssignments(in: read).isEmpty, "a read is not an assignment")
        let multiline = "collectionBehavior = [\n    .fullScreenAuxiliary,\n    .canJoinAllSpaces,\n]"
        XCTAssertEqual(Self.behaviorAssignments(in: multiline).count, 1)
        XCTAssertTrue(Self.behaviorAssignments(in: multiline)[0].contains("fullScreenAuxiliary"))
    }
}
