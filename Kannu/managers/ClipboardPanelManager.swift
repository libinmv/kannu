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
import os
import SwiftUI

class ClipboardPanelManager: ObservableObject {
    static let shared = ClipboardPanelManager()

    private var clipboardPanel: ClipboardPanel?

    private init() {}

    private static let spacesLog = os.Logger(subsystem: "com.kannu.app", category: "ClipboardSpaces")

    func showClipboardPanel() {
        hideClipboardPanel() // Close any existing panel

        let panel = ClipboardPanel()
        panel.positionNearNotch()

        self.clipboardPanel = panel

        // A `.nonactivatingPanel` takes key without activating the app — that is its design.
        // The app-activation call that used to sit here pulled macOS toward
        // Kannu's own spaces from inside another app's fullscreen space, which is how the panel
        // ended up "running, but not visible" (2026-09-30). Text input works through
        // `canBecomeKey` and the `makeKey()` calls alone.
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        repairVisiblePanelSpaces(context: "show")

        // Ensure the panel becomes the key window for text input
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            panel.makeKey()
        }
    }

    /// #67's space repair, applied at the one moment it matters for this panel: right after it
    /// is ordered in. macOS can strip an all-spaces window's membership around a sleep or lock
    /// (docs/REGRESSIONS.md, 2026-09-30 addendum) — the window stays alive, opaque and ordered
    /// in, yet absent from the fullscreen space the user is on. Re-adding it to the managed
    /// spaces is the only repair measured to work; it costs nothing when the panel is healthy.
    func repairVisiblePanelSpaces(context: String) {
        guard let panel = clipboardPanel,
              ClosedNotchVisibility.shouldRejoinSpaces(
                  isOnActiveSpace: panel.isOnActiveSpace,
                  isOrderedIn: panel.isVisible,
                  hiddenForLock: false,
                  screenLocked: false
              ) else { return }
        let spaces = CGSSpace.rejoinAllManagedSpaces([panel])
        Self.spacesLog.notice("Clipboard panel was off the active space at \(context, privacy: .public); re-added to \(spaces, privacy: .public) spaces, onActive=\(panel.isOnActiveSpace, privacy: .public)")
    }

    #if DEBUG
    /// For `--kannu-strand-clipboard` only: the live panel, so the strand-and-repair round trip
    /// can be exercised on the real window.
    var debugVisiblePanel: NSPanel? { clipboardPanel }
    #endif

    func hideClipboardPanel() {
        clipboardPanel?.close()
        clipboardPanel = nil
    }

    func toggleClipboardPanel() {
        if let panel = clipboardPanel, panel.isVisible {
            hideClipboardPanel()
        } else {
            showClipboardPanel()
        }
    }

    var isPanelVisible: Bool {
        return clipboardPanel?.isVisible ?? false
    }
}
