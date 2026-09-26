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

/// Source-level pins for the blank-notch fix. `KannuViewModel`, `AppDelegate` and
/// `FullscreenMediaDetector` are `@MainActor` AppKit/SwiftUI types with no unit surface, so the
/// parts of the fix that are *ordering* and *defaults* rather than arithmetic are pinned by reading
/// the source — the `ClosedNotchObservationTests` / `ModalPresentationRulesTests` pattern, including
/// their anti-vacuity devices.
final class ClosedNotchVisibilityRulesTests: XCTestCase {

    /// The flag's whole job is to hide for a *detected* fullscreen app. Initialising it `true` means
    /// "invisible until proven otherwise", and while the detector had no signal that was permanent.
    func testHideOnClosedStartsFalse() throws {
        let text = try XCTUnwrap(Self.appSources()["Kannu/models/KannuViewModel.swift"])
        XCTAssertTrue(
            text.contains("@Published var hideOnClosed: Bool = false"),
            """
            hideOnClosed must be initialised false. Defaulting to true hid every closed-notch \
            surface until the detector spoke, and when it never spoke the app had no UI at all.
            """
        )
        XCTAssertFalse(
            text.contains("@Published var hideOnClosed: Bool = true"),
            "hideOnClosed is back to defaulting to hidden."
        )
    }

    /// The detector chain must not be gated on a resolved screen. `compactMap` swallowed the initial
    /// nil and `CombineLatest` then emitted nothing, so the flag kept its initialiser forever.
    func testTheDetectorChainIsNotGatedOnAResolvedScreen() throws {
        let text = try XCTUnwrap(Self.appSources()["Kannu/models/KannuViewModel.swift"])
        let observer = try XCTUnwrap(
            Self.body(ofFunction: "setupDetectorObserver", in: text),
            "setupDetectorObserver went away — this pin is now vacuous, update it"
        )
        XCTAssertFalse(
            Self.strippingComments(observer).contains("compactMap"),
            """
            setupDetectorObserver filters the screen again. A nil screen must answer \
            "not fullscreen" via ClosedNotchVisibility, not drop out of the publisher.
            """
        )
        // Positive counterpart: deleting the delegation must not pass either.
        XCTAssertTrue(
            observer.contains("ClosedNotchVisibility.shouldHideClosedNotch"),
            "the verdict must come from the tested rule, not be re-implemented inline"
        )
    }

    /// The ordering this bug got wrong. `vm.screen` was assigned only inside
    /// `adjustWindowPosition`, below a lock guard that returns early — so a launch while the screen
    /// was locked, or in clamshell, left it nil for the whole session. Launch must seed it itself,
    /// *before* handing off to `adjustWindowPosition`, which may legitimately bail.
    ///
    /// Scoped to the launch function on purpose: `guard !windowsHiddenForLock` appears in several
    /// methods, so comparing offsets across the whole file compares unrelated code.
    func testLaunchSeedsTheScreenBeforeHandingOffToAdjustWindowPosition() throws {
        let text = try XCTUnwrap(Self.appSources()["Kannu/KannuApp.swift"])
        let launch = try XCTUnwrap(
            Self.body(ofFunction: "applicationDidFinishLaunching", in: text),
            "applicationDidFinishLaunching went away — this pin is now vacuous, update it"
        )
        let seed = try XCTUnwrap(
            launch.range(of: "viewModel.screen = screen.localizedName")?.lowerBound,
            """
            The launch path no longer seeds the shared view model's screen. Without it a launch \
            while locked leaves `screen` nil, the fullscreen detector's sink never resolves, and \
            hideOnClosed stays latched — an unpainted, zero-height notch for the whole session.
            """
        )
        // Positioning must still happen *after* the seed. Checking "the first adjustWindowPosition
        // in the function" would be wrong: launch also registers notification observers whose
        // closures mention it, and those are registrations, not calls.
        XCTAssertTrue(
            launch[seed...].contains("adjustWindowPosition("),
            """
            Launch seeds the screen but never hands off to adjustWindowPosition afterwards, so the \
            window is never positioned. Seed first, then position.
            """
        )
    }

    /// A missing Accessibility grant must not be read as "this app is fullscreen". It used to be,
    /// which hid the notch for any maximized window on a fresh install (a new code identity drops
    /// every TCC grant).
    func testAnUntrustedProcessDoesNotAssertFullscreen() throws {
        let text = try XCTUnwrap(Self.appSources()["Kannu/observers/FullscreenMediaDetection.swift"])
        XCTAssertTrue(
            text.contains("guard AXIsProcessTrusted() else {"),
            "the Accessibility check went away — this pin is now vacuous, update it"
        )
        XCTAssertFalse(
            text.contains("guard AXIsProcessTrusted() else { return true }"),
            """
            Without the Accessibility grant Kannu cannot tell fullscreen from maximized. Answering \
            true hides the whole product on a guess; answer false and surface the missing grant.
            """
        )
    }

    /// The recovery path for a dropped `com.apple.screenIsUnlocked`: the lock manager's poll clears
    /// the state, and something must tell AppDelegate so the self-heal inside
    /// `adjustWindowPosition` is actually reached.
    func testClearingTheLockStateNotifiesTheWindowOwner() throws {
        let sources = Self.appSources()
        let lock = try XCTUnwrap(sources["Kannu/managers/LockScreenManager.swift"])
        let app = try XCTUnwrap(sources["Kannu/KannuApp.swift"])
        XCTAssertTrue(
            lock.contains("NotificationCenter.default.post(name: .lockStateDidClear"),
            "screenUnlocked must announce that it cleared the lock state, poll-driven or not"
        )
        XCTAssertTrue(
            app.contains("forName: Notification.Name.lockStateDidClear"),
            "AppDelegate must observe lockStateDidClear, or the dropped-unlock self-heal never runs"
        )
    }

    // MARK: - Helpers

    /// The text of a function body, from its declaration to the next declaration at the same indent.
    /// Crude on purpose: enough to scope a pin to one function without parsing Swift.
    private static func body(ofFunction name: String, in text: String) -> String? {
        guard let start = text.range(of: "func \(name)(") else { return nil }
        let rest = text[start.upperBound...]
        let candidates = ["\n    private func ", "\n    func ", "\n    @objc func ",
                          "\n    @objc private func "]
        let end = candidates.compactMap { rest.range(of: $0)?.lowerBound }.min()
        guard let end else { return String(rest) }
        return String(rest[..<end])
    }

    /// Comments must neither trigger a pin nor mask one — a doc comment explaining the very trap a
    /// rule guards against would otherwise fail the rule. (It did, the first time this ran.)
    private static func strippingComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("/*")
            }
            .joined(separator: "\n")
    }

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

    /// Anti-vacuous: a broken path must fail loudly rather than scanning nothing.
    func testTheScanReadTheRealTree() {
        let sources = Self.appSources()
        XCTAssertGreaterThan(sources.count, 100, "the scan read too few files — fix appSources()")
        for path in [
            "Kannu/models/KannuViewModel.swift",
            "Kannu/KannuApp.swift",
            "Kannu/observers/FullscreenMediaDetection.swift",
            "Kannu/managers/LockScreenManager.swift",
        ] {
            XCTAssertNotNil(sources[path], "\(path) was not read — every pin above would pass vacuously")
        }
    }
}
