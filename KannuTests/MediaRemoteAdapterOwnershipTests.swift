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

/// Which leaked `mediaremote-adapter.pl` helpers Kannu is allowed to kill.
///
/// The argv strings below are real, copied from `ps` on the machine where the leak was found: nine
/// helpers alive at once across four bundle paths, one of them with a live parent. That mix is the
/// whole reason the predicate has to be exact — a basename match would have killed another build's
/// working helper, and ignoring the parent would have killed a helper still in use.
final class MediaRemoteAdapterOwnershipTests: XCTestCase {
    private let installedScript =
        "/Applications/Kannu.app/Contents/Resources/mediaremote-adapter.pl"
    private let installedArgv = """
        /usr/bin/perl /Applications/Kannu.app/Contents/Resources/mediaremote-adapter.pl \
        /Applications/Kannu.app/Contents/Resources/MediaRemoteAdapter.framework stream
        """
    private let buildProductArgv = """
        /usr/bin/perl /Users/x/kannu/.build-release/Build/Products/Release/Kannu.app/Contents/Resources/mediaremote-adapter.pl \
        /Users/x/kannu/.build-release/Build/Products/Release/Kannu.app/Contents/Resources/MediaRemoteAdapter.framework stream
        """

    private func reapable(_ command: String, parent: Int32, own: String) -> Bool {
        MediaRemoteAdapterOwnership.isReapable(
            command: command, parentPID: parent, ownScriptPath: own
        )
    }

    func testOurOwnOrphanIsReaped() {
        XCTAssertTrue(reapable(installedArgv, parent: 1, own: installedScript))
    }

    func testAHelperWithALiveParentIsLeftAlone() {
        // Observed: one of the nine had ppid 37569, a running Kannu that was using it.
        XCTAssertFalse(reapable(installedArgv, parent: 37569, own: installedScript))
    }

    func testAnotherBundlesOrphanIsLeftAlone() {
        // Four bundle paths coexisted on that machine. A basename match would have killed all of
        // them, including a build product's helper whose app is running fine.
        XCTAssertFalse(reapable(buildProductArgv, parent: 1, own: installedScript))
        XCTAssertFalse(
            reapable(
                installedArgv,
                parent: 1,
                own: "/Users/x/kannu/.build-release/Build/Products/Release/Kannu.app/Contents/Resources/mediaremote-adapter.pl"
            )
        )
    }

    func testAnUnrelatedPerlProcessIsLeftAlone() {
        XCTAssertFalse(reapable("/usr/bin/perl /Users/x/bin/backup.pl --nightly", parent: 1, own: installedScript))
    }

    func testAPathThatMerelyContainsOursIsNotOurs() {
        // A bundle nested inside another path would match a plain `contains`.
        let nested = "/usr/bin/perl /Volumes/Backup\(installedScript) /x stream"
        XCTAssertFalse(reapable(nested, parent: 1, own: installedScript))
    }

    func testAPerlProcessThatMerelyMentionsTheScriptIsLeftAlone() {
        // The reason the match is positional rather than a search: a `perl` process can name the file
        // without being the adapter — reading it, linting it, handing it to something else. Signalling
        // one of those would be worse than leaking a helper.
        XCTAssertFalse(reapable("/usr/bin/perl /Users/x/bin/lint.pl \(installedScript)", parent: 1, own: installedScript))
        XCTAssertFalse(reapable("/usr/bin/perl -e print \(installedScript)", parent: 1, own: installedScript))
    }

    func testTheScriptMustFollowTheInterpreterDirectly() {
        // `Process` puts argv[0] (the executable path) first and the arguments after it, so the script
        // is index 1. A shifted layout is not ours and must fail closed.
        XCTAssertFalse(reapable("/usr/bin/perl -w \(installedScript) /x stream", parent: 1, own: installedScript))
    }

    func testAnEmptyOwnPathReapsNothing() {
        // `Bundle.main` has no adapter script — for instance in a test host. Nothing is ours.
        XCTAssertFalse(reapable(installedArgv, parent: 1, own: ""))
        XCTAssertFalse(reapable("", parent: 1, own: ""))
    }

    func testTheScriptPathIsFoundAtTheEndOfTheCommandToo() {
        // The framework path and `stream` are not required — only the interpreter and the script.
        XCTAssertTrue(
            MediaRemoteAdapterOwnership.commandNamesScript("/usr/bin/perl \(installedScript)", installedScript)
        )
    }

    func testACommandWithNoScriptArgumentMatchesNothing() {
        XCTAssertFalse(MediaRemoteAdapterOwnership.commandNamesScript(installedScript, installedScript))
        XCTAssertFalse(MediaRemoteAdapterOwnership.commandNamesScript("/usr/bin/perl", installedScript))
        XCTAssertFalse(MediaRemoteAdapterOwnership.commandNamesScript("", installedScript))
    }

    func testAPrefixOfTheScriptPathDoesNotMatch() {
        XCTAssertFalse(
            MediaRemoteAdapterOwnership.commandNamesScript(
                "/usr/bin/perl /Applications/Kannu.app/Contents/Resources/mediaremote-adapter.plx /x stream",
                installedScript
            )
        )
    }
}
