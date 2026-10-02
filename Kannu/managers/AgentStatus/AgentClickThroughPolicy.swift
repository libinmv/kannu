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

/// What a click on a chat row does — the one place the rules live, so they can be tested.
///
/// The rule that broke: a live Claude session is **never** resumed. `claude://resume` spawns a
/// second `claude --resume` host for a transcript that already has one. It used to happen for a
/// live session whose host the parent walk could not reach (tmux, whose server's parent is
/// launchd; screen; ssh) and whose card was dim — `.inactive` was read as "not running". See
/// docs/REGRESSIONS.md entry 13.
enum AgentClickThroughPolicy {
    enum Host: Equatable {
        /// A GUI app owns the agent's terminal (Terminal, iTerm2, an IDE's terminal …).
        case app
        /// The agent runs in a tmux pane; its server has no GUI parent.
        case tmux
        case none
    }

    enum Action: Equatable {
        case desktopRoute
        case terminalHost
        case tmuxPane
        case resume
        case none
    }

    static func claude(hasDesktopRoute: Bool, liveProcess: Bool, host: Host,
                       displayState: AgentTrafficLightState, canResume: Bool) -> Action {
        if hasDesktopRoute { return .desktopRoute }
        if liveProcess { return cli(host: host) }
        return displayState == .inactive && canResume ? .resume : .none
    }

    /// Where "Open Chat" on a security finding would land.
    enum FindingDestination: Equatable {
        case desktopRoute
        /// `claude://resume`: Desktop imports the transcript as a new chat.
        case desktopImport
        case terminal
        case tmuxPane
        case runningApp
        /// The provider's app is not running and would be launched.
        case coldLaunch
        /// A cloud session's own page on claude.ai.
        case webPage
    }

    /// A finding goes back to its chat only where the chat already is. Never an import — it would
    /// re-open a transcript the finding may be about, possibly in a second host (entry 13) — and
    /// never a cold launch from a Settings row.
    static func findingMayOpen(_ destination: FindingDestination) -> Bool {
        switch destination {
        case .desktopRoute, .terminal, .tmuxPane, .runningApp, .webPage: return true
        case .desktopImport, .coldLaunch: return false
        }
    }

    /// Where a cloud card opens: its session's page on claude.ai, and nothing else whatever the
    /// relay sent — the id has already passed `ClaudeCloudRelay.sessionID(conversationID:)`.
    static func claudeCloudSessionURL(conversationID: String) -> URL? {
        ClaudeCloudRelay.sessionID(conversationID: conversationID).flatMap { URL(string: "https://claude.ai/code/" + $0) }
    }

    /// Checked again at the moment of opening: exactly `https://claude.ai/code/session_…`.
    static func isClaudeCloudSessionURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "claude.ai" && url.port == nil && url.user == nil
            && url.query == nil && url.fragment == nil
            && url.path.range(of: "^/code/session_[A-Za-z0-9]{1,64}$", options: .regularExpression) != nil
    }

    /// Terminal agents without a Desktop app to fall back on: their terminal, or nothing.
    static func cli(host: Host) -> Action {
        switch host {
        case .app: return .terminalHost
        case .tmux: return .tmuxPane
        case .none: return .none
        }
    }
}
