//
//  ADRDocsTests.swift
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

/// `docs/ADR.md` is what a user reads before trusting Kannu with ADR; when the code's list of
/// watched files or the scan schedule changes, the document must change with it. Read from the
/// source tree, like `SettingsHighlightInventoryTests`.
final class ADRDocsTests: XCTestCase {
    private static let doc: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KannuTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("docs/ADR.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    private func section(_ heading: String) throws -> String {
        let doc = Self.doc
        let start = try XCTUnwrap(doc.range(of: heading), "\(heading) is gone")
        let next = doc.range(of: "\n## ", range: start.upperBound..<doc.endIndex)?.lowerBound ?? doc.endIndex
        return String(doc[start.lowerBound..<next])
    }

    func testTheScanSectionNamesEveryWatchedSettingsFile() throws {
        let scans = try section("## 3. Let Kannu run it")
        for location in MCPServerWatch.globalLocations(home: "~") {
            let path = location.path
            let name = String(path.split(separator: "/").last ?? "")
            XCTAssertTrue(scans.contains(path) || scans.contains(name), "\(path) is watched but not documented")
        }
        XCTAssertFalse(scans.contains("/.mcp.json"), "a scan is triggered by the global files only")
        let flowed = scans.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertTrue(flowed.contains("once a minute"))
        XCTAssertTrue(flowed.contains("1, 2, 4, 8 and 16 hours"), "the retry after a failed scan")
        XCTAssertTrue(flowed.contains("24 hours"))
    }

    func testTheSensorIsDocumentedAsUnusedAndTheSectionsAreInOrder() throws {
        let sensor = try section("## 7. ADR Sensor")
        XCTAssertTrue(sensor.contains("Kannu does not use it"))
        XCTAssertTrue(sensor.contains("Copy install command"))
        XCTAssertTrue(sensor.contains("never installs anything"))
        let numbers = Self.doc.components(separatedBy: "\n## ").compactMap { Int($0.prefix(while: \.isNumber)) }
        XCTAssertEqual(numbers, numbers.sorted(), "the numbered sections run in order")
        XCTAssertEqual(numbers, Array(1...numbers.count))
    }

    func testTheFindingCardIsDocumented() throws {
        // Markdown wraps and emphasises; compare on the words.
        let card = try section("## What Kannu does with findings")
            .replacingOccurrences(of: "*", with: "")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        for phrase in ["Reveal File in Finder", "Reveal Project Folder", "Open Chat", "Copy Details", "Acknowledge"] {
            XCTAssertTrue(card.contains(phrase), phrase)
        }
    }
}
