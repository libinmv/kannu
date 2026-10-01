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

import AppKit

/// Small Spaces API wrapper.
public final class CGSSpace {
    private let identifier: CGSSpaceID
    private let createdByInit: Bool

    public var windows: Set<NSWindow> = [] {
        didSet {
            let remove = oldValue.subtracting(self.windows)
            let add = self.windows.subtracting(oldValue)

            CGSRemoveWindowsFromSpaces(_CGSDefaultConnection(),
                                       remove.map { $0.windowNumber } as NSArray,
                                       [self.identifier])
            CGSAddWindowsToSpaces(_CGSDefaultConnection(),
                                  add.map { $0.windowNumber } as NSArray,
                                  [self.identifier])
        }
    }

    /// Initialized `CGSSpace`s *MUST* be de-initialized upon app exit!
    public init(level: Int = 0) {
        let flag = 0x1 // this value MUST be 1, otherwise, Finder decides to draw desktop icons
        self.identifier = CGSSpaceCreate(_CGSDefaultConnection(), flag, nil)
        CGSSpaceSetAbsoluteLevel(_CGSDefaultConnection(), self.identifier, level)
        CGSShowSpaces(_CGSDefaultConnection(), [self.identifier])
        self.createdByInit = true // Mark as created by the first init
    }

    public init(id: UInt64) {
        self.identifier = id
        CGSShowSpaces(_CGSDefaultConnection(), [self.identifier])
        self.createdByInit = false // Mark as created externally
    }

    deinit {
        CGSHideSpaces(_CGSDefaultConnection(), [self.identifier])
        // Only call CGSSpaceDestroy if the space was created by the first init
        if createdByInit {
            CGSSpaceDestroy(_CGSDefaultConnection(), self.identifier)
        }
    }
}

public extension CGSSpace {
    /// Puts windows back on every managed space (every desktop and fullscreen space, all displays).
    ///
    /// For all-spaces panels that macOS has reset to a couple of spaces around a sleep or a lock:
    /// see `ClosedNotchVisibility.shouldRejoinSpaces`. Returns how many spaces were targeted, so the
    /// caller can log it.
    @discardableResult
    static func rejoinAllManagedSpaces(_ windows: [NSWindow]) -> Int {
        guard !windows.isEmpty else { return 0 }
        let displays = (CGSCopyManagedDisplaySpaces(_CGSDefaultConnection())?.takeRetainedValue() as? [[String: Any]]) ?? []
        let spaceIDs: [NSNumber] = displays.flatMap { display in
            ((display["Spaces"] as? [[String: Any]]) ?? []).compactMap { $0["id64"] as? NSNumber }
        }
        guard !spaceIDs.isEmpty else { return 0 }
        CGSAddWindowsToSpaces(_CGSDefaultConnection(), windows.map(\.windowNumber) as NSArray, spaceIDs as NSArray)
        return spaceIDs.count
    }
}

#if DEBUG
public extension CGSSpace {
    /// DEBUG only: takes windows off the currently active space, reproducing what a sleep or lock
    /// can do to an all-spaces panel, so the repair can be exercised end to end on the real notch.
    static func debugStrandFromActiveSpace(_ windows: [NSWindow]) {
        CGSRemoveWindowsFromSpaces(_CGSDefaultConnection(), windows.map(\.windowNumber) as NSArray,
                                   [CGSGetActiveSpace(_CGSDefaultConnection())] as NSArray)
    }
}
@_silgen_name("CGSGetActiveSpace")
fileprivate func CGSGetActiveSpace(_ cid: CGSConnectionID) -> UInt64
#endif

// CGSSpace stuff:
fileprivate typealias CGSConnectionID = UInt
fileprivate typealias CGSSpaceID = UInt64
@_silgen_name("_CGSDefaultConnection")
fileprivate func _CGSDefaultConnection() -> CGSConnectionID
@_silgen_name("CGSSpaceCreate")
fileprivate func CGSSpaceCreate(_ cid: CGSConnectionID, _ unknown: Int, _ options: NSDictionary?) -> CGSSpaceID
@_silgen_name("CGSSpaceDestroy")
fileprivate func CGSSpaceDestroy(_ cid: CGSConnectionID, _ space: CGSSpaceID)
@_silgen_name("CGSSpaceSetAbsoluteLevel")
fileprivate func CGSSpaceSetAbsoluteLevel(_ cid: CGSConnectionID, _ space: CGSSpaceID, _ level: Int)
@_silgen_name("CGSAddWindowsToSpaces")
fileprivate func CGSAddWindowsToSpaces(_ cid: CGSConnectionID, _ windows: NSArray, _ spaces: NSArray)
@_silgen_name("CGSRemoveWindowsFromSpaces")
fileprivate func CGSRemoveWindowsFromSpaces(_ cid: CGSConnectionID, _ windows: NSArray, _ spaces: NSArray)
@_silgen_name("CGSHideSpaces")
fileprivate func CGSHideSpaces(_ cid: CGSConnectionID, _ spaces: NSArray)
@_silgen_name("CGSShowSpaces")
fileprivate func CGSShowSpaces(_ cid: CGSConnectionID, _ spaces: NSArray)
@_silgen_name("CGSCopyManagedDisplaySpaces")
fileprivate func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>?
