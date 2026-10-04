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

/// The left wing of the closed notch while music plays: the album art, and beside it the badge of
/// the activity paired with the music (a timer, a recording, Focus, Caps Lock, an extension, the
/// shelf). The badge used to sit over the art's bottom-right corner and hid a quarter of a 20 pt
/// thumbnail; it now sits beside it.
///
/// - The art never moves: it keeps its slot (`artSlotWidth` × `contentHeight`, centred in it as
///   before), so the open/close matched-geometry animation flies from the same rect.
/// - The badge adds width only while it is drawn. The wing's frame and the notch width both read
///   `width`, so the black shape always fits what it holds.
/// - No badge during an inline sneak peek: that window is a fixed 460 pt
///   (`KannuApp.calculateRequiredNotchSize`) that an unpaired notch already fills, and anything
///   wider is cut off at both edges.
struct ClosedMusicWingLayout: Equatable {
    static let badgeSpacing: CGFloat = 4
    static let minimumBadgeSize: CGFloat = 13
    static let badgeToHeightRatio: CGFloat = 0.36

    /// The art's slot; also the right wing's base width, which this type never changes.
    let artSlotWidth: CGFloat
    let contentHeight: CGFloat
    let showsBadge: Bool

    init(artSlotWidth: CGFloat, contentHeight: CGFloat, hasPairedActivity: Bool, inlineSneakPeekActive: Bool) {
        self.artSlotWidth = max(0, artSlotWidth)
        self.contentHeight = max(0, contentHeight)
        self.showsBadge = hasPairedActivity && !inlineSneakPeekActive
    }

    var badgeSize: CGFloat { max(Self.minimumBadgeSize, contentHeight * Self.badgeToHeightRatio) }

    var width: CGFloat { artSlotWidth + (showsBadge ? Self.badgeSpacing + badgeSize : 0) }

    /// Where the square art is drawn: as large as fits the slot, centred in it.
    var artRect: CGRect {
        let side = min(artSlotWidth, contentHeight)
        return CGRect(x: (artSlotWidth - side) / 2, y: (contentHeight - side) / 2, width: side, height: side)
    }

    /// Where the badge is drawn, right of the slot and vertically centred; nil when there is none.
    var badgeRect: CGRect? {
        guard showsBadge else { return nil }
        return CGRect(x: artSlotWidth + Self.badgeSpacing, y: (contentHeight - badgeSize) / 2,
                      width: badgeSize, height: badgeSize)
    }
}
