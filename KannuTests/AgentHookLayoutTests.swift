//
//  AgentHookLayoutTests.swift
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

/// docs/REGRESSIONS.md entry 6: install, uninstall, the installed check and the migrations must
/// cover the same files. They all read `AgentHookLayout` now; these pin the table and keep paths
/// from creeping back into the installer.
final class AgentHookLayoutTests: XCTestCase {
    private let layout = AgentHookLayout(home: URL(fileURLWithPath: "/Users/u"))

    func testEveryProviderHasAScriptAndAFileInstallAlwaysWrites() {
        var scripts: Set<URL> = []
        var configs: Set<URL> = []
        for provider in AgentHookProvider.allCases {
            let files = layout.files(for: provider)
            XCTAssertEqual(files.script.lastPathComponent, AgentHookLayout.scriptName, "\(provider)")
            XCTAssertTrue(files.script.path.hasPrefix("/Users/u/."), "\(provider) lives in the home folder")
            XCTAssertTrue(scripts.insert(files.script).inserted, "\(provider) has a script of its own")
            XCTAssertTrue(files.configs.contains { $0.write == .always },
                          "\(provider): a fresh install must write a file the installed check can see")
            for config in files.configs {
                XCTAssertTrue(configs.insert(config.url).inserted, "\(config.url.path) belongs to one provider")
                XCTAssertEqual(layout.shape(of: config.url), config.shape)
            }
        }
        XCTAssertNil(layout.shape(of: URL(fileURLWithPath: "/Users/u/.zshrc")))
    }

    func testAntigravityListsAllThreeFilesItReads() {
        let files = layout.files(for: .antigravity)
        XCTAssertEqual(files.configs.map(\.url.path), ["/Users/u/.gemini/config/hooks.json",
                                                       "/Users/u/.gemini/antigravity-ide/hooks.json",
                                                       "/Users/u/.gemini/hooks.json"])
        XCTAssertEqual(files.configs.map(\.write), [.always, .onlyIfPresent, .onlyIfPresent])
        XCTAssertEqual(layout.files(for: .codex).sharedSettings.map(\.lastPathComponent), ["config.toml"])
        XCTAssertEqual(layout.files(for: .vscode).configs.map(\.shape), [.ownFile])
        XCTAssertEqual(layout.files(for: .cursor).configs.map(\.shape), [.flatEntries])
    }

    /// The installer may name paths only through the layout. Comments and the embedded hook
    /// script (whose sensitive-file tables list agent settings on purpose) are not code paths.
    func testTheInstallerHardCodesNoHookPaths() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kannu/managers/AgentStatus/AgentHookInstaller.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let forbidden = [".cursor/hooks.json", ".cursor/hooks/", ".copilot/hooks", ".codex/hooks.json", ".codex/config.toml",
                         ".claude/settings.json", ".gemini/config/hooks.json", ".gemini/antigravity-ide", ".gemini/hooks.json"]
        var insideScript = false
        for (number, line) in source.components(separatedBy: "\n").enumerated() {
            if insideScript {
                if line == "        \"\"\"" { insideScript = false }
                continue
            }
            if line.hasSuffix("let script = \"\"\"") { insideScript = true; continue }
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("//") || code.hasPrefix("*") { continue }
            for path in forbidden where code.contains(path) {
                XCTFail("AgentHookInstaller.swift:\(number + 1) names \(path); take it from AgentHookLayout")
            }
        }
    }
}
