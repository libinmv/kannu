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

import XCTest

/// The built-in notch skins and the AI prompt Settings › Notch skin copies.
final class NotchSkinTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    // MARK: - The prompt

    /// The prompt is an interview first: the AI asks, one question at a time, and draws nothing
    /// until every answer is in. The questions come before the drawing rules.
    func testThePromptAsksBeforeItDraws() throws {
        let text = NotchSkinPrompt.text
        XCTAssertTrue(text.contains("ask me these questions one at a time"))
        XCTAssertTrue(text.contains("Do not generate anything until I have answered all of them."))
        let questions = try XCTUnwrap(text.range(of: "1. What mood or theme"))
        let rules = try XCTUnwrap(text.range(of: "generate one image that follows these rules"))
        XCTAssertLessThan(questions.lowerBound, rules.lowerBound)
        XCTAssertEqual((1...5).filter { text.contains("\n\($0). ") }.count, 5)
    }

    /// The canvas the prompt asks for: 3× the default open notch (640 × 200 pt), as a PNG, with
    /// nothing in it that would read as interface or text.
    func testThePromptStatesTheCanvasAndWhatToLeaveOut() {
        let text = NotchSkinPrompt.text
        XCTAssertTrue(text.contains("1920 × 600 pixels, landscape, PNG."))
        XCTAssertTrue(text.contains("No text, letters, logos, watermarks, interface elements, people or faces."))
        XCTAssertTrue(text.contains("middle 60% of the width"))
        XCTAssertFalse(text.contains("\\"), "a line continuation leaked into the copied text")
    }

    /// `docs/NOTCH-SKINS.md` quotes the prompt; a change to one without the other is caught here.
    func testTheDocQuotesThePromptVerbatim() throws {
        let doc = try String(contentsOf: Self.root.appendingPathComponent("docs/NOTCH-SKINS.md"), encoding: .utf8)
        XCTAssertTrue(doc.contains("```text\n\(NotchSkinPrompt.text)\n```"))
    }

    // MARK: - Built-in skins

    /// A built-in id goes in `selectedNotchSkinID`, the key that holds an uploaded skin's UUID, so it
    /// must never parse as one. Ids are unique, and `with(id:)` finds each and nothing else.
    func testBuiltInIdsCannotCollideWithUploadedSkins() {
        let ids = BuiltInNotchSkin.all.map(\.id)
        XCTAssertFalse(ids.isEmpty)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(Self.uuidShapedIds(in: BuiltInNotchSkin.all), [])
        let planted = BuiltInNotchSkin(id: UUID().uuidString, assetName: "planted", name: "Planted")
        XCTAssertEqual(Self.uuidShapedIds(in: [planted]), [planted.id])

        for skin in BuiltInNotchSkin.all {
            XCTAssertEqual(BuiltInNotchSkin.with(id: skin.id), skin)
        }
        XCTAssertNil(BuiltInNotchSkin.with(id: nil))
        XCTAssertNil(BuiltInNotchSkin.with(id: UUID().uuidString))
    }

    /// Each built-in names an imageset that exists, whose `Contents.json` names an image file that
    /// exists: `NSImage(named:)` returns nil for a missing asset, and the skin would silently draw
    /// nothing.
    func testEveryBuiltInSkinHasItsImage() throws {
        for skin in BuiltInNotchSkin.all {
            let imageset = Self.root.appendingPathComponent("Kannu/Assets.xcassets/\(skin.assetName).imageset")
            let contents = try Data(contentsOf: imageset.appendingPathComponent("Contents.json"))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: contents) as? [String: Any])
            let images = try XCTUnwrap(json["images"] as? [[String: Any]])
            let files = images.compactMap { $0["filename"] as? String }
            XCTAssertFalse(files.isEmpty, skin.assetName)
            for file in files {
                XCTAssertTrue(FileManager.default.fileExists(atPath: imageset.appendingPathComponent(file).path),
                              "\(skin.assetName): \(file)")
            }
        }
    }

    private static func uuidShapedIds(in skins: [BuiltInNotchSkin]) -> [String] {
        skins.map(\.id).filter { UUID(uuidString: $0) != nil }
    }
}
