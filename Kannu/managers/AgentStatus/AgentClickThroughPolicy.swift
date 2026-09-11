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

    /// Terminal agents without a Desktop app to fall back on: their terminal, or nothing.
    static func cli(host: Host) -> Action {
        switch host {
        case .app: return .terminalHost
        case .tmux: return .tmuxPane
        case .none: return .none
        }
    }
}
