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

import AppKit

extension NSPasteboard {
    /// Copies `text` marked as concealed (the nspasteboard.org convention password managers use),
    /// for a secret such as the cloud relay key: clipboard managers, Kannu's own history included
    /// (`ClipboardCapturePolicy`), leave it out of what they keep.
    func setConcealedString(_ text: String) {
        clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType(ClipboardCapturePolicy.concealedType))
        writeObjects([item])
    }
}
