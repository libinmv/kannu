//
//  UsageScriptTests.swift
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

/// Runs the Claude statusline mirror (`scripts/kannu-usage-status.sh`) as a subprocess with a
/// synthetic `rate_limits` payload and checks what lands in `claude-usage.json`. The mirror is
/// byte-for-byte the copy `AgentHookInstaller` embeds, so this pins both. Until now nothing
/// executed the usage script at all.
final class UsageScriptTests: XCTestCase {

    private var home: URL!
    private var usageFile: URL { home.appendingPathComponent(".kannu/agent-status/claude-usage.json") }

    private static let scriptURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/kannu-usage-status.sh")
    }()

    override func setUpWithError() throws {
        try XCTSkipUnless(["/opt/homebrew/bin/python3", "/usr/bin/python3", "/usr/local/bin/python3"]
                            .contains { FileManager.default.isExecutableFile(atPath: $0) },
                          "python3 not installed")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.scriptURL.path),
                          "mirror script not found at \(Self.scriptURL.path)")
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("kannu-usage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private func run(payload: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(payload.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func windows() throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: usageFile)) as? [String: Any]
        return json?["windows"] as? [[String: Any]] ?? []
    }

    func testForwardsSeverityOnlyWhereTheBucketCarriesOne() throws {
        try run(payload: #"""
        {"rate_limits":{
            "five_hour":{"used_percentage":93,"resets_at":1788010000,"severity":"critical"},
            "seven_day":{"used_percentage":10,"resets_at":1788500000},
            "model_scoped":[{"display_name":"Fable","utilization":95,"resets_at":"2026-09-09T00:00:00Z","severity":"critical"}]
        }}
        """#)
        let byKey = Dictionary(uniqueKeysWithValues: try windows().map { ($0["key"] as! String, $0) })
        XCTAssertEqual(byKey["five_hour"]?["severity"] as? String, "critical")
        XCTAssertNil(byKey["seven_day"]?["severity"], "no severity in the bucket means none in the file")
        XCTAssertEqual(byKey["model_scoped:Fable"]?["label"] as? String, "Fable")
        XCTAssertEqual(byKey["model_scoped:Fable"]?["severity"] as? String, "critical")
        XCTAssertEqual((byKey["model_scoped:Fable"]?["pct"] as? NSNumber)?.doubleValue, 95)
    }

    func testEmptyOrNullSeverityIsDropped() throws {
        try run(payload: #"""
        {"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":1788010000,"severity":""},
                        "seven_day":{"used_percentage":5,"resets_at":1788500000,"severity":null}}}
        """#)
        for window in try windows() {
            XCTAssertNil(window["severity"], "\(window["key"] ?? "?") carried an empty severity")
        }
    }

    func testWritesNothingWithoutRateLimits() throws {
        try run(payload: #"{"session_id":"s","rate_limits":null}"#)
        XCTAssertFalse(FileManager.default.fileExists(atPath: usageFile.path))
    }
}
