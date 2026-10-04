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

import Security
import XCTest

/// Keeps Kannu's secrets in keychain items whose access list Kannu made.
///
/// Every secret Kannu stores (the AI provider API keys, the Pushover keys, the webhook URL, the
/// Spotify cookie) goes through `SecureSecretsStore` into `KeychainReader.setGenericPassword`. That
/// save used to update an existing item in place, and an in-place update keeps the item's access
/// list: an item pre-planted under Kannu's service and account with a list that lets any app read
/// it would have been handed the secret. Saves now delete and re-add, so the access list is always
/// the fresh one `SecItemAdd` builds, trusting only Kannu.
///
/// The plan is pinned directly; the rest scans the sources, because the failure this guards
/// against is someone "simplifying" the save back into an update.
final class KeychainWritePlanTests: XCTestCase {

    private static let readerPath = "Kannu/managers/LLMUsage/Quota/KeychainReader.swift"
    private static let storePath = "Kannu/helpers/SecureSecretsStore.swift"

    /// Calls that change an existing keychain item in place and so keep its access list:
    /// the modern API and the legacy `SecKeychainItemModify…` family.
    private static let inPlaceUpdateFragments = ["SecItemUpdate", "SecKeychainItemModify"]

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root

    // MARK: - The plan

    func testKannuOwnedServicesAreRecreated() {
        for service in ["com.kannu.app.secure-secrets", "com.kannu.app.llm-credentials"] {
            XCTAssertEqual(KeychainWritePlan.forSaving(service: service), .recreate, service)
            XCTAssertTrue(KeychainWritePlan.isKannuOwned(service: service), service)
        }
    }

    /// Kannu reads Codex's and Cursor's tokens from the keychain, and once read Claude Code's. Those
    /// items belong to the apps that made them; Kannu must never write or delete them.
    func testAnotherAppsItemIsNeverWritten() {
        let foreign = [
            "Claude Code-credentials",
            "Codex Auth",
            "cursor-access-token",
            "com.kannu.app.",                   // the bare prefix names no item
            "com.kannu.app",
            "com.kannu.application.secrets",
            "xcom.kannu.app.secure-secrets",
            "COM.KANNU.APP.secure-secrets",
            ""
        ]
        for service in foreign {
            XCTAssertEqual(KeychainWritePlan.forSaving(service: service), .refuse, service)
            XCTAssertFalse(KeychainWritePlan.isKannuOwned(service: service), service)
        }
    }

    /// The add runs only when the delete left nothing behind. Anything else means an item may still
    /// sit there, and the only way to put the secret into it would be the in-place update this whole
    /// change removes.
    func testTheSaveStopsWhenTheDeleteLeftSomethingBehind() {
        XCTAssertTrue(KeychainWritePlan.deleteLeftNothing(errSecSuccess))
        XCTAssertTrue(KeychainWritePlan.deleteLeftNothing(errSecItemNotFound))
        for status in [errSecUserCanceled, errSecInteractionNotAllowed, errSecAuthFailed, errSecDuplicateItem, errSecNotAvailable] {
            XCTAssertFalse(KeychainWritePlan.deleteLeftNothing(status), "status \(status)")
        }
    }

    /// Delete-then-add is not atomic. Once the delete has run, a failed add leaves no item, so a
    /// user editing a working Pushover token would lose it at the next relaunch with no error shown.
    /// The save puts the prior value back whenever the add failed, and only then.
    func testAFailedAddPutsThePriorValueBack() {
        for status in [errSecDuplicateItem, errSecNotAvailable, errSecInteractionNotAllowed, errSecIO, errSecParam] {
            XCTAssertEqual(KeychainWritePlan.valueToRestore(afterAdd: status, prior: "old-token"), "old-token", "status \(status)")
            XCTAssertNil(KeychainWritePlan.valueToRestore(afterAdd: status, prior: nil), "nothing was there to put back")
        }
        XCTAssertNil(KeychainWritePlan.valueToRestore(afterAdd: errSecSuccess, prior: "old-token"), "a saved value must not be overwritten")
    }

    // MARK: - The callers

    /// The audit behind this change, kept true: every call into the write path names a service Kannu
    /// owns. A string literal must be Kannu's; the one non-literal is `SecureSecretsStore`'s own
    /// `service` constant, which must be Kannu's too.
    func testEveryCallerOfTheWritePathNamesAKannuOwnedService() throws {
        let sources = Self.appSources()
        let calls = try NSRegularExpression(
            pattern: #"KeychainReader\.(?:set|delete)GenericPassword\([^)]*?service:\s*("[^"]*"|\w+)"#
        )
        var sites: [String] = []
        for (path, source) in sources {
            for line in Self.codeLines(of: source) {
                let range = NSRange(line.startIndex..., in: line)
                for match in calls.matches(in: line, range: range) {
                    guard let argumentRange = Range(match.range(at: 1), in: line) else { continue }
                    let argument = String(line[argumentRange])
                    sites.append(path)
                    if argument.hasPrefix("\"") {
                        let service = String(argument.dropFirst().dropLast())
                        XCTAssertTrue(KeychainWritePlan.isKannuOwned(service: service), "\(path) writes \(service)")
                    } else {
                        XCTAssertEqual(path, Self.storePath, "\(path) writes a keychain service this test cannot read: \(argument)")
                        XCTAssertEqual(argument, "service", path)
                    }
                }
            }
        }
        XCTAssertTrue(sites.contains(Self.storePath), "No write call found in SecureSecretsStore — check the pattern, not the rule.")

        let store = try XCTUnwrap(sources[Self.storePath])
        let constant = try NSRegularExpression(pattern: #"static let service = "([^"]+)""#)
        let match = try XCTUnwrap(constant.firstMatch(in: store, range: NSRange(store.startIndex..., in: store)))
        let serviceRange = try XCTUnwrap(Range(match.range(at: 1), in: store))
        let service = String(store[serviceRange])
        XCTAssertEqual(KeychainWritePlan.forSaving(service: service), .recreate, service)
    }

    // MARK: - The rule

    func testNothingInTheAppUpdatesAKeychainItemInPlace() {
        let sources = Self.appSources()
        XCTAssertGreaterThan(sources.count, 100, "The source scan found almost nothing — check the path, not the rule.")
        XCTAssertNotNil(sources[Self.readerPath], "KeychainReader.swift was not read; the scan would pass vacuously.")

        var offenders: [String] = []
        for (path, source) in sources {
            offenders.append(contentsOf: Self.inPlaceUpdates(in: source, path: path))
        }
        XCTAssertEqual(
            offenders.sorted(), [],
            """
            A keychain item updated in place keeps its access list, so a pre-planted item with a \
            permissive list receives the secret. Save through KeychainReader.setGenericPassword, \
            which deletes and re-adds (KeychainWritePlan).
            """
        )
    }

    /// One place creates keychain items, so one place has to get the plan right.
    func testOnlyKeychainReaderAddsKeychainItems() {
        var adders: [String] = []
        for (path, source) in Self.appSources() where Self.codeLines(of: source).contains(where: { $0.contains("SecItemAdd") }) {
            adders.append(path)
        }
        XCTAssertEqual(adders, [Self.readerPath])
    }

    /// The save asks the plan, reads the prior value, deletes, adds, and puts the prior value back
    /// when the add failed — in that order. The delete refuses a service Kannu does not own.
    func testTheSaveConsultsThePlanAndDeletesBeforeItAdds() throws {
        let reader = try XCTUnwrap(Self.appSources()[Self.readerPath])
        XCTAssertEqual(Self.saveProblems(in: reader), [])

        let remove = try XCTUnwrap(Self.body(of: "static func deleteGenericPassword", in: reader))
        let owned = try XCTUnwrap(remove.range(of: "KeychainWritePlan.isKannuOwned(service: service)"))
        let secDelete = try XCTUnwrap(remove.range(of: "SecItemDelete("))
        XCTAssertLessThan(owned.lowerBound, secDelete.lowerBound, "Ownership must be checked before anything is deleted.")
        XCTAssertTrue(remove.contains("KeychainWritePlan.deleteLeftNothing("))
    }

    /// The one place that calls `SecItemAdd` keeps the item's attributes, stays private, and runs only
    /// from the save — an add anywhere else would skip the plan and the delete.
    func testTheFreshAddKeepsKannusAttributesAndRunsOnlyFromTheSave() throws {
        let reader = try XCTUnwrap(Self.appSources()[Self.readerPath])
        let add = try XCTUnwrap(Self.body(of: "static func addGenericPassword", in: reader))
        XCTAssertTrue(add.contains("SecItemAdd("))
        XCTAssertTrue(add.contains("kSecAttrAccessibleWhenUnlockedThisDeviceOnly"))
        XCTAssertTrue(Self.codeLines(of: reader).contains { $0.contains("private static func addGenericPassword(") })

        let save = try XCTUnwrap(Self.body(of: "static func setGenericPassword", in: reader))
        let calls = { (text: String) in text.components(separatedBy: "addGenericPassword(").count - 1 }
        XCTAssertEqual(calls(save), 2, "the add and the restore")
        XCTAssertEqual(calls(Self.codeLines(of: reader).joined(separator: "\n")), 3, "the declaration plus the save's two calls")
    }

    // MARK: - The scanner itself

    /// Guards the detector, not the tree: the save as it stood before 2026-10-04 must be caught.
    func testTheScannerCatchesThePlantedOldSave() {
        let planted = """
        static func setGenericPassword(_ value: String, service: String, account: String) -> Bool {
            let data = Data(value.utf8)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecSuccess {
                return true
            }
            if status == errSecItemNotFound {
                var insert = query
                insert.merge(attributes) { _, new in new }
                return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
            }
            return false
        }
        """
        XCTAssertEqual(Self.inPlaceUpdates(in: planted, path: "X.swift"), ["X.swift:12"])
    }

    /// Guards the order check: the first delete-then-add save, which lost the old secret whenever
    /// the add failed, must be caught.
    func testTheOrderCheckCatchesASaveThatCannotPutThePriorValueBack() {
        let planted = """
        static func setGenericPassword(_ value: String, service: String, account: String) -> Bool {
            guard KeychainWritePlan.forSaving(service: service) == .recreate else { return false }
            guard deleteGenericPassword(service: service, account: account) else { return false }
            let item: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: Data(value.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        """
        let problems = Self.saveProblems(in: planted)
        XCTAssertTrue(problems.contains { $0.contains("allowInteraction: false") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("valueToRestore") }, "\(problems)")

        let readAfterDelete = """
        static func setGenericPassword(_ value: String, service: String, account: String) -> Bool {
            guard KeychainWritePlan.forSaving(service: service) == .recreate else { return false }
            guard deleteGenericPassword(service: service, account: account) else { return false }
            let prior = read(service: service, account: account, allowInteraction: false).value
            let status = addGenericPassword(value, service: service, account: account)
            if status == errSecSuccess { return true }
            if let restore = KeychainWritePlan.valueToRestore(afterAdd: status, prior: prior) {
                _ = addGenericPassword(restore, service: service, account: account)
            }
            return false
        }
        """
        XCTAssertFalse(Self.saveProblems(in: readAfterDelete).isEmpty, "a prior value read after the delete is always nil")
    }

    func testWhitespaceAndTheLegacyAPIDoNotEvadeTheScanner() {
        let planted = """
        let s = SecItemUpdate (query, attributes)
        let t = SecKeychainItemModifyAttributesAndData(item, nil, length, bytes)
        let u = SecKeychainItemModifyContent(item, nil, length, bytes)
        """
        XCTAssertEqual(Self.inPlaceUpdates(in: planted, path: "X.swift").count, 3)
    }

    /// A comment explaining the rule must not trip it.
    func testCommentsAboutTheRuleAreNotOffenders() {
        let prose = """
        /// An in-place SecItemUpdate keeps the item's access list.
        // Never call SecItemUpdate here.
         * `SecKeychainItemModifyContent` is the legacy spelling.
        """
        XCTAssertEqual(Self.inPlaceUpdates(in: prose, path: "X.swift"), [])
    }

    // MARK: - Helpers

    /// What `setGenericPassword` must do, in this order.
    private static let saveSteps: [(fragment: String, why: String)] = [
        ("KeychainWritePlan.forSaving(service: service) == .recreate", "ask the plan before touching anything"),
        ("read(service: service, account: account, allowInteraction: false)", "read the prior value silently, before the delete removes it"),
        ("deleteGenericPassword(service: service, account: account)", "remove the old item before adding"),
        ("addGenericPassword(value, service: service, account: account)", "add the new value fresh"),
        ("KeychainWritePlan.valueToRestore(afterAdd: status, prior: prior)", "decide whether a failed add needs the prior value back"),
        ("addGenericPassword(restore, service: service, account: account)", "put the prior value back with a fresh add")
    ]

    /// Every step of `saveSteps` missing from the save, or found only before an earlier step.
    private static func saveProblems(in reader: String) -> [String] {
        guard let save = body(of: "static func setGenericPassword", in: reader) else { return ["no setGenericPassword"] }
        var problems: [String] = []
        var cursor = save.startIndex
        for step in saveSteps {
            guard let found = save.range(of: step.fragment, range: cursor..<save.endIndex) else {
                problems.append("missing or out of order: \(step.fragment) (\(step.why))")
                continue
            }
            cursor = found.upperBound
        }
        return problems
    }

    private static func inPlaceUpdates(in source: String, path: String) -> [String] {
        var hits: [String] = []
        for (index, line) in source.components(separatedBy: "\n").enumerated() where !isComment(line) {
            if inPlaceUpdateFragments.contains(where: { line.contains($0) }) {
                hits.append("\(path):\(index + 1)")
            }
        }
        return hits
    }

    private static func isComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*")
    }

    private static func codeLines(of source: String) -> [String] {
        source.components(separatedBy: "\n").filter { !isComment($0) }
    }

    /// The text from `signature` up to the next `static func`, with comment lines removed.
    private static func body(of signature: String, in source: String) -> String? {
        guard let start = source.range(of: signature) else { return nil }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "static func ")?.lowerBound ?? rest.endIndex
        return codeLines(of: String(rest[..<end])).joined(separator: "\n")
    }

    /// Every Swift file under `Kannu/`, keyed by its repo-relative path.
    private static func appSources() -> [String: String] {
        let root = repoRoot.appendingPathComponent("Kannu")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
        var out: [String: String] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let path = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            out[path] = text
        }
        return out
    }
}
