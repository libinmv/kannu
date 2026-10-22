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

/// A light notch fill gives the notch subtree a light `colorScheme`, but a popover opened from it
/// is still a dark (VibrantDark) window — and SwiftUI passes the light scheme into the popover's
/// content, which then draws black text on the dark popover. So every `.popover` content closure
/// in the notch's views ends in `.notchDarkAppearance()`. Read from the source, the
/// `TaskColorRulesTests` idiom, with a planted-offender test so the scanner cannot pass vacuously.
final class NotchPopoverAppearanceRulesTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root

    /// Folders under `Kannu/components/` whose views never sit in the notch: separate windows
    /// (Settings, lock screen, OSD, onboarding, terms, the screen assistant and clipboard panels)
    /// and the shared colour picker, which only Settings presents.
    static let excludedFolders: Set<String> = [
        "Settings", "LockScreen", "OSD", "Onboarding", "Terms", "ScreenAssistant", "Clipboard", "Color",
    ]

    static let pin = ".notchDarkAppearance()"

    func testEveryNotchPopoverPinsItsContentDark() throws {
        let components = Self.repoRoot.appendingPathComponent("Kannu/components")
        var files = [Self.repoRoot.appendingPathComponent("Kannu/ContentView.swift")]
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: components, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: components.path + "/", with: "")
            guard let folder = relative.split(separator: "/").first, relative.contains("/") else {
                files.append(url)
                continue
            }
            if !Self.excludedFolders.contains(String(folder)) { files.append(url) }
        }
        var problems: [String] = []
        var popovers = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            popovers += text.components(separatedBy: ".popover(").count - 1
            problems += Self.unpinnedPopovers(in: text).map { "\(file.lastPathComponent):\($0)" }
        }
        XCTAssertGreaterThan(popovers, 5, "scanner found almost no popovers — did the folders move?")
        XCTAssertEqual(problems, [], "these notch popovers draw their content without \(Self.pin)")
    }

    func testTheScannerCatchesPlantedOffenders() {
        let bare = """
            Button("a") {}
                .popover(isPresented: $shows, arrowEdge: .bottom) {
                    TimerPopover()
                }
            """
        XCTAssertEqual(Self.unpinnedPopovers(in: bare), ["2"])
        let pinned = """
            Button("a") {}
                .popover(isPresented: $shows, arrowEdge: .bottom) {
                    TimerPopover()
                        .notchDarkAppearance()
                }
                .popover(isPresented: binding(for: x)) {
                    Ranked(onHover: { h in hovering = h })
                    .notchDarkAppearance()
                }
            """
        XCTAssertEqual(Self.unpinnedPopovers(in: pinned), [])
        // The pin after the closure modifies the button, not the popover's content.
        let outside = """
            Button("a") {}
                .popover(isPresented: $shows) {
                    TimerPopover()
                }
                .notchDarkAppearance()
            """
        XCTAssertEqual(Self.unpinnedPopovers(in: outside), ["2"])
    }

    /// Line numbers of `.popover(` calls whose trailing content closure lacks the pin.
    static func unpinnedPopovers(in text: String) -> [String] {
        let chars = Array(text)
        let needle = Array(".popover(")
        var out: [String] = []
        var index = 0
        while index + needle.count <= chars.count {
            guard Array(chars[index..<index + needle.count]) == needle else { index += 1; continue }
            let line = chars[..<index].filter { $0 == "\n" }.count + 1
            // Skip the argument list, then take the trailing closure, brace-matched.
            var cursor = index + needle.count
            var parens = 1
            while cursor < chars.count, parens > 0 {
                if chars[cursor] == "(" { parens += 1 } else if chars[cursor] == ")" { parens -= 1 }
                cursor += 1
            }
            while cursor < chars.count, chars[cursor] != "{" { cursor += 1 }
            let start = cursor
            var braces = 0
            repeat {
                if cursor >= chars.count { break }
                if chars[cursor] == "{" { braces += 1 } else if chars[cursor] == "}" { braces -= 1 }
                cursor += 1
            } while braces > 0
            if !String(chars[start..<min(cursor, chars.count)]).contains(pin) { out.append(String(line)) }
            index = cursor
        }
        return out
    }
}
