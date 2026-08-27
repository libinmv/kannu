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
import os

/// Keeps the Mac awake, in one of two user-selectable modes:
///
/// - **Manual** (`caffeinateEnabled`): plain caffeinate — while the notch switch is on, a
///   system-sleep assertion is held unconditionally until it is switched off or the app quits.
/// - **Smart** (`smartCaffeinate`): the assertion is held automatically while at least one
///   visible agent session is in an active run (thinking / executing / awaiting input — the
///   same definition the traffic light uses) and released the moment every run stops. While
///   smart mode is on, the manual switch is hidden from the notch and its value is ignored.
///
/// Only *idle system* sleep is prevented (same as `caffeinate -i`): the display may still
/// sleep, and closing the lid still sleeps the machine — assertions never override forced sleep.
///
/// Concurrency: all three inputs (two Defaults keys, the agent session list) are treated as
/// bare wake-up signals; no payload is ever captured. `reconcile()` re-reads every piece of
/// live state on the main actor at execution time, so a burst of events converges on the
/// current truth no matter how the queued tasks interleave, and the edge guard in
/// `setKeepingAwake` makes each pass idempotent. The IOPM calls are synchronous and there is
/// no suspension point inside a transition, so two transitions can never overlap.
@MainActor
final class CaffeinateManager: ObservableObject {
    static let shared = CaffeinateManager()

    private static let log = os.Logger(subsystem: "com.kannu.app", category: "Caffeinate")

    /// True while the IOPM assertion is actually held. Deliberately reports the assertion
    /// truth rather than any toggle position: if the create call ever fails, the cup icon
    /// shows off instead of lying, and the next event retries.
    @Published private(set) var isKeepingAwake = false

    private var assertionID: IOPMAssertionID = 0
    /// Which mode's reason string the held assertion carries; nil when not held. Tracked so a
    /// manual↔smart flip while held refreshes the assertion instead of leaving `pmset -g
    /// assertions` reporting the wrong mode.
    private var heldModeIsSmart: Bool?
    /// One bounded retry after a failed assertion create. Manual mode has no other event
    /// source, so without this a rare IOPM failure left the switch ON with no assertion forever.
    private var retryTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        Defaults.publisher(.caffeinateEnabled, options: [])
            .sink { [weak self] _ in
                Task { @MainActor in self?.reconcile(trigger: "manual toggle") }
            }
            .store(in: &cancellables)

        Defaults.publisher(.smartCaffeinate, options: [])
            .sink { [weak self] _ in
                Task { @MainActor in self?.reconcile(trigger: "smart toggle") }
            }
            .store(in: &cancellables)

        // Every caffeinate control lives inside the agent feature's UI; when the feature goes
        // off, holding an assertion with zero visible controls would strand the user.
        Defaults.publisher(.enableAgentStatusFeature, options: [])
            .sink { [weak self] _ in
                Task { @MainActor in self?.reconcile(trigger: "feature toggle") }
            }
            .store(in: &cancellables)

        CursorAgentStatusMonitor.shared.$sessions
            .sink { [weak self] _ in
                Task { @MainActor in self?.reconcile(trigger: "sessions") }
            }
            .store(in: &cancellables)

        Self.log.notice("init: manual=\(Defaults[.caffeinateEnabled]) smart=\(Defaults[.smartCaffeinate])")
        reconcile(trigger: "init")
    }

    deinit {
        // The singleton never deinits in practice; belt-and-braces. The OS also releases
        // assertions automatically when the process exits.
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
    }

    private func reconcile(trigger: String) {
        retryTask?.cancel()
        retryTask = nil

        let smart = Defaults[.smartCaffeinate]
        let featureEnabled = Defaults[.enableAgentStatusFeature]
        let hasActiveVisibleSession = CursorAgentStatusMonitor.shared.sessions.contains {
            $0.isVisible && !AgentTrafficLightMapper.isSimulationSession($0) && $0.displayState.isActiveRun
        }
        let shouldHold = AgentTrafficLightMapper.shouldKeepAwake(
            smartEnabled: smart,
            manualEnabled: Defaults[.caffeinateEnabled],
            featureEnabled: featureEnabled,
            hasActiveVisibleSession: hasActiveVisibleSession
        )
        // Log before the edge guard so a wrong read is never silent.
        if shouldHold != isKeepingAwake {
            Self.log.notice("reconcile(\(trigger, privacy: .public)): smart=\(smart) feature=\(featureEnabled) → shouldHold=\(shouldHold)")
        }
        setKeepingAwake(shouldHold, smart: smart && featureEnabled)
    }

    private func setKeepingAwake(_ shouldHold: Bool, smart: Bool) {
        // A manual↔smart flip while held would otherwise short-circuit at the edge guard and
        // leave the assertion carrying the old mode's reason string; refresh it so pmset
        // diagnostics report the mode actually in force. The recreate gap is microseconds —
        // far below powerd's decision timescale.
        if shouldHold, isKeepingAwake, heldModeIsSmart != smart {
            releaseAssertion()
        }

        guard shouldHold != isKeepingAwake else { return }

        if shouldHold {
            var id: IOPMAssertionID = 0
            let reason = smart
                ? "Kannu — keeping the Mac awake while AI agents run"
                : "Kannu — keeping the Mac awake"
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id
            )
            guard result == kIOReturnSuccess else {
                Self.log.error("failed to create sleep assertion (\(result)); retrying in 5s")
                scheduleRetry()
                return
            }
            assertionID = id
            heldModeIsSmart = smart
            isKeepingAwake = true
            Self.log.notice("☕ holding system-sleep assertion (\(smart ? "smart" : "manual", privacy: .public))")
        } else {
            releaseAssertion()
            isKeepingAwake = false
            Self.log.notice("💤 released system-sleep assertion")
        }
    }

    private func releaseAssertion() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        heldModeIsSmart = nil
    }

    /// Manual mode has no periodic event source, so a failed create must arm its own retry —
    /// otherwise the switch shows ON while the Mac can sleep, forever. One bounded attempt;
    /// each retry runs a full reconcile so it re-reads the current truth rather than blindly
    /// re-creating, and any real event cancels it first.
    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.retryTask = nil
            self?.reconcile(trigger: "retry")
        }
    }
}
