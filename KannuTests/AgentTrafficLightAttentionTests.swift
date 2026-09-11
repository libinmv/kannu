//
//  AgentTrafficLightAttentionTests.swift
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

/// The traffic light's timing and look, pinned so a change in how it is drawn cannot change what
/// people see.
final class AgentTrafficLightAttentionTests: XCTestCase {
    func testThePulseLooksAsItAlwaysHas() {
        XCTAssertEqual(TrafficLightPulseSpec.scale, 1.3)
        XCTAssertEqual(TrafficLightPulseSpec.opacity, 0.5)
        XCTAssertEqual(TrafficLightPulseSpec.halfPeriod, 0.7)
        XCTAssertEqual(TrafficLightPulseSpec.settleDuration, 0.15)
        XCTAssertLessThanOrEqual(TrafficLightPulseSpec.preferredFrameRate, 30, "a breath does not need 120 frames a second")
        XCTAssertGreaterThanOrEqual(TrafficLightPulseSpec.minimumFrameRate, 15)
    }
}
