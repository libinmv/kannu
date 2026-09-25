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

import Foundation
import os

/// Brings the browser tab that is playing the media card's track to the front. Best-effort
/// by design: the browser is already activated by the caller, so every failure here — no
/// Automation permission, no matching tab, a script error — leaves the user in the right app
/// on whatever tab it had. macOS asks for "Kannu wants to control <browser>" once per browser;
/// a refusal is remembered for this launch so the click never re-prompts.
@MainActor
enum BrowserTabLocator {
    private static let log = os.Logger(subsystem: "com.kannu.app", category: "BrowserTab")
    private static var deniedBundleIdentifiers: Set<String> = []

    static func canLocate(bundleIdentifier: String) -> Bool {
        BrowserTabMatcher.family(forBundleIdentifier: bundleIdentifier) != nil
            && !deniedBundleIdentifiers.contains(bundleIdentifier)
    }

    @discardableResult
    static func bringPlayingTabForward(bundleIdentifier: String, title: String, artist: String?) async -> Bool {
        guard let family = BrowserTabMatcher.family(forBundleIdentifier: bundleIdentifier),
              !deniedBundleIdentifiers.contains(bundleIdentifier) else { return false }
        do {
            let listing = try await AppleScriptHelper.execute(
                BrowserTabMatcher.listingScript(family: family, bundleIdentifier: bundleIdentifier)
            )?.stringValue ?? ""
            let tabs = BrowserTabMatcher.parseListing(listing)
            guard let tab = BrowserTabMatcher.bestMatch(tabs: tabs, title: title, artist: artist) else {
                log.notice("no tab matches the playing title in \(bundleIdentifier, privacy: .public) (\(tabs.count) tabs)")
                return false
            }
            try await AppleScriptHelper.executeVoid(
                BrowserTabMatcher.selectScript(family: family, bundleIdentifier: bundleIdentifier, tab: tab)
            )
            log.notice("selected tab \(tab.windowIndex).\(tab.tabIndex) in \(bundleIdentifier, privacy: .public)")
            return true
        } catch let error as NSError {
            if error.domain == "AppleScriptError", (error.userInfo["NSAppleScriptErrorNumber"] as? Int) == -1743 {
                deniedBundleIdentifiers.insert(bundleIdentifier)
                log.notice("Automation not allowed for \(bundleIdentifier, privacy: .public); tab targeting off for this launch")
            } else {
                let message = (error.userInfo["NSAppleScriptErrorMessage"] as? String) ?? error.localizedDescription
                log.error("tab targeting failed: \(message, privacy: .public)")
            }
            return false
        }
    }
}
