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

/// Keeps modal presentation in one place.
///
/// A user clicked the ADR policy picker and Kannu froze. A sample of the stuck process named it:
/// `choosePolicyFile()` → `-[NSSavePanel runModal]` → `-[NSApplication runModalForWindow:]`,
/// parked in `__CFRunLoopRun` for 1,596 of 1,599 samples at 0 % CPU with the panel out of reach.
/// `runModal()` stops the main run loop while `ADRConnection`, `SecurityFindingsStore` and the
/// session monitor keep publishing on the main queue, so SwiftUI re-enters layout underneath the
/// modal session — the same shape as the 2026-08-29 SIGABRT in CHANGELOG.
///
/// `beginSheetModal` is the other half. Nearly every window Kannu owns is a borderless
/// `.nonactivatingPanel` at `.mainMenu + 3` (the notch, the ScreenAssistant chat panels), and a
/// sheet anchored to one of those inherits that level and its refusal to activate, so it can be
/// neither focused nor moved aside.
///
/// Five call sites were converted once. This test is what stops the sixth being written: both APIs
/// live in `ModalPresenter` and nowhere else. `.githooks/pre-commit` runs the same rule, and this
/// runs it again in CI for anything committed with `--no-verify`.
final class ModalPresentationRulesTests: XCTestCase {

    /// The one file allowed to touch AppKit's modal APIs.
    private static let allowedPaths: Set<String> = ["Kannu/helpers/ModalPresenter.swift"]

    /// Line fragments that mean "a modal session is being started here".
    private static let bannedFragments = [".runModal(", "beginSheetModal"]

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root

    // MARK: - The rule

    func testModalPresentationLivesOnlyInTheHelper() {
        let sources = Self.appSources()
        XCTAssertGreaterThan(sources.count, 100, "The source scan found almost nothing — check the path, not the rule.")
        XCTAssertNotNil(sources["Kannu/helpers/ModalPresenter.swift"], "ModalPresenter.swift was not read; the allowlist would pass vacuously.")

        var offenders: [String] = []
        for (path, source) in sources where !Self.allowedPaths.contains(path) {
            offenders.append(contentsOf: Self.offenders(in: source, path: path))
        }

        XCTAssertEqual(
            offenders.sorted(), [],
            """
            runModal()/beginSheetModal outside ModalPresenter. A file panel's modal run loop freezes \
            the app, and a sheet on one of Kannu's non-activating notch panels cannot be reached. \
            Use ModalPresenter.present(panel:), ModalPresenter.present(alert:), or \
            ModalPresenter.runAppModal(alert) when the answer is needed before returning.
            """
        )
    }

    /// The allowlist is a list of exceptions, so it has to stay one entry long — every new name on
    /// it is a site that can freeze the app again.
    func testTheAllowlistIsExactlyTheHelper() {
        XCTAssertEqual(Self.allowedPaths, ["Kannu/helpers/ModalPresenter.swift"])
        for path in Self.allowedPaths {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: Self.repoRoot.appendingPathComponent(path).path),
                "Allowlisted \(path) does not exist — a rename left the ban pointing at nothing."
            )
        }
    }

    /// The helper is only an improvement if it presents panels without a modal loop, so pin that:
    /// a sheet when there is a window to hang it from, `begin` when there is not.
    func testTheHelperPresentsPanelsWithoutAModalLoop() throws {
        let source = try XCTUnwrap(Self.appSources()["Kannu/helpers/ModalPresenter.swift"])
        XCTAssertTrue(source.contains("panel.begin(completionHandler: completion)"))
        XCTAssertTrue(source.contains("panel.beginSheetModal(for: window, completionHandler: completion)"))
        XCTAssertFalse(source.contains("panel.runModal()"), "Even the helper must never run a file panel modally.")
        XCTAssertTrue(source.contains("NSApp.activate"), "An unactivated panel can still land behind another app.")
    }

    // MARK: - The scanner itself

    /// Guards the detector, not the tree: a regex that matched nothing would make the rule above
    /// pass forever.
    func testTheScannerCatchesEveryShapeOfOffender() {
        let planted = """
        func choose() {
            let panel = NSOpenPanel()
            let response = panel.runModal()
            alert.beginSheetModal(for: window) { _ in }
            _ = savePanel.runModal()
        }
        """
        XCTAssertEqual(Self.offenders(in: planted, path: "X.swift").count, 3)
    }

    /// A comment explaining the rule must not trip it — that is how the `.help(` ban in
    /// `.githooks/pre-commit` learned to strip the prefix first.
    func testCommentsAboutTheRuleAreNotOffenders() {
        let prose = """
        /// Never call panel.runModal() here.
        // beginSheetModal on the notch cannot be reached.
         * `alert.runModal()` is what froze the app.
        """
        XCTAssertEqual(Self.offenders(in: prose, path: "X.swift"), [])
    }

    // MARK: - Helpers

    private static func offenders(in source: String, path: String) -> [String] {
        var hits: [String] = []
        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
            if bannedFragments.contains(where: { line.contains($0) }) {
                hits.append("\(path):\(index + 1)")
            }
        }
        return hits
    }

    /// Every Swift file under `Kannu/`, keyed by its repo-relative path.
    private static func appSources() -> [String: String] {
        let root = repoRoot.appendingPathComponent("Kannu")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
        var out: [String: String] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let path = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            out[path] = text
        }
        return out
    }
}
