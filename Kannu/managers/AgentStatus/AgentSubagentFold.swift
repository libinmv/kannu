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

extension AgentTrafficLightMapper {
    /// Claude Code (and Qwen Code) run a subagent's hooks under the subagent's own id; hook v38 writes
    /// the chat it belongs to as `parent_id`. A subagent is part of that chat, never a card of its
    /// own (before v38 each Explore/Plan agent showed as a nameless "Untitled chat"):
    ///
    /// - While the parent's turn is open (working or waiting), the more urgent of the two lights
    ///   shows on the parent's card: a subagent waiting on permission turns it yellow, and the
    ///   parent's own progress cannot hide that prompt.
    /// - Once the parent's turn has ended, a leftover subagent file changes nothing — it used to
    ///   relight the whole light green for up to six minutes after the chat finished.
    /// - With no parent file this scan, a stand-in carries the parent's id; enrichment and the
    ///   reconciler name it from the parent's transcript and process.
    ///
    /// Identity, name, project and locators stay the parent's; extras (sightings, the unattended
    /// flag) ride `carryingExtras` from both sides (docs/REGRESSIONS.md entry 7). Returns the folded
    /// subagent conversation ids so retention does not bring a pre-v38 card back.
    static func foldSubagentHookSessions(_ sessions: [AgentSessionStatus],
                                         parentByKey: [String: String]) -> (sessions: [AgentSessionStatus], folded: Set<String>) {
        guard !parentByKey.isEmpty else { return (sessions, []) }
        var out: [AgentSessionStatus] = []
        var indexByKey: [String: Int] = [:]
        var subagents: [AgentSessionStatus] = []
        for session in sessions {
            if parentByKey[subagentKey(session)] != nil {
                subagents.append(session)
            } else {
                indexByKey[subagentKey(session)] = out.count
                out.append(session)
            }
        }
        var folded = Set<String>()
        for sub in subagents.sorted(by: { $0.updatedAt != $1.updatedAt ? $0.updatedAt < $1.updatedAt : $0.id < $1.id }) {
            guard let parentID = parentByKey[subagentKey(sub)] else { continue }
            folded.insert(sub.conversationID)
            let parentKey = sub.provider.lowercased() + "|" + parentID
            if let index = indexByKey[parentKey] {
                out[index] = folding(sub, into: out[index])
            } else {
                let standIn = AgentSessionStatus(
                    id: "\(sub.provider)-\(parentID)",
                    provider: sub.provider,
                    conversationID: parentID,
                    chatName: nil,
                    projectName: sub.projectName,
                    rawState: sub.rawState,
                    displayState: sub.displayState,
                    updatedAt: sub.updatedAt,
                    isVisible: sub.isVisible,
                    executionStartedAt: sub.executionStartedAt,
                    cwd: sub.cwd,
                    hostPID: nil
                ).carryingExtras(from: sub)
                indexByKey[parentKey] = out.count
                out.append(standIn)
            }
        }
        return (out, folded)
    }

    /// A conversation id as the hook writes it: 1–64 of `[A-Za-z0-9_-]`. The status file is
    /// untrusted input.
    static func isHookConversationID(_ value: String) -> Bool {
        (1...64).contains(value.count) && value.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
    }

    private static func subagentKey(_ session: AgentSessionStatus) -> String {
        session.provider.lowercased() + "|" + session.conversationID
    }

    /// Inside an open turn only a prompt outranks work, and work outranks thinking; a stopped or
    /// inactive subagent never wins.
    private static func turnUrgency(_ state: AgentTrafficLightState) -> Int {
        switch state {
        case .awaitingInput: return 3
        case .executing: return 2
        case .thinking: return 1
        case .stopped, .inactive: return 0
        }
    }

    private static func folding(_ sub: AgentSessionStatus, into parent: AgentSessionStatus) -> AgentSessionStatus {
        let turnOpen = parent.hasActiveRawState || isAwaitingInputRawState(parent.rawState)
        let subWins = turnOpen && sub.isVisible
            && (!parent.isVisible || turnUrgency(sub.displayState) > turnUrgency(parent.displayState))
        guard subWins else { return parent.carryingExtras(from: sub) }
        return AgentSessionStatus(
            id: parent.id,
            provider: parent.provider,
            conversationID: parent.conversationID,
            chatName: parent.chatName,
            projectName: parent.projectName ?? sub.projectName,
            rawState: sub.rawState,
            displayState: sub.displayState,
            updatedAt: sub.updatedAt,
            isVisible: true,
            executionStartedAt: parent.executionStartedAt ?? sub.executionStartedAt,
            cwd: parent.cwd ?? sub.cwd,
            hostPID: parent.hostPID
        ).carryingExtras(from: parent).carryingExtras(from: sub)
    }
}
