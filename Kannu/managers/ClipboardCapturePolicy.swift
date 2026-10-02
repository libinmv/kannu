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

/// Which pasteboard contents Kannu's clipboard history may record.
///
/// Password managers and other apps mark a copy as private by adding a marker type from the
/// nspasteboard.org convention: `org.nspasteboard.ConcealedType` for a secret (a password, a
/// key), `org.nspasteboard.TransientType` for something put there only briefly by automation.
/// The history persists what it records (UserDefaults, in plain text), so honouring the markers
/// is the difference between a password manager's copy vanishing on schedule and living on in
/// Kannu's preferences file. Kannu's own copies of secrets carry the concealed marker too.
enum ClipboardCapturePolicy {
    static let concealedType = "org.nspasteboard.ConcealedType"
    static let transientType = "org.nspasteboard.TransientType"

    /// `types` are the raw pasteboard type identifiers of the current contents.
    static func shouldRecord(types: [String]) -> Bool {
        !types.contains(concealedType) && !types.contains(transientType)
    }
}
