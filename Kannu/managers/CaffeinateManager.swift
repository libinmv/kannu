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

import Combine
import Defaults
import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake while AI agents are actually working.
///
/// Deliberately auto-scoped rather than a plain caffeinate clone: the assertion is held only
/// while the toggle is armed AND at least one visible agent session is in an active run
/// (thinking / executing / awaiting input — the same definition the traffic light uses).
/// The moment every run stops, the assertion is released, so an armed toggle forgotten for a
/// week costs nothing. Only *system* sleep is prevented; the display may still sleep — agents
/// keep running behind a dark screen.
@MainActor
final class CaffeinateManager: ObservableObject {
    static let shared = CaffeinateManager()

    /// True while the IOPM assertion is actually held (armed AND an agent run is active).
    /// The UI uses this to distinguish "holding" from merely "armed".
    @Published private(set) var isKeepingAwake = false

    private var assertionID: IOPMAssertionID = 0
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        // Both inputs funnel into the same recompute: the user arming/disarming the toggle,
        // and any change to the session list (state transitions, sessions appearing/expiring).
        Defaults.publisher(.caffeinateWhileAgentsRun, options: [])
            .sink { [weak self] _ in
                Task { @MainActor in self?.reevaluate() }
            }
            .store(in: &cancellables)

        CursorAgentStatusMonitor.shared.$sessions
            .sink { [weak self] sessions in
                Task { @MainActor in self?.reevaluate(sessions: sessions) }
            }
            .store(in: &cancellables)

        reevaluate()
    }

    deinit {
        // Actor isolation doesn't apply in deinit; release the raw assertion directly.
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
    }

    private func reevaluate(sessions: [AgentSessionStatus]? = nil) {
        let current = sessions ?? CursorAgentStatusMonitor.shared.sessions
        let anyActiveRun = current.contains {
            $0.isVisible && !AgentTrafficLightMapper.isSimulationSession($0) && $0.displayState.isActiveRun
        }
        setKeepingAwake(Defaults[.caffeinateWhileAgentsRun] && anyActiveRun)
    }

    private func setKeepingAwake(_ shouldHold: Bool) {
        guard shouldHold != isKeepingAwake else { return }

        if shouldHold {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Kannu — keeping the Mac awake while AI agents run" as CFString,
                &id
            )
            guard result == kIOReturnSuccess else {
                print("CaffeinateManager: ❌ failed to create sleep assertion (\(result))")
                return
            }
            assertionID = id
            isKeepingAwake = true
            print("CaffeinateManager: ☕ holding system-sleep assertion")
        } else {
            if assertionID != 0 {
                IOPMAssertionRelease(assertionID)
                assertionID = 0
            }
            isKeepingAwake = false
            print("CaffeinateManager: 💤 released system-sleep assertion")
        }
    }
}
