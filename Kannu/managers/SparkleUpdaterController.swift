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
import Sparkle

@MainActor
final class SparkleUpdaterController {
    static let shared = SparkleUpdaterController()

    private var standardUpdaterController: SPUStandardUpdaterController?

    private init() {}

    var isEnabled: Bool {
        #if DEBUG
        return false
        #else
        guard !AppRuntimeEnvironment.isUITesting else { return false }
        return Bundle.main.bundleIdentifier == "com.kannu.app"
        #endif
    }

    func configure() {
        guard isEnabled, standardUpdaterController == nil else { return }
        standardUpdaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates(_ sender: Any?) {
        guard isEnabled else { return }
        standardUpdaterController?.checkForUpdates(sender)
    }
}
