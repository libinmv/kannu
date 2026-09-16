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

/// The runner exists because five hand-rolled copies disagreed on the parts that hang a thread.
/// Each test here is one of the ways they could.
final class BoundedProcessRunnerTests: XCTestCase {
    private func shell(_ script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        return process
    }

    func testOutputLargerThanThePipeBufferDoesNotDeadlock() {
        // 300 KB is well past the 64 KB a pipe holds: a wait-then-read waits forever here.
        let result = BoundedProcessRunner.run(shell("head -c 300000 /dev/zero | tr '\\0' x; echo done >&2"), timeout: 10)
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout.count, 300_000)
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "done\n")
    }

    func testCapsKeepThePrefixAndKeepReading() {
        // Past the cap the bytes are still read (so the child never blocks) and dropped.
        let result = BoundedProcessRunner.run(shell("head -c 200000 /dev/zero | tr '\\0' y >&2; echo ok"), timeout: 10, stderrCap: 64_000)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stderr.count, 64_000)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "ok\n")
    }

    func testAChildThatTrapsSIGTERMIsKilled() {
        let started = Date()
        let result = BoundedProcessRunner.run(shell("trap '' TERM; sleep 30"), timeout: 0.5, killGrace: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "SIGTERM was ignored; SIGKILL must land")
    }

    func testAGrandchildHoldingThePipeDoesNotHoldTheCaller() {
        // The background subshell inherits stdout and lives 5 s longer than the child. A read-to-EOF
        // would wait for it; the runner returns when the child does.
        let started = Date()
        let result = BoundedProcessRunner.run(shell("(sleep 5) & echo hi"), timeout: 10)
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "hi\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testAnExecutableThatCannotRunReportsInsteadOfThrowing() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/nonexistent/kannu-no-such-tool")
        let result = BoundedProcessRunner.run(process, timeout: 1)
        XCTAssertEqual(result.status, -1)
        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(result.stderr.isEmpty, "the launch error is the stderr")
    }

    func testExitStatusAndBothStreamsAreReported() {
        let result = BoundedProcessRunner.run(shell("echo out; echo err >&2; exit 3"), timeout: 5)
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "out\n")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "err\n")
    }
}
