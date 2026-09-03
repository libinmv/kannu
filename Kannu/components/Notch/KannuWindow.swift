/*
 * Kannu (കണ്ണ്)
 * Copyright (C) 2024-2026 Kannu Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Kannu (കണ്ണ്)
 * See NOTICE for details.
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

import Cocoa

class KannuWindow: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )
        
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        
        collectionBehavior = [
            .fullScreenAuxiliary,
            .canJoinAllSpaces,
            .ignoresCycle,
            .stationary,
        ]
        
        isReleasedWhenClosed = false
        level = .mainMenu + 3
        hasShadow = false

        // The notch is drawn as an always-dark glass panel (black background, .white-opacity
        // fills expecting a dark backdrop), but nothing here pinned dark appearance — SwiftUI's
        // dynamic colors (.secondary, .primary) were resolving against whatever the *system*
        // appearance happened to be. In Light Mode that resolves near-black, rendered onto the
        // hardcoded-black background: invisible text. Force dark appearance explicitly so the
        // notch always renders correctly regardless of the system's light/dark setting.
        appearance = NSAppearance(named: .darkAqua)

        ScreenCaptureVisibilityManager.shared.register(self, scope: .entireInterface)
    }
    
    override var canBecomeKey: Bool {
        true
    }
    
    override var canBecomeMain: Bool {
        true
    }

}
