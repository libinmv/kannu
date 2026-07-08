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
import AtollExtensionKit

struct ExtensionDescriptorValidator {
    static func validate(_ descriptor: AtollLiveActivityDescriptor) throws {
        guard descriptor.isValid else {
            throw ExtensionValidationError.invalidDescriptor("Missing mandatory fields")
        }
        guard descriptor.leadingIcon.isValid else {
            throw ExtensionValidationError.invalidDescriptor("Invalid leading icon data")
        }
        if let badge = descriptor.badgeIcon {
            guard badge.isValid else {
                throw ExtensionValidationError.invalidDescriptor("Invalid badge icon data")
            }
        }
        if descriptor.metadata.count > 32 {
            throw ExtensionValidationError.invalidDescriptor("Metadata keys must be ≤ 32")
        }
    }

    static func validate(_ descriptor: AtollLockScreenWidgetDescriptor) throws {
        guard descriptor.isValid else {
            throw ExtensionValidationError.invalidDescriptor("Missing mandatory fields")
        }
        guard descriptor.content.count <= 12 else {
            throw ExtensionValidationError.invalidDescriptor("Too many content elements")
        }
        guard descriptor.size.width <= 480, descriptor.size.height <= 280 else {
            throw ExtensionValidationError.invalidDescriptor("Widget exceeds size limits")
        }
    }

    static func validate(_ descriptor: AtollNotchExperienceDescriptor) throws {
        guard descriptor.isValid else {
            throw ExtensionValidationError.invalidDescriptor("Missing mandatory fields")
        }
        if let durationHint = descriptor.durationHint {
            guard durationHint > 0, durationHint <= 21_600 else {
                throw ExtensionValidationError.invalidDescriptor("Duration hint must be between 0 and 6 hours")
            }
        }
    }
}
