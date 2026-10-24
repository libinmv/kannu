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

/// The notch window lives in Kannu's own top-level CGSSpace on every hide option, and in no other
/// space. Until 2026-10-22 only "Never hide" joined it; on `.canJoinAllSpaces` alone the notch slid
/// with every Space switch (David, 2026-10-22). Fullscreen hiding is `KannuViewModel.hideOnClosed`,
/// in the views, and never depended on the membership. `AppDelegate` is AppKit with no unit surface,
/// so the invariant is read from the source (the `NotchInteractionTests` idiom).
final class NotchSpaceMembershipTests: XCTestCase {

    func testEveryNotchWindowJoinsTheNotchSpace() throws {
        let lines = try Self.codeLines("Kannu/KannuApp.swift")
        let insert = "NotchSpaceManager.shared.notchSpace.windows.insert(window)"
        let at = try XCTUnwrap(lines.firstIndex(of: insert), "createKannuWindow no longer inserts the window into the notch space")
        let previous = try XCTUnwrap(lines[..<at].last { !$0.isEmpty })
        XCTAssertFalse(previous.hasPrefix("if ") || previous.hasPrefix("guard ") || previous.hasPrefix("} else"),
                       "the insert is gated again (\(previous)); the hide option must not decide space membership")
    }

    /// `orderFrontRegardless` puts a new window on the current space; the pin takes it off again,
    /// one run-loop turn later, because in the same turn WindowServer does not yet list the window as
    /// on screen and the repair read that as an unseen notch and fell back (2026-10-22, 22:11:06).
    func testEveryNotchWindowIsPinnedAtCreation() throws {
        let lines = try Self.codeLines("Kannu/KannuApp.swift")
        let insert = try XCTUnwrap(lines.firstIndex(of: "NotchSpaceManager.shared.notchSpace.windows.insert(window)"))
        let following = lines[(insert + 1)...].filter { !$0.isEmpty }.prefix(3).map { $0 }
        XCTAssertEqual(following.first, "DispatchQueue.main.async { [weak self, weak window] in",
                       "the creation pin must run a turn later, not in the turn the window is ordered in")
        XCTAssertTrue(following.contains("self.pinNotchWindows([window], after: \"create\")"),
                      "createKannuWindow no longer pins the new window after joining the notch space")
    }

    /// A window moved to another display without a rebuild (pointer follow) is re-pinned there.
    func testARepositionedWindowIsPinnedAgain() throws {
        let code = try Self.codeLines("Kannu/KannuApp.swift").joined(separator: "\n")
        let reposition = try XCTUnwrap(Self.body(ofFunction: "adjustWindowPosition", in: code))
        XCTAssertTrue(reposition.contains("self?.rejoinNotchSpacesIfNeeded(after: \"reposition\")"),
                      "adjustWindowPosition no longer re-pins the window it moved, a turn later")
    }

    func testTeardownStillLeavesTheSpace() throws {
        let code = try Self.codeLines("Kannu/KannuApp.swift").joined(separator: "\n")
        XCTAssertEqual(code.components(separatedBy: "notchSpace.windows.remove(window)").count - 1, 2,
                       "a window that joins the space on every option must leave it on every teardown path")
    }

    /// `.canJoinAllSpaces` is what macOS uses to put the notch back on a space it creates; the pin
    /// then takes it off again. Dropping it is a separate, reviewed change, not a side effect.
    func testTheWindowKeepsItsManagedSpaceFallback() throws {
        let window = try Self.codeLines("Kannu/components/Notch/KannuWindow.swift").joined(separator: "\n")
        for behaviour in [".fullScreenAuxiliary,", ".canJoinAllSpaces,", ".stationary,", ".ignoresCycle,"] {
            XCTAssertTrue(window.contains(behaviour), "\(behaviour) left the notch window's collectionBehavior")
        }
    }

    // MARK: - Helpers

    private static func codeLines(_ path: String) throws -> [String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
    }

    /// The text of a function body, from its declaration to the next `func ` at file scope. Crude on
    /// purpose: enough to scope a pin to one function without parsing Swift.
    private static func body(ofFunction name: String, in text: String) -> String? {
        guard let start = text.range(of: "func \(name)(") else { return nil }
        let rest = text[start.upperBound...]
        let end = ["\nfunc ", "\nprivate func ", "\n@MainActor\nfunc ", "\n@MainActor\nprivate func ",
                   "\n@objc func ", "\n@objc private func ", "\n@MainActor private func "]
            .compactMap { rest.range(of: $0)?.lowerBound }
            .min() ?? rest.endIndex
        return String(rest[..<end])
    }
}
