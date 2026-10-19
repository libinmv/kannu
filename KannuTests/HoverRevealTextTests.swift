//
//  HoverRevealTextTests.swift
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

import AppKit
import SwiftUI
import XCTest

/// The hover slide, run for real: hosted in a window and driven active, a clipped text must move,
/// and a text that fits — or one not hovered — must stay still.
///
/// David: "the animation to reveal the clipped text on hover is not working". v20 measured its two
/// sizes through preference keys, and in this view their `onPreferenceChange` reported zero and
/// never the real sizes (seen in a harness), so nothing ever counted as clipped. The sizes are
/// written straight to state now; these tests render the view and compare the pixels.
@MainActor
final class HoverRevealTextTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows = []
        super.tearDown()
    }

    private func host<Content: View>(_ content: Content, size: CGSize) -> NSView {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // The test keeps it; closing must not free it as well.
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: content
            .foregroundStyle(.white)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.black))
        window.contentView = hosting
        window.orderFrontRegardless()
        windows.append(window)
        return hosting
    }

    private func pixels(_ view: NSView) -> Data {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return Data() }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Past the pause and partway along the travel, the clipped line has moved.
    func testAClippedLineSlidesWhileActive() {
        let view = host(HoverRevealText("Health Check Migration and more words", font: .system(size: 11, weight: .medium),
                                        isActive: true)
                            .frame(width: 70, alignment: .leading),
                        size: CGSize(width: 90, height: 20))
        wait(0.2)
        let atRest = pixels(view)
        XCTAssertFalse(atRest.isEmpty, "nothing rendered")
        wait(HoverRevealMotion.startDelay + 1)
        XCTAssertNotEqual(pixels(view), atRest, "the clipped line never moved")
    }

    /// A two-line title longer than two lines slides up.
    func testAClippedTitleSlidesUpWhileActive() {
        let view = host(HoverRevealText("A long card title that runs over two lines and then some more words to make three",
                                        font: .system(size: 13, weight: .semibold), lines: 2, isActive: true)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 140, alignment: .leading),
                        size: CGSize(width: 150, height: 40))
        wait(0.2)
        let atRest = pixels(view)
        wait(HoverRevealMotion.startDelay + 1)
        XCTAssertNotEqual(pixels(view), atRest, "the clipped title never moved")
    }

    /// Nothing moves when the text fits, or when nobody hovers it.
    func testTextThatFitsOrIsNotHoveredStaysStill() {
        let fits = host(HoverRevealText("Short", font: .system(size: 11, weight: .medium), isActive: true)
                            .frame(width: 70, alignment: .leading),
                        size: CGSize(width: 90, height: 20))
        let idle = host(HoverRevealText("Health Check Migration and more words", font: .system(size: 11, weight: .medium),
                                        isActive: false)
                            .frame(width: 70, alignment: .leading),
                        size: CGSize(width: 90, height: 20))
        wait(0.2)
        let fitsAtRest = pixels(fits)
        let idleAtRest = pixels(idle)
        wait(HoverRevealMotion.startDelay + 1)
        XCTAssertEqual(pixels(fits), fitsAtRest, "text that fits moved")
        XCTAssertEqual(pixels(idle), idleAtRest, "a clipped text moved without a hover")
    }

    /// The sizes never travel through preference keys again: here they arrived as zero.
    func testTheSizesAreNotMeasuredThroughPreferences() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Kannu/components/Notch/HoverRevealText.swift"), encoding: .utf8)
        let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        XCTAssertFalse(code.contains("onPreferenceChange"), "the sizes reported zero through onPreferenceChange in this view")
        XCTAssertTrue(code.contains(".background(SizeReader(size: $frameSize))"))
        XCTAssertTrue(code.contains(".background(SizeReader(size: $fullSize))"))
        XCTAssertTrue(code.contains(".task(id: trigger)"), "sizes arriving after the hover must still start the slide")
    }
}
