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
        // The launch proper lives in `continueLaunch()` since the Terms of Use gate:
        // `applicationDidFinishLaunching` now only starts the invariants and decides whether to
        // show the gate, and the screen seed moved with the rest of the launch, unchanged.
        let launch = try XCTUnwrap(
            Self.body(ofFunction: "continueLaunch", in: text),
            "continueLaunch went away — this pin is now vacuous, update it"
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

    /// CodeRabbit on #109: two inputs to the verdict changed with nothing re-checking. Granting or
    /// revoking Accessibility switches between `AXFullScreen` and the menu-bar fallback, and the
    /// fallback's menu bar can still be sliding when the 500 ms settle reads it, so the fallback
    /// takes one more pass after it.
    func testTheVerdictIsReadAgainWhenItsInputsChange() throws {
        let text = try XCTUnwrap(Self.appSources()["Kannu/observers/FullscreenMediaDetection.swift"])
        let observers = try XCTUnwrap(Self.body(ofFunction: "setupNotificationObservers", in: text),
                                      "setupNotificationObservers went away — this pin is now vacuous, update it")
        XCTAssertTrue(observers.contains("AccessibilityPermissionStore.shared.$isAuthorized")
                      && observers.contains("self?.handleChange()"),
                      "a change to the Accessibility grant no longer re-reads fullscreen")
        let change = try XCTUnwrap(Self.body(ofFunction: "handleChange", in: text), "handleChange went away")
        let code = Self.strippingComments(change)
        XCTAssertEqual(code.components(separatedBy: "self.updateFullScreenStatus()").count - 1, 2,
                       "the fallback no longer looks again after the menu bar's slide")
        XCTAssertTrue(code.contains("guard !AXIsProcessTrusted() else { return }"),
                      "the second look is for the fallback only; AXFullScreen needs no wait")
    }

    /// `fullscreenStatus` is main-actor state, but the detector reads screens and windows off the
    /// main thread (an Accessibility read of an unresponsive app can wait). The verdict reaches the
    /// property through one `@MainActor` function, and nothing else assigns it.
    func testTheVerdictIsPublishedOnTheMainActor() throws {
        let text = try XCTUnwrap(Self.appSources()["Kannu/observers/FullscreenMediaDetection.swift"])
        let publish = try XCTUnwrap(Self.body(ofFunction: "publish", in: text),
                                    "publish went away — this pin is now vacuous, update it")
        XCTAssertTrue(publish.contains("fullscreenStatus = newStatus"), "publish(_:) no longer assigns the verdict")
        XCTAssertTrue(publish.contains("ticket == scanGeneration"),
                      "a scan that finished late can overwrite a newer verdict (CodeRabbit on #112)")
        XCTAssertTrue(text.contains("@MainActor\n    private func publish("), "publish(_:) must be @MainActor")
        let assignments = Self.strippingComments(text).components(separatedBy: "fullscreenStatus = ").count - 1
        XCTAssertEqual(assignments, 1, "fullscreenStatus is assigned somewhere other than publish(_:)")
        XCTAssertFalse(Self.strippingComments(text).contains("Dictionary(uniqueKeysWithValues:"),
                       "two displays can share a localizedName; uniqueKeysWithValues traps on it")
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
    /// The stranded-notch repair has to stay wired to where it shows: a space switch, a wake, an
    /// unlock. Unhooking any of them brings back "the notch is gone in this fullscreen app until I
    /// relaunch" (2026-09-30), and nothing else in the app would notice.
    func testAStrandedNotchIsCheckedOnSpaceChangeWakeAndUnlock() throws {
        let text = try XCTUnwrap(Self.appSources()["Kannu/KannuApp.swift"])
        let launch = try XCTUnwrap(Self.body(ofFunction: "continueLaunch", in: text))
        XCTAssertTrue(launch.contains("NSWorkspace.activeSpaceDidChangeNotification"),
                      "the launch no longer watches space switches for a stranded notch")
        XCTAssertTrue(launch.contains("NSWorkspace.didWakeNotification"),
                      "the launch no longer checks the notch after a wake")
        let restore = try XCTUnwrap(Self.body(ofFunction: "restoreWindowsAfterLock", in: text))
        XCTAssertTrue(restore.contains("rejoinNotchSpacesIfNeeded("),
                      "unlocking no longer checks whether the notch was stranded")
        let repair = Self.strippingComments(try XCTUnwrap(Self.body(ofFunction: "rejoinNotchSpacesIfNeeded", in: text)))
        XCTAssertTrue(repair.contains("reassertShown()") && repair.contains("pinNotchWindows(notchWindows, after: reason)"),
                      "the repair no longer shows the notch space and pins the windows")
        let pin = Self.strippingComments(try XCTUnwrap(Self.body(ofFunction: "pinNotchWindows", in: text),
                                                       "pinNotchWindows went away — this pin is now vacuous, update it"))
        XCTAssertTrue(pin.contains("ClosedNotchVisibility.notchSpaceRepair("),
                      "the pin no longer asks the tested decision")
        XCTAssertTrue(pin.contains("CGSSpace.rejoinAllManagedSpaces("),
                      "the fallback no longer puts an unseen notch back on the managed spaces (2026-09-30)")
        // Never strip a window before the notch space is confirmed to hold it.
        let add = try XCTUnwrap(pin.range(of: "notchSpace.add("), "the pin no longer joins the notch space")
        let readBack = try XCTUnwrap(pin.range(of: "CGSSpace.spaceIDs(of: window)", range: add.upperBound..<pin.endIndex),
                                     "the join is no longer read back")
        let strip = try XCTUnwrap(pin.range(of: "CGSSpace.remove(", range: add.upperBound..<pin.endIndex))
        XCTAssertLessThan(readBack.lowerBound, strip.lowerBound, "the join must be confirmed before any space is left")
        // A strip that leaves the window off screen is undone and remembered, or the fallback and
        // the strip undo each other at every check.
        XCTAssertEqual(pin.components(separatedBy: "keepVisibleAfterStrip(window, after: reason)").count - 1, 2,
                       "both strips must check the window is still on screen")
        XCTAssertTrue(pin.contains("notchSpaceUnseen: notchSpaceUnseenWindows.contains(window.windowNumber)"),
                      "the decision no longer hears about an earlier fallback")
        // A refused join must not leave the window in no space: the fallback and the refused join
        // both put it back on the managed spaces.
        XCTAssertEqual(pin.components(separatedBy: "CGSSpace.rejoinAllManagedSpaces([window])").count - 1, 2,
                       "a refused join or an unseen notch no longer falls back to the managed spaces")
    }

    /// The repair that made the notch a member of every space at the first switch after each
    /// launch (2026-10-22): `isOnActiveSpace` is false by design for a window that lives only in the
    /// notch space, and emptying the space before re-adding left the window in no space for a moment.
    func testTheNotchRepairDoesNotUseTheOldSignals() throws {
        let text = Self.strippingComments(try XCTUnwrap(Self.appSources()["Kannu/KannuApp.swift"]))
        XCTAssertFalse(text.contains("isOnActiveSpace: $0.isOnActiveSpace"),
                       "the notch repair decides on isOnActiveSpace again")
        XCTAssertFalse(text.contains("notchSpace.windows = []"),
                       "the notch space is emptied to re-sync again")
    }

    private static func body(ofFunction name: String, in text: String) -> String? {
        guard let start = text.range(of: "func \(name)(") else { return nil }
        let rest = text[start.upperBound...]
        let candidates = ["\n    private func ", "\n    func ", "\n    @objc func ",
                          "\n    @objc private func ", "\n    @MainActor private func ",
                          "\n    private static func ", "\n    @MainActor\n    private func "]
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
