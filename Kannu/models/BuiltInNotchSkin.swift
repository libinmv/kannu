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

/// A notch skin that ships with Kannu, next to the plain Default and the user's uploads. Its image
/// is an imageset in `Assets.xcassets`; selecting it stores `id` in `selectedNotchSkinID`, the same
/// key an uploaded skin's UUID goes in. Foundation only, so the test target compiles it.
struct BuiltInNotchSkin: Identifiable, Equatable {
    /// Never a UUID string, so it can never be mistaken for an uploaded skin's id.
    let id: String
    let assetName: String
    let name: String

    static let all: [BuiltInNotchSkin] = [
        BuiltInNotchSkin(id: "builtin.horns", assetName: "notch-skin-horns", name: String(localized: "Horns")),
    ]

    static func with(id: String?) -> BuiltInNotchSkin? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}
