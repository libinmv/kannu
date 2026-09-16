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

import AppKit

/// The one way Kannu puts a file panel or an alert on screen.
///
/// A file panel's `runModal()` enters a nested modal run loop, and this app keeps publishing on the
/// main queue while that loop turns — `ADRConnection`, `SecurityFindingsStore` and the session
/// monitor all deliver there — so SwiftUI re-enters layout on a hosting view underneath the modal
/// session. That is the shape of the SIGABRT recorded in CHANGELOG on 2026-08-29
/// (`_postWindowNeedsUpdateConstraints` from `NSHostingView.invalidateSafeAreaCornerInsets`), which
/// was fixed for the borderless panels only. A live sample of a stuck build caught the other half:
/// the main thread parked in `choosePolicyFile()` → `-[NSSavePanel runModal]` →
/// `runModalForWindow:` with the panel out of reach, which reads to the user as a freeze, or as a
/// crash once they force-quit.
///
/// Two rules come out of that, and `.githooks/pre-commit` plus `ModalPresentationRulesTests`
/// enforce the first one:
///
/// 1. **A file panel is never modal.** `NSSavePanel` has `begin(completionHandler:)`, so there is
///    no reason to stop the run loop for one. As a sheet, or presented on its own, the completion
///    arrives on the main actor and everything else keeps drawing.
/// 2. **An alert the user cannot see is what turns a modal session into a hang.** AppKit has no
///    non-modal presentation for `NSAlert`, so an alert with no window to hang from still runs
///    app-modal — but the app is brought forward first and the alert is raised above Kannu's own
///    panels, so there is always a visible dialog to dismiss.
@MainActor
enum ModalPresenter {

    // MARK: - What is on screen

    /// Panels and alerts presented through here that have not completed yet. The notch consults
    /// this before opening. It used to infer the fact from `NSApp.modalWindow` and `attachedSheet`,
    /// which missed the `panel.begin` fallback below (neither modal nor a sheet — the normal path
    /// when Settings is closed, so the notch opened over the very picker the user had to answer)
    /// and caught every unrelated SwiftUI `.sheet` on Settings, which locked the notch out for as
    /// long as the Spotify sign-in was up.
    private(set) static var presentedCount = 0
    static var isPresenting: Bool { presentedCount > 0 }

    /// Alerts waiting for the one on screen. A second alert while the first is a sheet on Settings
    /// found no anchor (the window already had a sheet) and fell to app-modal, over the sheet.
    private static var pendingAlerts: [(NSAlert, (NSApplication.ModalResponse) -> Void)] = []

    // MARK: - Anchors

    /// A window a sheet may safely hang from, or nil.
    ///
    /// Kannu is an accessory app and nearly every window it owns is a borderless
    /// `.nonactivatingPanel` at `.mainMenu + 3` — the notch (`KannuWindow.swift`) and the
    /// ScreenAssistant chat panels. A sheet anchored to one of those inherits that level and its
    /// refusal to activate, so it can be neither focused nor moved aside: the same freeze wearing a
    /// different hat. Only a titled window at the normal level qualifies, which in practice means
    /// Settings.
    static func sheetAnchorWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.isVisible
                && window.styleMask.contains(.titled)
                && window.level == .normal
                && window.attachedSheet == nil
        }
    }

    // MARK: - File panels

    /// Presents an open or save panel without ever entering a modal run loop.
    ///
    /// `NSOpenPanel` is an `NSSavePanel`, so this covers both.
    static func present(_ panel: NSSavePanel, completion handler: @escaping (NSApplication.ModalResponse) -> Void) {
        // The notch panels are non-activating, so the app is not necessarily front when one of its
        // buttons is clicked; a picker behind another app is the freeze again.
        NSApp.activate(ignoringOtherApps: true)
        presentedCount += 1
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            presentedCount -= 1
            handler(response)
            drainPendingAlerts()
        }
        if let window = sheetAnchorWindow() {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    // MARK: - Alerts

    /// Shows an alert and reports the button the user pressed.
    ///
    /// With a titled window on screen this is a sheet and no run loop is nested. Without one it is
    /// app-modal, raised and activated so it is on screen, and `completion` runs once it closes.
    static func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void = { _ in }) {
        // One at a time. The next one is shown from the current one's completion.
        if isPresenting {
            pendingAlerts.append((alert, completion))
            return
        }
        if let window = sheetAnchorWindow() {
            NSApp.activate(ignoringOtherApps: true)
            presentedCount += 1
            alert.beginSheetModal(for: window) { response in
                presentedCount -= 1
                completion(response)
                drainPendingAlerts()
            }
            return
        }
        completion(runAppModal(alert))
        drainPendingAlerts()
    }

    private static func drainPendingAlerts() {
        guard !isPresenting, !pendingAlerts.isEmpty else { return }
        let (alert, completion) = pendingAlerts.removeFirst()
        present(alert, completion: completion)
    }

    /// App-modal, for the callers that cannot return until they know the answer — a restart prompt,
    /// a consent gate, an accessory view whose controls only work inside a modal session.
    ///
    /// Always activate and raise first: an alert at the default `.modalPanel` level renders
    /// *underneath* the notch window at `.mainMenu + 3`, so the user sees a stopped app and no
    /// dialog and has nothing to dismiss.
    @discardableResult
    static func runAppModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        raiseAboveOwnWindows(alert)
        presentedCount += 1
        defer { presentedCount -= 1 }
        // A dialog waiting for the user is a stopped main thread on purpose, so the hang watchdog
        // must not call it a freeze. This is the only place that has to say so.
        return HangWatchdog.shared.duringExpectedStall { alert.runModal() }
    }

    private static func raiseAboveOwnWindows(_ alert: NSAlert) {
        let highest = NSApp.windows
            .filter(\.isVisible)
            .map(\.level.rawValue)
            .max() ?? NSWindow.Level.normal.rawValue
        if highest >= alert.window.level.rawValue {
            alert.window.level = NSWindow.Level(rawValue: highest + 1)
        }
    }
}
