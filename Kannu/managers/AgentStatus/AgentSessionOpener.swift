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
import ApplicationServices
import Darwin
import Foundation
import os

/// Click-through from an agent session row to the app that hosts it.
///
/// Tiered, degrading gracefully:
/// 1. Activate the right app. GUI IDE sessions (Cursor / VS Code / Antigravity) activate by
///    bundle id, or — when not running and the session knows its working directory — launch
///    the IDE *on that project*. Claude Code sessions walk the agent process's parent chain
///    to whatever GUI app hosts the terminal (Terminal, iTerm2, Ghostty, Warp, or an IDE's
///    integrated terminal) and activate that; the `com.anthropic.claude` bundle id is the
///    desktop chat app, NOT Claude Code, so activating it would focus the wrong thing.
/// 2. When Accessibility is already granted, additionally raise the specific window whose
///    title matches the session's project. Silently skipped when not granted — the row's
///    click still lands in the right app, and the existing Settings card is where users
///    grant AX if they want window-level precision. No prompts from here.
///
/// `target(for:)` is the clickability oracle: nil means the row offers no affordance at all
/// (no hand cursor, no tooltip, no dead click) — e.g. Codex hook-only sessions carry nothing
/// that locates a host, and a dead Claude pid must not pretend to be openable.
@MainActor
enum AgentSessionOpener {
    private static let log = os.Logger(subsystem: "com.kannu.app", category: "SessionOpener")

    struct OpenTarget {
        let appName: String
        fileprivate let kind: Kind

        fileprivate enum Kind {
            /// A GUI IDE identified by bundle id (running app when non-nil).
            case ide(running: NSRunningApplication?, appURL: URL?, source: AgentProviderIconSource)
            /// The GUI app hosting a CLI agent's terminal, found via parent-walk.
            case terminalHost(NSRunningApplication)
        }
    }

    /// What clicking this session would open, or nil when nothing can be located.
    static func target(for session: AgentSessionStatus) -> OpenTarget? {
        let source = AgentProviderIconSource(rawProvider: session.provider)
        switch source {
        case .cursor, .vscode, .antigravity:
            if let running = runningApplication(for: source) {
                return OpenTarget(appName: running.localizedName ?? session.providerLabel,
                                  kind: .ide(running: running, appURL: running.bundleURL, source: source))
            }
            if let appURL = installedApplicationURL(for: source) {
                let name = FileManager.default.displayName(atPath: appURL.path)
                return OpenTarget(appName: name, kind: .ide(running: nil, appURL: appURL, source: source))
            }
            return nil
        case .claude, .codex:
            // CLI agents: only a live pid gives us a host to activate. The provider bundle
            // ids intentionally aren't used — they point at unrelated desktop apps.
            guard let pid = session.hostPID, let host = terminalHostApplication(agentPID: pid) else {
                return nil
            }
            return OpenTarget(appName: host.localizedName ?? "Terminal", kind: .terminalHost(host))
        case .unknown:
            return nil
        }
    }

    /// Opens the session's host. Returns true when something was activated.
    @discardableResult
    static func open(_ session: AgentSessionStatus) -> Bool {
        guard let target = target(for: session) else { return false }

        switch target.kind {
        case .terminalHost(let host):
            log.notice("activating terminal host \(host.localizedName ?? "?", privacy: .public) (pid \(host.processIdentifier))")
            raiseMatchingWindow(in: host, session: session)
            host.activate()
            return true

        case .ide(let running, let appURL, _):
            if let running {
                log.notice("activating IDE \(running.localizedName ?? "?", privacy: .public)")
                raiseMatchingWindow(in: running, session: session)
                running.activate()
                return true
            }
            guard let appURL else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            if let cwd = session.cwd, FileManager.default.fileExists(atPath: cwd) {
                // Launch the IDE on the session's project rather than bare — lands the user
                // in the right workspace even from cold.
                log.notice("launching \(appURL.lastPathComponent, privacy: .public) on \(cwd, privacy: .public)")
                NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: appURL, configuration: configuration)
            } else {
                log.notice("launching \(appURL.lastPathComponent, privacy: .public)")
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            }
            return true
        }
    }

    // MARK: - App resolution

    private static func runningApplication(for source: AgentProviderIconSource) -> NSRunningApplication? {
        let ids = source.bundleIdentifiers
        return NSWorkspace.shared.runningApplications.first { app in
            guard let bid = app.bundleIdentifier else { return false }
            return ids.contains(bid)
        }
    }

    private static func installedApplicationURL(for source: AgentProviderIconSource) -> URL? {
        for bid in source.bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                return url
            }
        }
        for path in source.applicationPaths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: - Terminal host discovery (CLI agents)

    /// Walks the agent process's parent chain until it reaches a regular GUI application.
    /// Same sysctl idiom as `isClaudeProcessAlive`; `kp_eproc.e_ppid` is the parent pid.
    private static func terminalHostApplication(agentPID: Int) -> NSRunningApplication? {
        var pid = pid_t(agentPID)
        for _ in 0..<10 {
            guard pid > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: pid),
               app.activationPolicy == .regular {
                return app
            }
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
            let parent = info.kp_eproc.e_ppid
            guard parent != pid else { return nil }
            pid = parent
        }
        return nil
    }

    // MARK: - Window raise (Accessibility, best-effort)

    /// Raises the app window whose title matches the session's project, when Accessibility is
    /// already granted. Best-effort by design: failures and missing permission both just mean
    /// the app activates with whatever window it last had frontmost.
    private static func raiseMatchingWindow(in app: NSRunningApplication, session: AgentSessionStatus) {
        guard AXIsProcessTrusted() else { return }
        let needles: [String] = [
            session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
            session.displayProjectName
        ].compactMap { $0?.lowercased() }.filter { !$0.isEmpty }
        guard !needles.isEmpty else { return }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else { return }

        for window in windows {
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                  let title = (titleValue as? String)?.lowercased(), !title.isEmpty else { continue }
            if needles.contains(where: { title.contains($0) }) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                log.notice("raised window matching project (\(title, privacy: .private))")
                return
            }
        }
    }
}
