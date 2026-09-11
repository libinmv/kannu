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

/// Each visible Claude card's request tokens (`ClaudeTurnTokenReader`), read on a utility queue.
///
/// Its own ObservableObject, not a field of the sessions: the numbers change with every assistant
/// message, and on the sessions they would re-render the whole notch (ContentView observes the
/// monitor) and bump the reveal pulse (docs/REGRESSIONS.md entries 10 and 11). Transcripts can be
/// 100+ MB; nothing here touches one on the main actor. Reads token counts only — never content —
/// and logs nothing.
@MainActor
final class ClaudeTurnTokenFollower: ObservableObject {
    static let shared = ClaudeTurnTokenFollower()

    /// By conversation id. A card shows an entry only when it belongs to its current turn.
    @Published private(set) var tokens: [String: TurnTokens] = [:]

    /// At most one pass a second while nothing changed; a new turn is read at once.
    static let minimumInterval: TimeInterval = 1
    /// While a big turn is still being caught up, the next pass follows almost at once.
    static let catchUpDelay: TimeInterval = 0.05

    private let reader: ClaudeTurnTokenReader
    private let home: String
    private let queue = DispatchQueue(label: "com.kannu.turn-tokens", qos: .utility)
    private var requests: [ClaudeTurnTokenRequest] = []
    private var generation = 0
    private var passInFlight = false
    private var passQueued = false
    private var lastPassStartedAt = Date.distantPast
    private var wakeTask: Task<Void, Never>?

    private init() {
        home = FileManager.default.homeDirectoryForCurrentUser.path
        reader = ClaudeTurnTokenReader(projectsRoot: home + "/.claude/projects")
    }

    /// Called after every rescan with the published sessions. Builds requests only; the reading
    /// happens on the queue, coalesced.
    func follow(_ sessions: [AgentSessionStatus]) {
        let next = ClaudeTurnTokenRequest.requests(from: sessions, home: home)
        let changed = next != requests
        requests = next
        guard !next.isEmpty else {
            if !tokens.isEmpty { tokens = [:] }
            return
        }
        schedulePass(after: changed ? 0 : max(0, Self.minimumInterval - Date().timeIntervalSince(lastPassStartedAt)))
    }

    /// The monitor stopped: forget everything, and let no pass that is still running publish.
    func reset() {
        generation &+= 1
        wakeTask?.cancel()
        wakeTask = nil
        requests = []
        passQueued = false
        if !tokens.isEmpty { tokens = [:] }
        let reader = self.reader
        queue.async { reader.reset() }
    }

    private func schedulePass(after delay: TimeInterval) {
        if passInFlight {
            passQueued = true
            return
        }
        if delay <= 0 {
            wakeTask?.cancel()
            wakeTask = nil
            runPass()
            return
        }
        guard wakeTask == nil else { return }
        wakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.wakeTask = nil
            self.runPass()
        }
    }

    private func runPass() {
        guard !requests.isEmpty, !passInFlight else { return }
        passInFlight = true
        passQueued = false
        lastPassStartedAt = Date()
        let requests = self.requests
        let generation = self.generation
        let reader = self.reader
        queue.async { [weak self] in
            let pass = reader.pass(requests, now: Date())
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.passInFlight = false
                    let current = generation == self.generation
                    if current { self.publish(pass) }
                    if current, pass.behind {
                        self.schedulePass(after: Self.catchUpDelay)
                    } else if self.passQueued {
                        self.schedulePass(after: max(0, Self.minimumInterval - Date().timeIntervalSince(self.lastPassStartedAt)))
                    }
                }
            }
        }
    }

    /// Complete totals replace what was shown; a chat still being caught up keeps its last numbers
    /// (the card checks they belong to its turn); chats no longer requested are dropped.
    private func publish(_ pass: ClaudeTurnTokenReader.Pass) {
        let wanted = Set(requests.map(\.conversationID))
        var next = tokens.filter { wanted.contains($0.key) }
        for (conversationID, total) in pass.tokens where wanted.contains(conversationID) {
            next[conversationID] = total
        }
        if next != tokens { tokens = next }
    }
}
