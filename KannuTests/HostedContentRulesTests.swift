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

/// Pins docs/REGRESSIONS.md entry 17: a hosting view is never a borderless panel's
/// `contentView`. As a content view it gets SwiftUI's window-size bridge, which clamps the frame
/// on every layout and fights Kannu's own sizing until AppKit throws. Panels go through
/// `NSWindow.setHostedContent(_:)` (`Kannu/helpers/HostedContent.swift`). The only direct
/// assignments left are titled windows, where content-driven sizing is wanted — pinned below by
/// file and count, so a new one is a deliberate edit.
final class HostedContentRulesTests: XCTestCase {

    /// Titled windows keep the direct assignment on purpose, plus the offscreen DEBUG snapshot
    /// window.
    private static let allowedDirectAssignments: [String: Int] = [
        "Kannu/KannuApp.swift": 1,                                        // onboarding window
        "Kannu/components/Settings/SettingsWindowController.swift": 1,    // Settings
        "Kannu/managers/ClipboardWindowManager.swift": 1,                 // titled clipboard window
        "Kannu/managers/LockScreenWidgetPreviewManager.swift": 2,         // titled preview window
        "Kannu/helpers/DebugSnapshot.swift": 1,                           // offscreen, DEBUG only
    ]

    func testNoPanelTakesAHostingViewAsItsContentView() {
        let sources = Self.appSources()
        XCTAssertGreaterThan(sources.count, 100, "the scan read too few files — fix appSources()")
        var found: [String: [Int]] = [:]
        for (path, text) in sources {
            let lines = Self.offenders(in: text)
            if !lines.isEmpty { found[path] = lines }
        }
        for (path, lines) in found {
            let allowed = Self.allowedDirectAssignments[path] ?? 0
            XCTAssertLessThanOrEqual(
                lines.count, allowed,
                "\(path):\(lines): a hosting view is assigned straight to contentView — use window.setHostedContent(_:) (docs/REGRESSIONS.md entry 17)")
        }
        for (path, allowed) in Self.allowedDirectAssignments {
            XCTAssertEqual(found[path]?.count ?? 0, allowed,
                           "\(path): the pinned count is stale — lower it so it keeps meaning something")
        }
    }

    func testTheHelperIsWhereTheRuleSays() throws {
        let sources = Self.appSources()
        let helper = try XCTUnwrap(sources["Kannu/helpers/HostedContent.swift"], "HostedContent.swift moved")
        XCTAssertTrue(helper.contains("func setHostedContent"))
        XCTAssertTrue(helper.contains("class HostingContainerView"))
        XCTAssertTrue(helper.contains("sizingOptions = []"))
        // The notch window is the one that crashed; it must use the helper.
        XCTAssertTrue(sources["Kannu/KannuApp.swift"]?.contains("window.setHostedContent(hostingView)") == true)
    }

    // MARK: - The scanner must catch things

    func testTheScannerCatchesEveryShape() {
        XCTAssertEqual(Self.offenders(in: "window.contentView = hostingView").count, 1)
        XCTAssertEqual(Self.offenders(in: "        self.contentView = hosting").count, 1)
        XCTAssertEqual(Self.offenders(in: "win.contentView = NSHostingView(rootView: X())").count, 1)
        XCTAssertEqual(Self.offenders(in: "newWindow.contentView = newHostingView").count, 1)
        XCTAssertEqual(Self.offenders(in: "window.contentView = hostingView()").count, 1)
    }

    func testTheScannerLeavesTheCuresAndCommentsAlone() {
        XCTAssertEqual(Self.offenders(in: "window.setHostedContent(hostingView)").count, 0)
        XCTAssertEqual(Self.offenders(in: "window.contentView = nil").count, 0)
        XCTAssertEqual(Self.offenders(in: "window.contentView = container").count, 0)
        XCTAssertEqual(Self.offenders(in: "newWindow.contentView = newView").count, 0)
        XCTAssertEqual(Self.offenders(in: "// window.contentView = hostingView").count, 0)
        XCTAssertEqual(Self.offenders(in: "if window.contentView !== hostingView {").count, 0)
    }

    // MARK: - Plumbing

    private static let pattern = try! NSRegularExpression(
        pattern: #"\bcontentView\s*=\s*(?:NSHostingView\b|\w*[Hh]osting\w*)"#)

    /// 1-based lines that assign a hosting view straight to `contentView`, comments skipped.
    private static func offenders(in text: String) -> [Int] {
        var out: [Int] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
            let string = String(line)
            if pattern.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil {
                out.append(index + 1)
            }
        }
        return out
    }

    /// Every `.swift` under `Kannu/`, keyed by repo-relative path.
    private static func appSources() -> [String: String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let kannu = root.appendingPathComponent("Kannu")
        var out: [String: String] = [:]
        guard let walker = FileManager.default.enumerator(at: kannu, includingPropertiesForKeys: nil) else { return out }
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            out[relative] = try? String(contentsOf: url, encoding: .utf8)
        }
        return out.compactMapValues { $0 }
    }
}
