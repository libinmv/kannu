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

/// A beta never reaches every user. The release workflow runs on every `v*` tag, and its last step
/// commits the appcast to `main`, which every installed Kannu reads: before pre-release tags were
/// handled, `v1.4.0-beta.1` would have been offered to everyone by Sparkle and published as the
/// Latest release. A tag with a hyphen is a pre-release now; these pins keep it one. The workflow
/// is YAML that only runs on a tag, so its text is read.
final class ReleaseWorkflowRulesTests: XCTestCase {
    private static let workflowPath = ".github/workflows/release.yml"

    func testAPreReleaseTagNeverReachesTheAppcast() throws {
        XCTAssertEqual(Self.problems(in: try Self.read(Self.workflowPath)), [])
    }

    func testTheScannerCatchesTheOldWorkflow() throws {
        let workflow = try Self.read(Self.workflowPath)
        let unguarded = workflow.replacingOccurrences(of: "        if: env.RELEASE_PRERELEASE != 'true'\n", with: "")
        XCTAssertEqual(Self.problems(in: unguarded), [
            "Export Sparkle Update Assets runs for a pre-release",
            "Upload Sparkle Artifact runs for a pre-release",
            "Update appcast on main runs for a pre-release",
        ])
        let unflagged = workflow
            .replacingOccurrences(of: "          prerelease: ${{ env.RELEASE_PRERELEASE == 'true' }}\n", with: "")
            .replacingOccurrences(of: "if [[ \"${VERSION}\" == *-* ]]; then", with: "if false; then")
        XCTAssertEqual(Self.problems(in: unflagged), [
            "a tag with a hyphen is not marked a pre-release",
            "the GitHub release is not published as a pre-release",
        ])
    }

    /// No build strips the `com.apple.security.mach-services` entitlement. The release workflow, CI
    /// and both local build scripts each ran `plutil -remove com.apple.security.mach-services`, which
    /// reads the dots in the key as a key path, answered "No value to remove at key path" and never
    /// removed it: every build those four made, ad-hoc ones included, carried the key. The reason the
    /// strip gave, that amfid kills an ad-hoc app carrying it, does not hold on macOS 26 (an ad-hoc
    /// signed app with hardened runtime and this entitlement launches), and neither does
    /// `ExtensionXPCServiceHost`'s note that its listener crashes the app without it (a Kannu Dev
    /// build without the key started the listener and ran for hours). A strip that worked would
    /// only change what gets signed, for no reason anyone has shown.
    func testNoBuildStripsTheMachServicesEntitlement() throws {
        for path in Self.buildFiles {
            XCTAssertEqual(Self.machServicesProblems(in: try Self.read(path), path: path), [], path)
        }
        let plutilStrip = "if ! plutil_out=$(plutil -remove com.apple.security.mach-services Kannu/Kannu.entitlements 2>&1); then"
        XCTAssertEqual(Self.machServicesProblems(in: plutilStrip, path: "ci.yml"),
                       ["ci.yml strips the mach-services entitlement"])
        let plistBuddyStrip = "/usr/libexec/PlistBuddy -c \"Delete :com.apple.security.mach-services\" \"$ENTITLEMENTS\""
        XCTAssertEqual(Self.machServicesProblems(in: plistBuddyStrip, path: "release.yml"),
                       ["release.yml strips the mach-services entitlement"])
        let quotedStrip = "plutil -remove \"com.apple.security.mach-services\" \"$TEMP_ENTITLEMENTS\""
        XCTAssertEqual(Self.machServicesProblems(in: quotedStrip, path: "build-dmg.sh"),
                       ["build-dmg.sh strips the mach-services entitlement"])
    }

    private static let buildFiles = [
        workflowPath, ".github/workflows/ci.yml", "scripts/build-dmg.sh", "scripts/build-launch-app.sh",
    ]

    static func machServicesProblems(in text: String, path: String) -> [String] {
        strips("com.apple.security.mach-services", in: text) ? ["\(path) strips the mach-services entitlement"] : []
    }

    /// A `plutil -remove` or PlistBuddy `Delete` of `key`, however the shell quotes it.
    private static func strips(_ key: String, in text: String) -> Bool {
        let unquoted = text.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
        return unquoted.contains("plutil -remove \(key)") || unquoted.contains("Delete :\(key)")
    }

    /// No build strips `com.apple.security.cs.disable-library-validation` either. `build-dmg.sh` and
    /// `build-launch-app.sh` ran `plutil -remove` on it, which never removed it, for the same key-path
    /// reason. A strip that worked would break both: their builds are ad-hoc signed, an ad-hoc
    /// signature has no Team ID, and with library validation on, dyld refuses the embedded Lottie
    /// and Sparkle frameworks ("mapping process and mapped file (non-platform) have different Team
    /// IDs"), so the app never starts. An ad-hoc probe app with hardened runtime and an embedded
    /// ad-hoc framework shows exactly that on macOS 26, and runs once the entitlement is back.
    func testNoBuildStripsLibraryValidation() throws {
        for path in Self.buildFiles {
            XCTAssertEqual(Self.libraryValidationProblems(in: try Self.read(path), path: path), [], path)
        }
        let plutilStrip = "if ! plutil_out=$(plutil -remove com.apple.security.cs.disable-library-validation \"$TEMP_ENTITLEMENTS\" 2>&1); then"
        XCTAssertEqual(Self.libraryValidationProblems(in: plutilStrip, path: "build-dmg.sh"),
                       ["build-dmg.sh strips disable-library-validation"])
        let plistBuddyStrip = "/usr/libexec/PlistBuddy -c \"Delete :com.apple.security.cs.disable-library-validation\" \"$TEMP_ENTITLEMENTS\""
        XCTAssertEqual(Self.libraryValidationProblems(in: plistBuddyStrip, path: "build-launch-app.sh"),
                       ["build-launch-app.sh strips disable-library-validation"])
        let quotedStrip = "plutil -remove 'com.apple.security.cs.disable-library-validation' \"$TEMP_ENTITLEMENTS\""
        XCTAssertEqual(Self.libraryValidationProblems(in: quotedStrip, path: "ci.yml"),
                       ["ci.yml strips disable-library-validation"])
    }

    static func libraryValidationProblems(in text: String, path: String) -> [String] {
        strips("com.apple.security.cs.disable-library-validation", in: text)
            ? ["\(path) strips disable-library-validation"] : []
    }

    // MARK: - Rules

    static func problems(in workflow: String) -> [String] {
        var problems: [String] = []
        if !workflow.contains("if [[ \"${VERSION}\" == *-* ]]; then\n            echo \"RELEASE_PRERELEASE=true\" >> \"$GITHUB_ENV\"") {
            problems.append("a tag with a hyphen is not marked a pre-release")
        }
        for step in ["Export Sparkle Update Assets", "Upload Sparkle Artifact", "Update appcast on main"] {
            guard let range = workflow.range(of: "- name: \(step)\n") else {
                problems.append("\(step) is gone")
                continue
            }
            let next = workflow[range.upperBound...].prefix(80)
            if !next.hasPrefix("        if: env.RELEASE_PRERELEASE != 'true'\n") {
                problems.append("\(step) runs for a pre-release")
            }
        }
        let publish = workflow.range(of: "- name: Publish GitHub Release").map { String(workflow[$0.upperBound...].prefix(700)) } ?? ""
        if !publish.contains("prerelease: ${{ env.RELEASE_PRERELEASE == 'true' }}")
            || !publish.contains("make_latest: ${{ env.RELEASE_PRERELEASE == 'true' && 'false' || 'true' }}") {
            problems.append("the GitHub release is not published as a pre-release")
        }
        return problems
    }

    private static func read(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
