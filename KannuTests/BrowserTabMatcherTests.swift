//
//  BrowserTabMatcherTests.swift
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

/// Which browsers can be asked, what the scripts say, and which tab wins.
final class BrowserTabMatcherTests: XCTestCase {
    typealias M = BrowserTabMatcher
    private func tab(_ w: Int, _ t: Int, _ title: String) -> M.Tab { M.Tab(windowIndex: w, tabIndex: t, title: title) }

    func testFamilies() {
        XCTAssertEqual(M.family(forBundleIdentifier: "com.apple.Safari"), .safari)
        XCTAssertEqual(M.family(forBundleIdentifier: "com.google.Chrome"), .chromium)
        XCTAssertEqual(M.family(forBundleIdentifier: "com.brave.Browser"), .chromium)
        XCTAssertEqual(M.family(forBundleIdentifier: "com.microsoft.edgemac"), .chromium)
        XCTAssertNil(M.family(forBundleIdentifier: "org.mozilla.firefox"), "Firefox exposes no tabs")
        XCTAssertNil(M.family(forBundleIdentifier: "company.thebrowser.Browser"), "Arc speaks another dictionary")
        XCTAssertNil(M.family(forBundleIdentifier: "com.spotify.client"))
    }

    func testScriptsUseEachFamilysOwnVocabulary() {
        let safari = M.listingScript(family: .safari, bundleIdentifier: "com.apple.Safari")
        XCTAssertTrue(safari.contains("tell application id \"com.apple.Safari\""))
        XCTAssertTrue(safari.contains("(name of t)"))
        let chrome = M.listingScript(family: .chromium, bundleIdentifier: "com.google.Chrome")
        XCTAssertTrue(chrome.contains("(title of t)"))
        let pick = tab(2, 3, "x")
        XCTAssertTrue(M.selectScript(family: .safari, bundleIdentifier: "com.apple.Safari", tab: pick)
            .contains("set current tab of window 2 to tab 3 of window 2"))
        let chromeSelect = M.selectScript(family: .chromium, bundleIdentifier: "com.google.Chrome", tab: pick)
        XCTAssertTrue(chromeSelect.contains("set active tab index of window 2 to 3"))
        XCTAssertTrue(chromeSelect.contains("set index of window 2 to 1"))
        XCTAssertTrue(chromeSelect.hasSuffix("activate\nend tell"))
    }

    func testListingParsesOneTabPerLine() {
        let text = "1\t1\tInbox - Mail\n1\t2\t(3) Song Name - YouTube\n2\t1\tTitle with\ttab\nbad line\n"
        let tabs = M.parseListing(text)
        XCTAssertEqual(tabs, [tab(1, 1, "Inbox - Mail"), tab(1, 2, "(3) Song Name - YouTube"), tab(2, 1, "Title with\ttab")])
    }

    func testNormalizeDropsSiteDecorations() {
        XCTAssertEqual(M.normalize("(12) Blinding Lights - YouTube"), "blinding lights")
        XCTAssertEqual(M.normalize("Café del Mar • Energy 52 | Spotify"), "cafe del mar energy 52")
        XCTAssertEqual(M.normalize("  Some   Title - YouTube Music"), "some title")
    }

    func testTheTabCarryingTheTitleWins() {
        let tabs = [tab(1, 1, "Inbox - Mail"), tab(1, 2, "(2) Blinding Lights (Official Video) - YouTube"), tab(2, 1, "Hacker News")]
        XCTAssertEqual(M.bestMatch(tabs: tabs, title: "Blinding Lights", artist: "The Weeknd"), tabs[1])
        XCTAssertEqual(M.bestMatch(tabs: tabs, title: "BLINDING LIGHTS", artist: nil), tabs[1], "case-insensitive")
    }

    func testMostWordsMatchWhenTheSiteRewordsTheTitle() {
        // The tab shows "Artist - Title (Lyrics)" while Now Playing carries "Title (Lyric Video)".
        let tabs = [tab(1, 1, "The Weeknd - Blinding Lights (Lyrics) - YouTube")]
        XCTAssertEqual(M.bestMatch(tabs: tabs, title: "Blinding Lights (Lyric Video)", artist: "The Weeknd"), tabs[0])
    }

    func testArtistBreaksTiesAndFrontmostWindowWinsOtherwise() {
        let sameWindow = [tab(1, 1, "Hello - YouTube"), tab(1, 3, "Hello by Adele - YouTube")]
        XCTAssertEqual(M.bestMatch(tabs: sameWindow, title: "Hello", artist: "Adele"), sameWindow[1], "artist beats the lower tab index")
        XCTAssertEqual(M.bestMatch(tabs: sameWindow, title: "Hello", artist: nil), sameWindow[0], "no artist: the lower tab index")
        let twoWindows = [tab(2, 1, "Hello - YouTube"), tab(1, 5, "Hello - YouTube")]
        XCTAssertEqual(M.bestMatch(tabs: twoWindows, title: "Hello", artist: nil), twoWindows[1], "the frontmost window wins")
    }

    func testNothingConvincingMeansNoTab() {
        let tabs = [tab(1, 1, "Inbox - Mail"), tab(1, 2, "Kannu — GitHub")]
        XCTAssertNil(M.bestMatch(tabs: tabs, title: "Blinding Lights", artist: "The Weeknd"))
        XCTAssertNil(M.bestMatch(tabs: tabs, title: "ab", artist: nil), "too short to trust")
        XCTAssertNil(M.bestMatch(tabs: [], title: "Blinding Lights", artist: nil))
    }
}
