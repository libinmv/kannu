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

/// The extension RPC server listens on port 9020 from launch. It took connections on every
/// interface, so any machine on the network could open one, and dropped non-loopback peers only
/// after accepting them. It is loopback-only now; the server is AppKit, so its text is read.
final class ExtensionRPCServerRulesTests: XCTestCase {
    func testTheListenerIsLoopbackOnly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Kannu/services/Extensions/ExtensionRPCServer.swift"),
                                encoding: .utf8)
        XCTAssertEqual(Self.problems(in: source), [])

        let open = source.replacingOccurrences(of: "        params.requiredInterfaceType = .loopback\n", with: "")
        XCTAssertNotEqual(open, source, "the plant did not take")
        XCTAssertEqual(Self.problems(in: open), ["the RPC listener is not limited to loopback"])

        let unchecked = source.replacingOccurrences(of: "guard isLoopback(endpoint: nwConnection.endpoint) else {",
                                                    with: "guard true else {")
        XCTAssertNotEqual(unchecked, source, "the plant did not take")
        XCTAssertEqual(Self.problems(in: unchecked), ["new connections are not checked for a loopback peer"])
    }

    static func problems(in source: String) -> [String] {
        var problems: [String] = []
        // The requirement must be set on the parameters before the listener is built from them.
        let start = source.range(of: "func start() {").map { String(source[$0.upperBound...]) } ?? ""
        let beforeListener = start.components(separatedBy: "NWListener(using: params").first ?? ""
        if !beforeListener.contains("params.requiredInterfaceType = .loopback") {
            problems.append("the RPC listener is not limited to loopback")
        }
        if !source.contains("guard isLoopback(endpoint: nwConnection.endpoint) else {") {
            problems.append("new connections are not checked for a loopback peer")
        }
        return problems
    }
}
