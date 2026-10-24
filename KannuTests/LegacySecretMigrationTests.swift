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

import XCTest

/// The launch-time move of legacy plaintext secrets into the Keychain read all eight items on the
/// main thread, dialogs allowed, at every launch. Now it decides each one from a silent read, and
/// only runs at all for a value still in Defaults.
final class LegacySecretMigrationTests: XCTestCase {
    private typealias Step = LegacySecretMigration.Step

    func testAnItemAlreadyThereWinsReadableOrNot() {
        XCTAssertEqual(LegacySecretMigration.step(existingValue: "saved", needsApproval: false, itemNotFound: false), .clearLegacy)
        XCTAssertEqual(LegacySecretMigration.step(existingValue: nil, needsApproval: true, itemNotFound: false), .clearLegacy,
                       "an item another build saved is kept, never overwritten or prompted for")
    }

    func testTheLegacyValueIsStoredOnlyWhereNothingIs() {
        XCTAssertEqual(LegacySecretMigration.step(existingValue: nil, needsApproval: false, itemNotFound: true), .store)
        XCTAssertEqual(LegacySecretMigration.step(existingValue: "", needsApproval: false, itemNotFound: false), .store)
    }

    func testAnythingElseWaitsForTheNextLaunch() {
        XCTAssertEqual(LegacySecretMigration.step(existingValue: nil, needsApproval: false, itemNotFound: false), .retryNextLaunch)
    }

    // MARK: - The launch path

    func testTheLaunchPathIsSilentAndOffTheMainThread() throws {
        let store = try Self.read("Kannu/helpers/SecureSecretsStore.swift")
        let usage = try Self.read("Kannu/managers/LLMUsage/LLMUsageManager.swift")
        XCTAssertEqual(Self.problems(store: store, usage: usage), [])

        let oldStore = store.replacingOccurrences(
            of: "        guard !pending.isEmpty else { return }\n        DispatchQueue.global(qos: .utility).async {\n",
            with: "        _ = value(for: .spotifySPDCCookie)\n        DispatchQueue.main.async {\n"
        )
        XCTAssertNotEqual(oldStore, store, "the plant did not take")
        XCTAssertEqual(Self.problems(store: oldStore, usage: usage), [
            "the migration reads the Keychain before knowing there is anything to move",
            "the migration's Keychain reads run on the main thread",
        ])

        let oldUsage = usage.replacingOccurrences(of: "            DispatchQueue.global(qos: .utility).async {\n                _ = KeychainReader.deleteGenericPassword",
                                                  with: "            do {\n                _ = KeychainReader.deleteGenericPassword")
        XCTAssertNotEqual(oldUsage, usage, "the plant did not take")
        XCTAssertEqual(Self.problems(store: store, usage: oldUsage), ["the legacy Claude credential delete runs on the main thread"])
    }

    static func problems(store: String, usage: String) -> [String] {
        var problems: [String] = []
        let migration = store.components(separatedBy: "static func migrateFromDefaultsIfNeeded() {").dropFirst().first ?? ""
        let beforeGuard = migration.components(separatedBy: "guard !pending.isEmpty else { return }").first ?? migration
        if beforeGuard.contains("value(for:") || beforeGuard.contains("read(") || !migration.contains("guard !pending.isEmpty else { return }") {
            problems.append("the migration reads the Keychain before knowing there is anything to move")
        }
        let afterGuard = migration.components(separatedBy: "guard !pending.isEmpty else { return }").dropFirst().first ?? ""
        if !afterGuard.hasPrefix("\n        DispatchQueue.global(") || !migration.contains("read(secureKey, allowInteraction: false)") {
            problems.append("the migration's Keychain reads run on the main thread")
        }
        let delete = usage.components(separatedBy: "KeychainReader.deleteGenericPassword(service: \"com.kannu.app.llm-credentials\"").first ?? ""
        if !(delete.suffix(160).contains("DispatchQueue.global(")) {
            problems.append("the legacy Claude credential delete runs on the main thread")
        }
        return problems
    }

    private static func read(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
