/*
 * Kannu (കണ്ണ്)
 * Copyright (C) 2024-2026 Kannu Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Kannu (കണ്ണ്)
 * See NOTICE for details.
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

import ApplicationServices
import Combine
import Defaults
import MacroVisionKit
import SwiftUI

class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()
    private let detector: MacroVisionKit
    @ObservedObject private var musicManager = MusicManager.shared
    @MainActor @Published private(set) var fullscreenStatus: [String: Bool] = [:]
    private var notificationTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        self.detector = MacroVisionKit.shared
        detector.configuration.includeSystemApps = true
        setupNotificationObservers()
        updateFullScreenStatus()
    }

    private func setupNotificationObservers() {
        notificationTask = Task { @Sendable [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    let activeSpaceNotifications = NSWorkspace.shared.notificationCenter.notifications(
                        named: NSWorkspace.activeSpaceDidChangeNotification
                    )
                    
                    for await _ in activeSpaceNotifications {
                        await self?.handleChange()
                    }
                }
                
                group.addTask {
                    let screenParameterNotifications = NSWorkspace.shared.notificationCenter.notifications(
                        named:  NSApplication.didChangeScreenParametersNotification
                    )

                    for await _ in screenParameterNotifications {
                        await  self?.handleChange()
                    }
                }
            }
        }

        // A space change is not the only input to the verdict. Fullscreen entered *before*
        // pressing play never re-checked, so the notch stayed out for the whole video: the
        // now-playing app and its play state are inputs too, as is the hide option itself.
        // Everything funnels through `handleChange`'s 500 ms settle.
        musicManager.$bundleIdentifier
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in Task { await self?.handleChange() } }
            .store(in: &cancellables)
        musicManager.$isPlaying
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in Task { await self?.handleChange() } }
            .store(in: &cancellables)
        Defaults.publisher(.hideNotchOption, options: [])
            .sink { [weak self] _ in Task { await self?.handleChange() } }
            .store(in: &cancellables)
        Defaults.publisher(.enableFullscreenMediaDetection, options: [])
            .sink { [weak self] _ in Task { await self?.handleChange() } }
            .store(in: &cancellables)
    }

    private func handleChange() async {
        try? await Task.sleep(for: .milliseconds(500))
        self.updateFullScreenStatus()
    }

    private func updateFullScreenStatus() {
        guard Defaults[.enableFullscreenMediaDetection] else {
            let reset = Dictionary(uniqueKeysWithValues: NSScreen.screens.map { ($0.localizedName, false) })
            if reset != fullscreenStatus {
                fullscreenStatus = reset
            }
            return
        }
        

        let apps = detector.detectFullscreenApps(debug: false)
        let names = NSScreen.screens.map { $0.localizedName }
        let hideOption = Defaults[.hideNotchOption]
        // One window snapshot per pass: the AX-denied fallback reads each screen's menu-bar
        // visibility, and must not pay a CGWindowList walk per candidate app.
        let menuBarByScreen = AXIsProcessTrusted() ? nil : menuBarVisibilityByScreen()

        var newStatus: [String: Bool] = [:]
        for name in names {
            newStatus[name] = apps.contains { app in
                guard app.screen.localizedName == name,
                      app.bundleIdentifier != "com.apple.finder" else { return false }

                // The notch stays on display by default (the window's collectionBehavior
                // rides along with fullscreen spaces). It only hides when the user's
                // "Hide DynamicIsland" option asks for it.
                switch hideOption {
                case .always:
                    // Hide for any app in genuine native fullscreen on this screen.
                    return isInNativeFullscreen(app, menuBarVisibleByScreen: menuBarByScreen)
                case .nowPlayingOnly:
                    // Hide only when the currently playing media app is in fullscreen.
                    return app.bundleIdentifier == musicManager.bundleIdentifier
                        && isInNativeFullscreen(app, menuBarVisibleByScreen: menuBarByScreen)
                case .never:
                    // Always on display; never hide.
                    return false
                }
            }
        }

        if newStatus != fullscreenStatus {
            fullscreenStatus = newStatus
            NSLog("✅ Fullscreen status: \(newStatus)")
        }
    }

    /// Says once, not on every window scan, that fullscreen detection is degraded. Without the
    /// grant Kannu cannot read `AXFullScreen`, so it falls back to the menu-bar probe
    /// (`FullscreenFallbackVerdict`), which misreads only when the menu bar is set to auto-hide.
    private static let accessibilityWarningOnce: Void = {
        NSLog("⚠️ Kannu: Accessibility is not granted, so fullscreen cannot be read exactly. "
              + "Falling back to the menu-bar probe; grant Accessibility for exact detection.")
    }()

    private static func warnAboutMissingAccessibilityOnce() {
        _ = accessibilityWarningOnce
    }

    /// Confirms an app the detector flagged as screen-filling is in *genuine* native
    /// fullscreen, not merely maximized/zoomed. On a notched Mac a maximized window and a
    /// fullscreen window report nearly identical frames, so frame size alone can't tell them
    /// apart — the Accessibility `AXFullScreen` attribute can.
    ///
    /// Without the Accessibility grant this used to answer `true` — "assume fullscreen" — which
    /// meant a freshly installed build (a new code identity drops every TCC grant) hid the notch
    /// for any *maximized* window under `.always`, and for a maximized media window under
    /// `.nowPlayingOnly`. Hiding the entire product on an unverifiable guess is the worse error.
    /// A later build answered a flat `false`, which erred the other way: every re-signed install
    /// silently stopped hiding over fullscreen video for good. An untrusted process now asks
    /// `FullscreenFallbackVerdict`: fullscreen iff the window covers the *whole* screen frame
    /// (nothing maximized can) or that screen's menu bar is gone — the one signal a maximized
    /// window can't fake without the menu bar set to auto-hide.
    private func isInNativeFullscreen(_ app: MacroVisionKit.FullscreenWindowInfo,
                                      menuBarVisibleByScreen: [String: Bool]?) -> Bool {
        guard AXIsProcessTrusted() else {
            Self.warnAboutMissingAccessibilityOnce()
            // Unknown visibility reads as "menu bar there" — the safe bias: show the notch.
            let menuBarVisible = menuBarVisibleByScreen?[app.screen.localizedName] ?? true
            return FullscreenFallbackVerdict.isLikelyFullscreen(
                windowFrame: app.windowFrame,
                screenFrame: app.screen.frame,
                menuBarVisible: menuBarVisible
            )
        }

        let appElement = AXUIElementCreateApplication(app.processId)

        // Prefer the focused window, then fall back to scanning all windows.
        if let focused: AXUIElement = copyAttribute(kAXFocusedWindowAttribute as CFString, from: appElement),
           isWindowFullscreen(focused) {
            return true
        }

        if let windows: [AXUIElement] = copyAttribute(kAXWindowsAttribute as CFString, from: appElement) {
            return windows.contains { isWindowFullscreen($0) }
        }

        return false
    }

    private func isWindowFullscreen(_ window: AXUIElement) -> Bool {
        // "AXFullScreen" is the (undocumented but stable) attribute set true only in native
        // fullscreen; maximized/zoomed windows report false or omit it.
        let value: Bool? = copyAttribute("AXFullScreen" as CFString, from: window)
        return value ?? false
    }

    private func copyAttribute<T>(_ attribute: CFString, from element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let typed = value as? T else { return nil }
        return typed
    }

    /// Each screen's menu-bar visibility from one `CGWindowList` snapshot, converted to AppKit
    /// coordinates the way MacroVisionKit converts its own. Only taken while the Accessibility
    /// grant is missing — with the grant, `AXFullScreen` answers and this never runs.
    private func menuBarVisibilityByScreen() -> [String: Bool] {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let mainQuartzHeight = CGDisplayBounds(CGMainDisplayID()).height
        let menuBarLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
        let records: [FullscreenFallbackVerdict.WindowRecord] = raw.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let quartzFrame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
            let appKitOrigin = CGPoint(
                x: quartzFrame.origin.x,
                y: mainQuartzHeight - quartzFrame.origin.y - quartzFrame.height
            )
            return FullscreenFallbackVerdict.WindowRecord(
                layer: layer,
                frame: CGRect(origin: appKitOrigin, size: quartzFrame.size)
            )
        }
        var byScreen: [String: Bool] = [:]
        for screen in NSScreen.screens {
            byScreen[screen.localizedName] = FullscreenFallbackVerdict.menuBarIsVisible(
                onScreenWithFrame: screen.frame,
                windows: records,
                menuBarLayer: menuBarLayer
            )
        }
        return byScreen
    }

    private func cleanupNotificationObservers() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
