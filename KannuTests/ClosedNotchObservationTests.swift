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

/// Pins the closed notch's observation shape (docs/REGRESSIONS.md entry 10, 2026-09-17 addendum).
/// `CursorAgentStatusMonitor` publishes `sessions` on every hook write — up to ~20 Hz under a
/// busy agent — so a view that observes the whole monitor re-renders that often whether or not
/// it reads the list. `ContentView` (a ~3,300-line body) doing exactly that measured 38 % CPU on
/// a Release build. It observes the narrow `AgentTrafficLightProjection` instead; only leaf
/// views that genuinely render the session list observe the monitor.
final class ClosedNotchObservationTests: XCTestCase {

    /// The views allowed to observe the whole monitor: leaves that render session data, and
    /// surfaces that exist to show live rows.
    private static let allowedObservers: Set<String> = [
        "Kannu/components/AgentStatus/AgentTrafficLightLiveActivity.swift",  // AgentTrafficLightIndicator, the leaf
        "Kannu/components/AgentStatus/NotchAgentStatusView.swift",           // the open panel's list
        "Kannu/components/Notch/NotchLLMUsageView.swift",                    // usage tab
        "Kannu/components/Settings/SettingsView.swift",                      // style preview (6d6a826 pattern)
    ]

    func testOnlyLeafViewsObserveTheWholeMonitor() {
        let sources = Self.appSources()
        XCTAssertGreaterThan(sources.count, 100, "the scan read too few files — fix appSources()")
        for (path, text) in sources {
            let count = Self.monitorObserverCount(in: text)
            if Self.allowedObservers.contains(path) {
                XCTAssertGreaterThan(count, 0, "\(path): pinned as a monitor observer but no longer is — update the allowlist")
                continue
            }
            XCTAssertEqual(count, 0, """
            \(path): observes CursorAgentStatusMonitor wholesale. The monitor publishes on every \
            hook write; observe AgentTrafficLightProjection for the light, or justify the leaf \
            here (docs/REGRESSIONS.md entry 10).
            """)
        }
    }

    func testContentViewObservesTheProjectionAndConsumesThroughTheMonitor() throws {
        let text = try XCTUnwrap(Self.appSources()["Kannu/ContentView.swift"])
        XCTAssertEqual(Self.monitorObserverCount(in: text), 0)
        XCTAssertTrue(text.contains("@ObservedObject private var agentLight = CursorAgentStatusMonitor.shared.projection"))
        // Entry 10: the latch keeps exactly one consumer, and it lives here.
        XCTAssertEqual(text.components(separatedBy: "consumeActivityPulseWasHeartbeatOnly").count - 1, 1)
    }

    /// The projection is a mirror: only the monitor's own file writes it.
    func testOnlyTheMonitorWritesTheProjection() {
        for (path, text) in Self.appSources() where path != "Kannu/managers/AgentStatus/CursorAgentStatusMonitor.swift" {
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                XCTAssertFalse(line.contains("projection.trafficLightState =")
                               || line.contains("projection.shouldShowTrafficLight =")
                               || line.contains("projection.activityPulse ="),
                               "\(path): writes the projection — only the monitor's didSets may (it is a mirror, not a second truth)")
            }
        }
    }

    // MARK: - Scanner self-tests

    func testTheScannerCatchesAPlantedObserver() {
        XCTAssertEqual(Self.monitorObserverCount(in: "@ObservedObject var m = CursorAgentStatusMonitor.shared"), 1)
        XCTAssertEqual(Self.monitorObserverCount(in: "@ObservedObject private var monitor: CursorAgentStatusMonitor"), 1)
        XCTAssertEqual(Self.monitorObserverCount(in: """
        @StateObject var m = CursorAgentStatusMonitor.shared
        """), 1)
        // The cures and mere references are not observers.
        XCTAssertEqual(Self.monitorObserverCount(in: "private let agentStatusMonitor = CursorAgentStatusMonitor.shared"), 0)
        XCTAssertEqual(Self.monitorObserverCount(in: "@ObservedObject private var agentLight = CursorAgentStatusMonitor.shared.projection"), 0)
        XCTAssertEqual(Self.monitorObserverCount(in: "// @ObservedObject var m = CursorAgentStatusMonitor.shared"), 0)
    }

    // MARK: - Plumbing

    private static let observerPattern = try! NSRegularExpression(
        pattern: #"@(?:ObservedObject|StateObject)[^\n]*CursorAgentStatusMonitor(?!\.shared\.projection)"#)

    private static func monitorObserverCount(in text: String) -> Int {
        var count = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
            let string = String(line)
            count += observerPattern.numberOfMatches(in: string, range: NSRange(string.startIndex..., in: string))
        }
        return count
    }

    private static func appSources() -> [String: String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let kannu = root.appendingPathComponent("Kannu")
        var out: [String: String] = [:]
        guard let walker = FileManager.default.enumerator(at: kannu, includingPropertiesForKeys: nil) else { return out }
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            out[relative] = try? String(contentsOf: url, encoding: .utf8)
        }
        return out.compactMapValues { $0 }
    }
}
