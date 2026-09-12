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

/// Shows a Settings file picker without blocking the main thread.
///
/// `runModal()` enters a nested modal run loop from inside a SwiftUI action, and this app keeps
/// publishing on the main queue while that loop runs — `ADRConnection`, `SecurityFindingsStore` and
/// the session monitor all deliver there — so SwiftUI re-enters layout on the Settings
/// `NSHostingView` underneath the modal session. That is the shape of the SIGABRT recorded in
/// CHANGELOG on 2026-08-29 (`_postWindowNeedsUpdateConstraints` from
/// `NSHostingView.invalidateSafeAreaCornerInsets`), which was fixed for the borderless panels only.
/// A live sample of a stuck build caught the other half: the main thread parked in
/// `choosePolicyFile()` → `-[NSSavePanel runModal]` → `runModalForWindow:` with the panel out of
/// reach, which reads to the user as a freeze, or as a crash once they force-quit.
///
/// As a sheet on the Settings window the panel owns only that window, the run loop keeps turning,
/// and the completion arrives on the main actor. With no Settings window on screen the panel is
/// still presented asynchronously — never modally.
@MainActor
enum SettingsFilePicker {
    static func present(_ panel: NSOpenPanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        // The notch panels are borderless and non-activating, so the app is not necessarily front
        // when a Settings button is clicked; a picker behind another app is the same freeze again.
        NSApp.activate()
        if let window = SettingsWindowController.shared.window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
