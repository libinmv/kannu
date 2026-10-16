//
//  TaskFileStoreTests.swift
//  KannuTests
//
//  Copyright (C) 2026 Kannu contributors
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import XCTest

/// `tasks.json` in a temporary folder: private on disk, never overwritten by an older save, and
/// never lost when it cannot be read.
final class TaskFileStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskFileStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeStore() -> TaskFileStore {
        let folder = folder!
        return TaskFileStore(directory: { folder })
    }

    private func file(_ titles: String...) -> TasksFile {
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        return TasksFile(tasks: titles.map { TaskItem(title: $0, createdAt: created) }, drafts: [])
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    func testNoFileYetIsAnEmptyList() async {
        let result = await makeStore().load()
        XCTAssertEqual(result, .empty)
    }

    func testASavedListLoadsBack() async {
        let saved = file("Write the release notes", "Review PR 42")
        let store = makeStore()
        let outcome = await store.save(saved, revision: 1)
        XCTAssertEqual(outcome, .written)
        let loaded = await makeStore().load()
        XCTAssertEqual(loaded, .loaded(saved))
    }

    func testTheFileIsReadableOnlyByTheUser() async throws {
        let outcome = await makeStore().save(file("Private title"), revision: 1)
        XCTAssertEqual(outcome, .written)
        XCTAssertEqual(try mode(of: folder.appendingPathComponent("tasks.json")), 0o600)
        XCTAssertEqual(try mode(of: folder), 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [], "the temporary file is renamed over, never left behind")
    }

    func testAStaleRevisionIsDropped() async {
        let store = makeStore()
        let newer = file("Newer")
        let first = await store.save(newer, revision: 2)
        XCTAssertEqual(first, .written)
        let second = await store.save(file("Older"), revision: 1)
        XCTAssertEqual(second, .stale)
        let repeated = await store.save(file("Same revision"), revision: 2)
        XCTAssertEqual(repeated, .stale)
        let loaded = await makeStore().load()
        XCTAssertEqual(loaded, .loaded(newer))
    }

    func testTheQuitPathKeepsToTheSameRevisionRule() async {
        let store = makeStore()
        let quit = file("Saved at quit")
        XCTAssertEqual(store.saveImmediately(quit, revision: 5), .written)
        let late = await store.save(file("Slower save still in flight"), revision: 4)
        XCTAssertEqual(late, .stale, "an earlier save landing late cannot undo the quit save")
        let loaded = await makeStore().load()
        XCTAssertEqual(loaded, .loaded(quit))
    }

    func testACorruptFileIsMovedAsideAndNeverOverwritten() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let garbage = Data("{ this is not a task list".utf8)
        try garbage.write(to: folder.appendingPathComponent("tasks.json"))

        let result = await makeStore().load()
        guard case .movedAside(let name) = result else {
            return XCTFail("expected the file to be moved aside, got \(result)")
        }
        XCTAssertTrue(name.hasPrefix("tasks.corrupt-") && name.hasSuffix(".json"), name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("tasks.json").path))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), garbage, "kept byte for byte")

        let afterwards = await makeStore().load()
        XCTAssertEqual(afterwards, .empty, "the list starts again from nothing")
    }
}
