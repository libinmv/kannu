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

/// Where a terminal agent lives: its controlling terminal (`/dev/ttys003`) and, when known, the
/// session leader that owns it — so a reused tty number in a new tab is never mistaken for it.
/// Validated before it goes anywhere near an AppleScript or a tmux argument.
struct TerminalLocator: Codable, Equatable {
    let tty: String
    let sessionLeaderPID: Int?

    init?(tty: String, sessionLeaderPID: Int? = nil) {
        guard Self.isValidTTY(tty) else { return nil }
        if let pid = sessionLeaderPID, pid <= 1 { return nil }
        self.tty = tty
        self.sessionLeaderPID = sessionLeaderPID
    }

    static func isValidTTY(_ tty: String) -> Bool {
        guard tty.hasPrefix("/dev/tty") else { return false }
        let rest = tty.dropFirst("/dev/tty".count)
        return (1...12).contains(rest.count) && rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

/// The two terminals that let a script pick a tab by its terminal: Terminal.app (tabs have a
/// `tty`) and iTerm2 (sessions have a `tty`). Everything else stays at "bring the app forward".
enum TerminalTabMatcher {
    enum Family: Equatable {
        case terminal
        case iterm2
    }

    static func family(forBundleIdentifier bundleIdentifier: String?) -> Family? {
        switch bundleIdentifier {
        case "com.apple.Terminal": return .terminal
        case "com.googlecode.iterm2": return .iterm2
        default: return nil
        }
    }

    /// Selects the tab (and, for iTerm2, the split session) whose terminal is `tty`, raises its
    /// window, activates the app. Nil for a tty that does not validate.
    static func selectScript(family: Family, bundleIdentifier: String, tty: String) -> String? {
        guard TerminalLocator.isValidTTY(tty) else { return nil }
        switch family {
        case .terminal:
            return """
            tell application id "\(bundleIdentifier)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
                return false
            end tell
            """
        case .iterm2:
            return """
            tell application id "\(bundleIdentifier)"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                tell t to select
                                tell s to select
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
                return false
            end tell
            """
        }
    }
}

/// tmux, as data: the arguments Kannu runs and how their output is read. A pane is found by its
/// tty; the window and pane are selected; the client showing that session is the terminal tab to
/// bring forward (switching a client to the session when none shows it).
enum Tmux {
    static let listPanesArguments = ["list-panes", "-a", "-F", "#{pane_tty}\t#{pane_id}\t#{session_name}"]
    static let listClientsArguments = ["list-clients", "-F", "#{client_pid}\t#{client_tty}\t#{client_session}\t#{client_activity}"]

    struct Pane: Equatable {
        let tty: String
        let paneID: String
        let session: String
    }

    struct Client: Equatable {
        let pid: Int
        let tty: String
        let session: String
        let activity: Int
    }

    static func parsePanes(_ text: String) -> [Pane] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, TerminalLocator.isValidTTY(parts[0]), isValidPaneID(parts[1]) else { return nil }
            return Pane(tty: parts[0], paneID: parts[1], session: parts[2])
        }
    }

    static func parseClients(_ text: String) -> [Client] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4, let pid = Int(parts[0]), pid > 1, TerminalLocator.isValidTTY(parts[1]) else { return nil }
            let session = parts[2...(parts.count - 2)].joined(separator: "\t")
            return Client(pid: pid, tty: parts[1], session: session, activity: Int(parts[parts.count - 1]) ?? 0)
        }
    }

    static func pane(forTTY tty: String, in panes: [Pane]) -> Pane? {
        panes.first { $0.tty == tty }
    }

    /// `%` followed by digits — nothing else ever reaches a tmux argument.
    static func isValidPaneID(_ id: String) -> Bool {
        id.count >= 2 && id.hasPrefix("%") && id.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func focusArguments(paneID: String) -> [[String]]? {
        guard isValidPaneID(paneID) else { return nil }
        return [["select-window", "-t", paneID], ["select-pane", "-t", paneID]]
    }

    /// The client already showing the pane's session (most recently active first); otherwise the
    /// most recently active client, which must be switched to that session.
    static func client(for pane: Pane, in clients: [Client]) -> (client: Client, needsSwitch: Bool)? {
        if let attached = clients.filter({ $0.session == pane.session }).max(by: { $0.activity < $1.activity }) {
            return (attached, false)
        }
        guard let recent = clients.max(by: { $0.activity < $1.activity }) else { return nil }
        return (recent, true)
    }

    static func switchArguments(clientTTY: String, paneID: String) -> [String]? {
        guard TerminalLocator.isValidTTY(clientTTY), isValidPaneID(paneID) else { return nil }
        return ["switch-client", "-c", clientTTY, "-t", paneID]
    }
}
