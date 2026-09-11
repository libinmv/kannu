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
import Defaults
import Foundation
import os

/// Click-through from an agent session row to the app that hosts it.
///
/// Tiered, degrading gracefully:
/// 1. Claude chats Desktop knows — hosted in its Code tab, or imported earlier — open through
///    `claude://claude.ai/epitaxy/<local id>`, Desktop's in-app route for that exact chat; it
///    navigates and creates nothing (verified against Desktop 1.46388.4: `setFocusedSession`
///    in its log, no new host). Live and stopped rows alike; the id comes from Desktop's
///    on-disk index via `ClaudeDesktopSessionIndex`.
/// 2. Stopped Claude chats Desktop has never seen open through `claude://resume?session=<cli
///    uuid>`, which imports the on-disk transcript and shows it where it left off. NEVER for a
///    live session: Desktop's id diverges from the CLI id after a resume, so `resume` imports a
///    second `claude --resume` host for a transcript that already has one (verified against
///    Desktop 2.1.222 and 1.46388.4).
/// 3. Otherwise activate the right app. GUI IDE sessions (Cursor / VS Code / Antigravity)
///    activate by bundle id, or — when not running and the session knows its working
///    directory — launch the IDE *on that project*. Claude Code sessions running in a real
///    terminal walk the agent process's parent chain to whatever GUI app hosts it (Terminal,
///    iTerm2, Ghostty, Warp, or an IDE's integrated terminal) and activate that. A
///    Desktop-hosted session the index has not resolved yet lands here too — activation only.
/// 4. When Accessibility is already granted, additionally raise the specific window whose
///    title matches the session's project. Silently skipped when not granted — the row's
///    click still lands in the right app, and the Agents settings callout is where users
///    grant AX if they want window-level precision. No prompts from here.
///
/// `target(for:)` is the clickability oracle: nil means the row offers no affordance at all
/// (no hand cursor, no tooltip, no dead click) — e.g. Codex hook-only sessions carry nothing
/// that locates a host, and a dead Codex pid must not pretend to be openable.
@MainActor
enum AgentSessionOpener {
    private static let log = os.Logger(subsystem: "com.kannu.app", category: "SessionOpener")

    struct OpenTarget {
        let appName: String
        fileprivate let kind: Kind

        fileprivate enum Kind {
            /// A GUI IDE identified by bundle id (running app when non-nil).
            case ide(running: NSRunningApplication?, appURL: URL?, source: AgentProviderIconSource)
            /// The GUI app hosting a CLI agent's terminal, found via parent-walk; `tty` lets
            /// Terminal and iTerm2 bring the exact tab forward.
            case terminalHost(NSRunningApplication, tty: String?)
            /// A tmux pane (its server has no GUI parent): tmux selects it, then the terminal
            /// showing that session comes forward.
            case tmuxPane(tty: String)
            /// A specific Claude Code chat, via a Claude Desktop deep link: the session route
            /// (focus) or `resume` (import).
            case claudeDeepLink(url: URL)
        }

        /// Tooltip text: a deep link lands on the chat itself, the others on its app.
        var actionLabel: String {
            switch kind {
            case .claudeDeepLink: return String(localized: "Open chat in \(appName)")
            case .tmuxPane: return String(localized: "Open in tmux")
            default: return String(localized: "Open in \(appName)")
            }
        }
    }

    /// What clicking this session would open, or nil when nothing can be located.
    static func target(for session: AgentSessionStatus) -> OpenTarget? {
        let source = AgentProviderIconSource(rawProvider: session.provider)
        switch source {
        case .cursor, .vscode, .antigravity, .warp, .claudeDesktop:
            // Warp and Claude Desktop are GUI apps too: activate when running, launch when not.
            if let running = runningApplication(for: source) {
                return OpenTarget(appName: running.localizedName ?? session.providerLabel,
                                  kind: .ide(running: running, appURL: running.bundleURL, source: source))
            }
            if let appURL = installedApplicationURL(for: source) {
                let name = FileManager.default.displayName(atPath: appURL.path)
                return OpenTarget(appName: name, kind: .ide(running: nil, appURL: appURL, source: source))
            }
            return nil
        case .claude:
            // The decision lives in `AgentClickThroughPolicy` (tested). A Desktop-known chat opens
            // on its session route; a live one goes to its terminal or tmux pane — NEVER `resume`:
            // it spawns a second `claude --resume` host for a transcript that already has one
            // (verified against Desktop 2.1.222 and 1.46388.4; REGRESSIONS entry 13). Only a chat
            // whose process is gone may be imported, and only once it is dim.
            let desktopURL = session.desktopSessionID.flatMap { ClaudeDesktopSessionIndex.focusDeepLink(desktopSessionID: $0) }
            let chain = session.hostPID.map { hostChain(agentPID: $0) }
            let resumeURL = claudeResumeDeepLink(conversationID: session.conversationID)
            let action = AgentClickThroughPolicy.claude(
                hasDesktopRoute: desktopURL != nil && claudeDesktopAppURL != nil,
                liveProcess: session.hostPID != nil,
                host: chain?.host ?? .none,
                displayState: session.displayState,
                canResume: resumeURL != nil && claudeDesktopAppURL != nil
            )
            switch action {
            case .desktopRoute:
                guard let desktopURL, let handler = claudeDesktopAppURL else { return nil }
                return OpenTarget(appName: FileManager.default.displayName(atPath: handler.path), kind: .claudeDeepLink(url: desktopURL))
            case .resume:
                guard let resumeURL, let handler = claudeDesktopAppURL else { return nil }
                return OpenTarget(appName: FileManager.default.displayName(atPath: handler.path), kind: .claudeDeepLink(url: resumeURL))
            case .terminalHost, .tmuxPane:
                return chain.flatMap(terminalTarget(for:))
            case .none:
                return nil
            }
        case .codex:
            // Codex: only a live pid gives us a host to activate. The provider bundle id
            // intentionally isn't used — it points at an unrelated desktop app.
            guard let pid = session.hostPID else { return nil }
            return terminalTarget(for: hostChain(agentPID: pid))
        case .unknown:
            return nil
        }
    }

    /// Opens the session's host. Returns true when something was activated.
    @discardableResult
    static func open(_ session: AgentSessionStatus) -> Bool {
        guard let target = target(for: session) else { return false }

        switch target.kind {
        case .claudeDeepLink(let url):
            log.notice("opening chat via Claude Desktop deep link (\(url.absoluteString, privacy: .private))")
            NSWorkspace.shared.open(url)
            // Desktop's handler focuses the window itself; activating too covers a handler
            // disabled by policy, which drops the link silently.
            NSRunningApplication.runningApplications(withBundleIdentifier: claudeDesktopBundleID).first?.activate()
            return true

        case .terminalHost(let host, let tty):
            log.notice("activating terminal host \(host.localizedName ?? "?", privacy: .public) (pid \(host.processIdentifier))")
            host.activate()
            if host.bundleIdentifier == claudeDesktopBundleID {
                // Desktop-hosted but unresolved in the index: its window titles never carry
                // the project, so the raise would only ever miss.
                log.notice("Desktop-hosted session not in the index yet; activating only")
            } else if let tty, Defaults[.openAgentTerminalTab],
                      let bundle = host.bundleIdentifier, TerminalTabMatcher.family(forBundleIdentifier: bundle) != nil {
                Task { @MainActor in
                    if await !TerminalTabLocator.selectTab(bundleIdentifier: bundle, tty: tty) {
                        raiseMatchingWindow(in: host, session: session)
                    }
                }
            } else {
                raiseMatchingWindow(in: host, session: session)
            }
            return true

        case .tmuxPane(let tty):
            log.notice("focusing tmux pane")
            Task { @MainActor in await TmuxLocator.focus(paneTTY: tty) }
            return true

        case .ide(let running, let appURL, let source):
            if let running {
                log.notice("activating IDE \(running.localizedName ?? "?", privacy: .public)")
                raiseMatchingWindow(in: running, session: session)
                running.activate()
                return true
            }
            guard let appURL else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            // Claude Desktop is not a project editor: handing it a folder would import it as
            // a new chat, not focus the existing one. Launch it bare.
            if source != .claudeDesktop, let cwd = session.cwd, FileManager.default.fileExists(atPath: cwd) {
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

    // MARK: - Claude Desktop deep link

    private static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    /// The app registered for claude:// links — kept only when it is actually Claude
    /// Desktop, so a stray handler can't capture stopped-session clicks. Resolved once;
    /// installing Claude Desktop mid-run is picked up on the next launch.
    private static let claudeDesktopAppURL: URL? = {
        guard let probe = URL(string: "claude://resume"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe),
              Bundle(url: handler)?.bundleIdentifier == claudeDesktopBundleID else { return nil }
        return handler
    }()

    /// `claude://resume?session=<uuid>` — Claude Desktop imports the CLI session's on-disk
    /// transcript and navigates to it. Strictly UUID-validated before it goes anywhere near
    /// a URL: a conversation id is data from disk, not something to interpolate blindly.
    static func claudeResumeDeepLink(conversationID: String) -> URL? {
        guard UUID(uuidString: conversationID) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "resume"
        components.queryItems = [URLQueryItem(name: "session", value: conversationID.lowercased())]
        return components.url
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

    struct HostChain {
        /// The first regular GUI app up the parent chain.
        let app: NSRunningApplication?
        /// The chain passed through a tmux server before reaching launchd.
        let passesThroughTmux: Bool
        /// The agent's controlling terminal, e.g. `/dev/ttys003`.
        let tty: String?

        var host: AgentClickThroughPolicy.Host {
            if app != nil { return .app }
            return passesThroughTmux && tty != nil ? .tmux : .none
        }
    }

    /// Walks the agent process's parent chain until it reaches a regular GUI application, noting
    /// a tmux server on the way and the agent's own terminal. Same sysctl idiom as
    /// `isClaudeProcessAlive`; `kp_eproc.e_ppid` is the parent pid. No process is spawned: this
    /// runs while a row renders.
    static func hostChain(agentPID: Int) -> HostChain {
        let tty = controllingTTY(pid: agentPID)
        var pid = pid_t(agentPID)
        var passesThroughTmux = false
        for _ in 0..<12 {
            guard pid > 1 else { break }
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                return HostChain(app: app, passesThroughTmux: passesThroughTmux, tty: tty)
            }
            guard let info = processInfo(pid: pid) else { break }
            if processName(info) == "tmux" { passesThroughTmux = true }
            let parent = info.kp_eproc.e_ppid
            guard parent != pid else { break }
            pid = parent
        }
        return HostChain(app: nil, passesThroughTmux: passesThroughTmux, tty: tty)
    }

    /// Kept for callers that only need the app.
    static func terminalHostApplication(agentPID: Int) -> NSRunningApplication? {
        hostChain(agentPID: agentPID).app
    }

    private static func terminalTarget(for chain: HostChain) -> OpenTarget? {
        switch chain.host {
        case .app:
            guard let app = chain.app else { return nil }
            return OpenTarget(appName: app.localizedName ?? "Terminal", kind: .terminalHost(app, tty: chain.tty))
        case .tmux:
            guard let tty = chain.tty else { return nil }
            return OpenTarget(appName: "tmux", kind: .tmuxPane(tty: tty))
        case .none:
            return nil
        }
    }

    private static func processInfo(pid: pid_t) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    private static func processName(_ info: kinfo_proc) -> String {
        var comm = info.kp_proc.p_comm
        return withUnsafeBytes(of: &comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// `/dev/ttys003` for a process with a controlling terminal; nil otherwise (Desktop-hosted
    /// sessions have none).
    static func controllingTTY(pid: Int) -> String? {
        guard let info = processInfo(pid: pid_t(pid)) else { return nil }
        let device = info.kp_eproc.e_tdev
        guard device != -1 else { return nil }
        var buffer = [CChar](repeating: 0, count: 64)
        guard devname_r(device, S_IFCHR, &buffer, Int32(buffer.count)) != nil else { return nil }
        let name = String(cString: buffer)
        let path = "/dev/" + name
        return TerminalLocator.isValidTTY(path) ? path : nil
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
