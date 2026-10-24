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

/// `ScreenCaptureVisibility` decides which Kannu windows carry `NSWindow.sharingType = .none`. The
/// default shows everything, like the old toggle's default, so nobody's screenshots change on
/// update. "Hide the notch" keeps the notch and its satellites out while Brain and the other panels
/// stay capturable. The registrations are pinned from the source because the windows are AppKit and
/// the manager is not in the logic target.
final class ScreenCapturePolicyTests: XCTestCase {

    // MARK: - The rule

    func testTheDefaultHidesOnlyTheNotch() {
        XCTAssertTrue(ScreenCaptureVisibility.hideNotch.hides(.notch))
        XCTAssertFalse(ScreenCaptureVisibility.hideNotch.hides(.panel),
                       "a screenshot for a bug report must still show the Settings window")
    }

    func testHideEverythingHidesBothKinds() {
        XCTAssertTrue(ScreenCaptureVisibility.hideEverything.hides(.notch))
        XCTAssertTrue(ScreenCaptureVisibility.hideEverything.hides(.panel))
    }

    func testShowEverythingHidesNothing() {
        XCTAssertFalse(ScreenCaptureVisibility.showEverything.hides(.notch))
        XCTAssertFalse(ScreenCaptureVisibility.showEverything.hides(.panel))
    }

    /// Stored in Defaults: a renamed case silently resets everyone who chose it.
    func testRawValuesAreStable() {
        XCTAssertEqual(ScreenCaptureVisibility.allCases.map(\.rawValue), ["hideNotch", "hideEverything", "showEverything"])
        XCTAssertEqual(ScreenCaptureVisibility(rawValue: "hideNotch"), .hideNotch)
    }

    // MARK: - The key and the migration

    func testTheKeyDefaultsToShowingEverythingAndTheLegacyKeyIsReadRaw() throws {
        let constants = try Self.source("Kannu/models/Constants.swift")
        XCTAssertTrue(constants.contains("Key<ScreenCaptureVisibility>(\"screenCaptureVisibility\", default: .showEverything)"),
                      "the default no longer shows everything; a new default would change everyone's screenshots on update")
        XCTAssertFalse(constants.contains("Key<Bool>(\"hideDynamicIslandFromScreenCapture\""),
                       "a declared Key registers its default, so object(forKey:) would be non-nil for everyone and the migration would read a choice nobody made")
        XCTAssertTrue(constants.contains("UserDefaults.standard.object(forKey: \"hideDynamicIslandFromScreenCapture\") as? Bool"),
                      "the legacy toggle is no longer migrated")
    }

    // MARK: - Every window says what it is

    /// Windows that register as `.panel` stay in screenshots under "Hide the notch". A notch satellite
    /// registering as a panel would leak the notch back into captures, so the set is pinned.
    private static let panelFiles: Set<String> = [
        "Kannu/KannuApp.swift",                                           // onboarding window
        "Kannu/components/Settings/SettingsWindowController.swift",
        "Kannu/managers/ClipboardWindowManager.swift",
        "Kannu/components/Clipboard/ClipboardPanel.swift",
        "Kannu/components/ScreenAssistant/ScreenAssistantPanel.swift",
        "Kannu/components/ScreenAssistant/ModelSelectionPanel.swift",
        "Kannu/components/ScreenAssistant/ChatPanels.swift",
    ]

    func testEveryRegistrationNamesWhatTheWindowIs() throws {
        let sources = try Self.appSources()
        XCTAssertGreaterThan(sources.count, 100, "the scan read too few files")
        var registrations = 0
        var panelFiles: Set<String> = []
        var notchFiles: Set<String> = []
        for (path, text) in sources {
            for line in text.split(separator: "\n") where line.contains("ScreenCaptureVisibilityManager.shared.register(") {
                registrations += 1
                if line.contains("scope: .panel)") {
                    panelFiles.insert(path)
                } else if line.contains("scope: .notch)") {
                    notchFiles.insert(path)
                } else {
                    XCTFail("\(path): a registration names neither .notch nor .panel: \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(registrations, 20, "the scan found too few registrations")
        XCTAssertEqual(panelFiles, Self.panelFiles, "the set of windows that stay in screenshots under \"Hide the notch\" changed")
        XCTAssertTrue(notchFiles.contains("Kannu/components/Notch/KannuWindow.swift"),
                      "the notch window itself must register as .notch")
        XCTAssertTrue(panelFiles.isDisjoint(with: notchFiles), "a file registers both kinds; make sure that is deliberate")
    }

    /// The fullscreen artwork shows five windows; the wallpaper transition and the looping video
    /// were the two never registered, so "Hide the notch" did not reach them (CodeRabbit on #126).
    func testEveryFullscreenArtworkWindowIsRegistered() throws {
        let source = try Self.source("Kannu/managers/FullScreenArtworkWindowManager.swift")
        for function in ["func showWallpaperTransition(", "func showVideoWindow("] {
            let start = try XCTUnwrap(source.range(of: function), "\(function) went away; update this test")
            let rest = source[start.upperBound...]
            let end = rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex
            XCTAssertTrue(rest[..<end].contains("ScreenCaptureVisibilityManager.shared.register(newWindow, scope: .notch)"),
                          "\(function) shows a window the screenshot setting does not know about")
        }
    }

    /// The setting can only ask: `sharingType = .none` is a legacy value some capture tools ignore,
    /// so no description may promise that a window stays out of a capture.
    func testTheDescriptionsDoNotPromiseExclusion() {
        for option in [ScreenCaptureVisibility.hideNotch, .hideEverything] {
            XCTAssertTrue(option.description.contains("Some capture tools ignore this"), "\(option) promises more than macOS gives")
            XCTAssertFalse(option.description.contains("stay out of") || option.description.contains("stays out of"),
                           "\(option) promises exclusion")
        }
    }

    // MARK: - Helpers

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static func appSources() throws -> [String: String] {
        let root = repoRoot.appendingPathComponent("Kannu", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var out: [String: String] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = "Kannu/" + url.path.dropFirst(root.path.count + 1)
            out[relative] = try String(contentsOf: url, encoding: .utf8)
        }
        return out
    }
}
