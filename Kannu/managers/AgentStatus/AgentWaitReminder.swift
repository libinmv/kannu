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

import Foundation

/// "Still waiting on you": which yellow sessions have waited past the threshold and have not been
/// reminded about this wait yet.
///
/// A wait starts when a session is first seen yellow and keeps that start until the session
/// leaves yellow — so a Cursor transcript yellow whose timestamp moves with activity is still one
/// wait, one reminder. Leaving yellow and coming back is a new wait. Waits already overdue on the
/// first look after launch are marked, not pushed, so a relaunch never sends a burst.
struct AgentWaitReminder: Equatable {
    struct Due: Equatable {
        let sessionID: String
        let provider: String
        let minutes: Int
    }

    private(set) var waits: [String: Date] = [:]
    private(set) var reminded: Set<String> = []

    /// `threshold` nil means reminders are off: everything is forgotten.
    mutating func update(_ sessions: [AgentSessionStatus], now: Date, threshold: TimeInterval?,
                         suppressOverdue: Bool) -> [Due] {
        guard let threshold, threshold > 0 else {
            waits = [:]
            reminded = []
            return []
        }
        var current: [String: Date] = [:]
        var providers: [String: String] = [:]
        for session in sessions where session.isVisible && session.displayState == .awaitingInput
            && !AgentTrafficLightMapper.isSimulationSession(session) {
            current[session.id] = waits[session.id] ?? min(session.updatedAt, now)
            providers[session.id] = session.provider
        }
        waits = current
        reminded.formIntersection(Set(current.map { Self.key($0.key, $0.value) }))
        var due: [Due] = []
        for (id, since) in current where now.timeIntervalSince(since) >= threshold {
            let key = Self.key(id, since)
            guard !reminded.contains(key) else { continue }
            reminded.insert(key)
            if suppressOverdue { continue }
            due.append(Due(sessionID: id, provider: providers[id] ?? "", minutes: Int(now.timeIntervalSince(since) / 60)))
        }
        return due.sorted { $0.sessionID < $1.sessionID }
    }

    /// When the next pending reminder falls due; nil when none is pending.
    func nextCheck(now: Date, threshold: TimeInterval) -> Date? {
        waits.filter { !reminded.contains(Self.key($0.key, $0.value)) }
            .map { $0.value.addingTimeInterval(threshold) }
            .filter { $0 > now }
            .min()
    }

    private static func key(_ id: String, _ since: Date) -> String {
        id + "|" + String(Int(since.timeIntervalSince1970))
    }
}
