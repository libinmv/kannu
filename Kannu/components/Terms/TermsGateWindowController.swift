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
import Defaults
import SwiftUI

/// Holds Kannu's whole launch behind the Terms of Use.
///
/// `AppDelegate.applicationDidFinishLaunching` starts nothing but the crash marker, the hang
/// watchdog, the updater and the orphan reaper until `TermsOfUse.isAccepted(acceptedVersion:)` is
/// true; otherwise it shows this window and waits. Accept records the version and the time and hands
/// control back through `onAccept`, which continues the launch. Decline quits.
///
/// A titled, `.normal`-level window like onboarding's — never a borderless notch panel, which cannot
/// be focused, and never `runModal`, which docs/REGRESSIONS.md entry 14 bans. The content goes in
/// through `setHostedContent` (entry 17), so SwiftUI never sizes the window.
@MainActor
final class TermsGateWindowController {
    static let shared = TermsGateWindowController()

    private var window: NSWindow?
    private var onAccept: (() -> Void)?

    private init() {}

    var isShowing: Bool { window?.isVisible == true }

    func show(onAccept: @escaping () -> Void) {
        self.onAccept = onAccept
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 580, height: 660),
                styleMask: [.titled, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = String(localized: "Kannu Terms of Use")
            window.minSize = NSSize(width: 520, height: 560)
            window.isRestorable = false
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("TermsOfUseGateWindow")
            window.setHostedContent(NSHostingView(rootView: TermsOfUseView(
                termsText: LegalDocuments.termsText(),
                onAccept: { [weak self] in self?.accept() },
                onDecline: { NSApp.terminate(nil) }
            )))
            window.center()
            self.window = window
        }
        bringToFront()
    }

    /// Also used when the user clicks the Dock icon or the Settings menu item before accepting.
    func bringToFront() {
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func accept() {
        Defaults[.termsAcceptedVersion] = TermsOfUse.currentVersion
        Defaults[.termsAcceptedAt] = Date()
        window?.orderOut(nil)
        window?.close()
        window = nil
        NSApp.setActivationPolicy(.accessory)
        let continueLaunch = onAccept
        onAccept = nil
        continueLaunch?()
    }
}
