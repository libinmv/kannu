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

/// The watcher behind "Open in Editor". Settings must hear about every way an editor can save the
/// policy, or a hand edit that breaks the JSON switches blocking off while the row still shows the
/// old rule count (the hook ignores a malformed file whole; docs/REGRESSIONS.md entry 1).
final class AgentPolicyWatcherTests: XCTestCase {
    private var directory: URL!
    private var policyFile: URL!
    private var watcher: AgentPolicyWatcher!
    private let box = ExpectationBox()

    private static let valid = Data(#"{"version": 1, "block": [{"command": "ssh"}]}"#.utf8)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentPolicyWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        policyFile = directory.appendingPathComponent("agent-policy.json")
        watcher = AgentPolicyWatcher(fileURL: policyFile, debounce: .milliseconds(40)) { [box] in box.fire() }
    }

    override func tearDownWithError() throws {
        watcher?.stop()
        watcher = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Every way a save can land

    func testAnInPlaceWriteIsSeen() throws {
        try Self.valid.write(to: policyFile)
        XCTAssertTrue(watcher.start())
        try expectChange("in-place append") { try append(" ") }
    }

    func testAnAtomicSaveIsSeenAndTheReplacementIsWatchedToo() throws {
        try Self.valid.write(to: policyFile)
        watcher.start()
        try expectChange("atomic save") { try Self.valid.write(to: policyFile, options: .atomic) }
        // The save put a new inode at the path; an in-place write to *it* must still be heard.
        try expectChange("in-place write to the replacement") { try append(" ") }
    }

    func testAFileCreatedAfterStartIsSeenAndThenWatched() throws {
        XCTAssertTrue(watcher.start(), "the directory exists, so it is watched even with no file yet")
        try expectChange("file created") { try Self.valid.write(to: policyFile) }
        try expectChange("in-place write to the new file") { try append(" ") }
    }

    func testADeletedFileIsSeen() throws {
        try Self.valid.write(to: policyFile)
        watcher.start()
        try expectChange("file deleted") { try FileManager.default.removeItem(at: policyFile) }
    }

    // MARK: - The bug this exists to fix

    /// What the store does on each change: load the file. A save that breaks the JSON must reach
    /// that load and come back as the error Settings shows, not as the old rule count. The break
    /// is a trailing comma, the commonest hand-edit slip, and the one `JSONSerialization` used to
    /// wave through while the hook ignored the file (this test caught that).
    func testASaveThatBreaksTheJSONReachesTheCheckAsAnError() throws {
        try Self.valid.write(to: policyFile)
        let seen = ResultBox()
        watcher.stop()
        watcher = AgentPolicyWatcher(fileURL: policyFile, debounce: .milliseconds(40)) { [box, policyFile] in
            seen.set(AgentPolicy.load(at: policyFile!))
            box.fire()
        }
        watcher.start()
        try expectChange("broken save") {
            try Data(#"{"version": 1, "block": [{"command": "ssh"},]}"#.utf8).write(to: policyFile)
        }
        XCTAssertEqual(seen.get(), .failure(.trailingComma))
    }

    // MARK: - Lifecycle

    func testAMissingDirectoryIsWatchedOnceItExists() throws {
        try FileManager.default.removeItem(at: directory)
        XCTAssertFalse(watcher.start(), "nothing to watch yet")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(watcher.start(), "a later start() picks it up; the store calls start() on every check")
        try expectChange("file created in the new directory") { try Self.valid.write(to: policyFile) }
    }

    func testStartIsIdempotent() throws {
        try Self.valid.write(to: policyFile)
        XCTAssertTrue(watcher.start())
        XCTAssertTrue(watcher.start())
        try expectChange("still exactly one live watch") { try append(" ") }
    }

    func testStopSilencesIt() throws {
        try Self.valid.write(to: policyFile)
        watcher.start()
        watcher.stop()
        let silence = expectation(description: "no call after stop")
        silence.isInverted = true
        box.set(silence)
        try append(" ")
        wait(for: [silence], timeout: 0.4)
        box.set(nil)
    }

    /// An atomic save fires several events (directory entry, old inode deleted); Settings should
    /// re-check once, not once per event.
    func testOneSaveIsOneCall() throws {
        try Self.valid.write(to: policyFile)
        let counter = Counter()
        watcher.stop()
        watcher = AgentPolicyWatcher(fileURL: policyFile, debounce: .milliseconds(150)) { counter.increment() }
        watcher.start()
        try Self.valid.write(to: policyFile, options: .atomic)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(counter.value, 1)
    }

    // MARK: - Helpers

    /// Runs `action` and waits for the change it causes, then lets trailing events drain so they
    /// cannot satisfy the next expectation.
    private func expectChange(_ description: String, _ action: () throws -> Void) throws {
        let expectation = expectation(description: description)
        expectation.assertForOverFulfill = false
        box.set(expectation)
        try action()
        wait(for: [expectation], timeout: 3)
        box.set(nil)
        Thread.sleep(forTimeInterval: 0.15)
    }

    /// An in-place write: same inode, new bytes. What `echo >>` and some editors do.
    private func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: policyFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }
}

/// Where the current expectation lives; the watcher calls in from its own queue.
private final class ExpectationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: XCTestExpectation?
    func set(_ expectation: XCTestExpectation?) { lock.withLock { current = expectation } }
    func fire() { lock.withLock { current }?.fulfill() }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<AgentPolicy, AgentPolicy.LoadError>?
    func set(_ value: Result<AgentPolicy, AgentPolicy.LoadError>) { lock.withLock { result = value } }
    func get() -> Result<AgentPolicy, AgentPolicy.LoadError>? { lock.withLock { result } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
