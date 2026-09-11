//
//  TerminalTabMatcherTests.swift
//  KannuTests
//
//  Copyright (C) 2026 Kannu contributors
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import XCTest

/// Which terminals can be asked, what the scripts say, and how tmux output is read. Every value
/// that reaches a script or a tmux argument is validated first.
final class TerminalTabMatcherTests: XCTestCase {
    func testFamilies() {
        XCTAssertEqual(TerminalTabMatcher.family(forBundleIdentifier: "com.apple.Terminal"), .terminal)
        XCTAssertEqual(TerminalTabMatcher.family(forBundleIdentifier: "com.googlecode.iterm2"), .iterm2)
        XCTAssertNil(TerminalTabMatcher.family(forBundleIdentifier: "dev.warp.Warp-Stable"))
        XCTAssertNil(TerminalTabMatcher.family(forBundleIdentifier: "com.mitchellh.ghostty"))
        XCTAssertNil(TerminalTabMatcher.family(forBundleIdentifier: nil))
    }

    func testLocatorRejectsInjectedTTYs() {
        XCTAssertNotNil(TerminalLocator(tty: "/dev/ttys003"))
        XCTAssertNil(TerminalLocator(tty: "/dev/ttys003\"; do shell script \"rm -rf ~\""))
        XCTAssertNil(TerminalLocator(tty: "/dev/../etc/passwd"))
        XCTAssertNil(TerminalLocator(tty: ""))
        XCTAssertNil(TerminalLocator(tty: "/dev/tty"))
        XCTAssertNil(TerminalLocator(tty: "/dev/ttys003", sessionLeaderPID: 1), "launchd is nobody's session leader here")
        XCTAssertNil(TerminalTabMatcher.selectScript(family: .terminal, bundleIdentifier: "com.apple.Terminal", tty: "/dev/ttys1\" & x"))
    }

    func testScriptsUseEachAppsVocabulary() throws {
        let terminal = try XCTUnwrap(TerminalTabMatcher.selectScript(family: .terminal, bundleIdentifier: "com.apple.Terminal", tty: "/dev/ttys004"))
        XCTAssertTrue(terminal.contains("if tty of t is \"/dev/ttys004\" then"))
        XCTAssertTrue(terminal.contains("set selected of t to true"))
        XCTAssertTrue(terminal.contains("set index of w to 1"))
        let iterm = try XCTUnwrap(TerminalTabMatcher.selectScript(family: .iterm2, bundleIdentifier: "com.googlecode.iterm2", tty: "/dev/ttys004"))
        XCTAssertTrue(iterm.contains("repeat with s in sessions of t"))
        XCTAssertTrue(iterm.contains("tell s to select"))
    }

    func testTmuxPaneListingParsesTabSeparatedLines() {
        let text = "/dev/ttys010\t%3\tmy project\n/dev/ttys011\t%4\twork\nbroken line\n/dev/ttys012\tbad\tx\n"
        XCTAssertEqual(Tmux.parsePanes(text), [
            Tmux.Pane(tty: "/dev/ttys010", paneID: "%3", session: "my project"),
            Tmux.Pane(tty: "/dev/ttys011", paneID: "%4", session: "work")
        ])
    }

    func testTmuxPaneForTTYAndNoMatch() {
        let panes = Tmux.parsePanes("/dev/ttys010\t%3\twork\n")
        XCTAssertEqual(Tmux.pane(forTTY: "/dev/ttys010", in: panes)?.paneID, "%3")
        XCTAssertNil(Tmux.pane(forTTY: "/dev/ttys099", in: panes))
    }

    func testTmuxPaneIDsAreValidated() {
        XCTAssertEqual(Tmux.focusArguments(paneID: "%12"), [["select-window", "-t", "%12"], ["select-pane", "-t", "%12"]])
        XCTAssertNil(Tmux.focusArguments(paneID: "%"))
        XCTAssertNil(Tmux.focusArguments(paneID: "%1;kill-server"))
        XCTAssertNil(Tmux.focusArguments(paneID: "work:1"))
        XCTAssertEqual(Tmux.switchArguments(clientTTY: "/dev/ttys001", paneID: "%3"), ["switch-client", "-c", "/dev/ttys001", "-t", "%3"])
        XCTAssertNil(Tmux.switchArguments(clientTTY: "/dev/ttys001; x", paneID: "%3"))
    }

    func testTmuxClientPrefersTheSessionThenMostRecent() {
        let clients = Tmux.parseClients("400\t/dev/ttys001\twork\t100\n401\t/dev/ttys002\twork\t300\n402\t/dev/ttys003\tother\t900\n")
        XCTAssertEqual(clients.count, 3)
        let pane = Tmux.Pane(tty: "/dev/ttys010", paneID: "%3", session: "work")
        let attached = Tmux.client(for: pane, in: clients)
        XCTAssertEqual(attached?.client.pid, 401, "the most recently active client already on that session")
        XCTAssertEqual(attached?.needsSwitch, false)
        let elsewhere = Tmux.client(for: Tmux.Pane(tty: "/dev/ttys011", paneID: "%9", session: "detached"), in: clients)
        XCTAssertEqual(elsewhere?.client.pid, 402)
        XCTAssertEqual(elsewhere?.needsSwitch, true)
        XCTAssertNil(Tmux.client(for: pane, in: []))
    }
}
