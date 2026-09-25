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
import Foundation
import os

/// Brings an agent's Terminal or iTerm2 tab to the front. Best-effort: the app is already active
/// when this runs, so a refused Automation prompt (-1743, remembered for the launch), a closed tab
/// or a script error leaves the user in the right app on whatever tab it had.
@MainActor
enum TerminalTabLocator {
    private static let log = os.Logger(subsystem: "com.kannu.app", category: "SessionOpener")
    private static var deniedBundleIdentifiers: Set<String> = []

    @discardableResult
    static func selectTab(bundleIdentifier: String, tty: String) async -> Bool {
        guard let family = TerminalTabMatcher.family(forBundleIdentifier: bundleIdentifier),
              !deniedBundleIdentifiers.contains(bundleIdentifier),
              let script = TerminalTabMatcher.selectScript(family: family, bundleIdentifier: bundleIdentifier, tty: tty)
        else { return false }
        do {
            let result = try await AppleScriptHelper.execute(script)
            return result?.booleanValue ?? false
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

/// Runs tmux to focus a pane and bring the terminal showing it forward. Arguments come from
/// `Tmux` (tested); no shell, the default socket, a short deadline, off the main actor.
enum TmuxLocator {
    private static let log = os.Logger(subsystem: "com.kannu.app", category: "SessionOpener")

    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/tmux"),
            URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
            URL(fileURLWithPath: "/usr/local/bin/tmux"),
            URL(fileURLWithPath: "/opt/local/bin/tmux"),
            home.appendingPathComponent(".nix-profile/bin/tmux")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 2) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                // Only what tmux needs to find its server — not the whole environment of a process
                // that holds API keys in it. No `TMUX`: inside a session tmux would target that one.
                let inherited = ProcessInfo.processInfo.environment
                var environment: [String: String] = [:]
                for key in ["PATH", "HOME", "USER", "SHELL", "TMPDIR", "TMUX_TMPDIR", "LANG", "LC_ALL"] {
                    if let value = inherited[key] { environment[key] = value }
                }
                process.environment = environment
                // Through the shared runner: this waited and *then* read, the >64 KB pipe deadlock,
                // rescued only by the timeout; and a tmux server the client spawned kept the pipe
                // open past the client's exit, which parked this thread and its continuation.
                let result = BoundedProcessRunner.run(process, timeout: timeout, stdoutCap: 1_000_000, stderrCap: 4_096, killGrace: 1, pollInterval: 0.02)
                continuation.resume(returning: result.status == 0 && !result.timedOut ? String(decoding: result.stdout, as: UTF8.self) : nil)
            }
        }
    }

    /// Selects the pane whose tty is `paneTTY`, then brings forward the terminal tab of the client
    /// showing it. Returns false when tmux, the pane or a client could not be found.
    @MainActor
    @discardableResult
    static func focus(paneTTY: String) async -> Bool {
        guard let tmux = executable(),
              let panesText = await run(tmux, Tmux.listPanesArguments),
              let pane = Tmux.pane(forTTY: paneTTY, in: Tmux.parsePanes(panesText)),
              let focus = Tmux.focusArguments(paneID: pane.paneID) else { return false }
        for arguments in focus { _ = await run(tmux, arguments) }
        guard let clientsText = await run(tmux, Tmux.listClientsArguments),
              let pick = Tmux.client(for: pane, in: Tmux.parseClients(clientsText)) else {
            log.notice("tmux pane selected; no attached client to bring forward")
            return true
        }
        if pick.needsSwitch, let switchArgs = Tmux.switchArguments(clientTTY: pick.client.tty, paneID: pane.paneID) {
            _ = await run(tmux, switchArgs)
        }
        guard let app = AgentSessionOpener.hostChain(agentPID: pick.client.pid).app else { return true }
        app.activate()
        if Defaults[.openAgentTerminalTab], let bundle = app.bundleIdentifier {
            await TerminalTabLocator.selectTab(bundleIdentifier: bundle, tty: pick.client.tty)
        }
        return true
    }
}
