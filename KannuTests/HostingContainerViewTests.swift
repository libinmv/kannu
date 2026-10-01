//
//  HostingContainerViewTests.swift
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

/// Every Kannu panel's content sits in a `HostingContainerView` (docs/REGRESSIONS.md entries 17
/// and 19). The container's contract is "holds a hosting view full-size". It broke silently for
/// the clipboard panel: installed while the panel was 0×0, then sized, autoresizing added the
/// whole delta to the child and left a 640×800 hosting view in a 320×400 window — on screen,
/// correct level, correct space, and showing the wrong part of its content.
final class HostingContainerViewTests: XCTestCase {
    private let size = CGSize(width: 320, height: 400)

    func testAChildAddedWhileTheContainerIsEmptyStillFillsItAfterItGrows() {
        let container = HostingContainerView(frame: .zero)
        let child = NSView(frame: .zero)
        child.autoresizingMask = [.width, .height]
        container.addSubview(child)
        child.setFrameSize(size)            // what ClipboardPanel did before sizing its window
        container.setFrameSize(size)
        XCTAssertEqual(child.frame, container.bounds, "grown from 0×0, the child must fill the container, not double")
    }

    func testTheChildFollowsEveryLaterResize() {
        let container = HostingContainerView(frame: NSRect(origin: .zero, size: size))
        let child = NSView(frame: container.bounds)
        container.addSubview(child)
        for next in [CGSize(width: 360, height: 420), CGSize(width: 200, height: 90), size] {
            container.setFrameSize(next)
            XCTAssertEqual(child.frame, container.bounds, "after resizing to \(next)")
        }
    }

    func testSetHostedContentOnAZeroFramePanelThenSizedFillsTheContent() {
        // The exact ClipboardPanel sequence before this fix, through the real helper.
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.styleMask.insert(.fullSizeContentView)
        let hosting = NSHostingView(rootView: Text("clipboard"))
        panel.setHostedContent(hosting)
        hosting.setFrameSize(size)
        panel.setContentSize(size)
        XCTAssertEqual(hosting.frame, panel.contentView?.bounds, "hosting view must equal the content bounds — was 640×800 in 320×400")
        XCTAssertTrue(panel.hostedContentView === hosting)
    }
}
