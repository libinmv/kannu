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

/// One ADR Detection verdict on one finished session, as the adapter reports it.
struct ADRSessionAnalysis: Codable, Equatable, Identifiable {
    var id: String { conversationID }
    let conversationID: String
    let chatName: String?
    let date: Date
    let isMalicious: Bool
    let confidence: Double
    let tactic: String?
    let explanation: String
    let threatMessages: Int?
    let totalMessages: Int?
    let method: String?
    let modelUsed: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let costUSD: Double?
    let triageEnabled: Bool
    let reportPath: String?

    enum ParseError: Error, Equatable { case notAVerdict, adapterError(String) }

    /// The adapter's stdout JSON (`schema` 1). An `error` key is the adapter saying why it
    /// could not run; that is surfaced, never turned into a "clean" verdict.
    static func parse(_ data: Data, conversationID: String, chatName: String?, reportPath: String?, now: Date = Date()) throws -> ADRSessionAnalysis {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["schema"] as? NSNumber)?.intValue == 1 else { throw ParseError.notAVerdict }
        if let error = json["error"] as? String { throw ParseError.adapterError(error) }
        guard let malicious = json["is_malicious"] as? Bool else { throw ParseError.notAVerdict }
        func int(_ key: String) -> Int? { (json[key] as? NSNumber)?.intValue }
        func double(_ key: String) -> Double? { (json[key] as? NSNumber)?.doubleValue }
        return ADRSessionAnalysis(
            conversationID: conversationID,
            chatName: chatName,
            date: now,
            isMalicious: malicious,
            confidence: min(1, max(0, double("confidence") ?? 0)),
            tactic: (json["tactic"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            explanation: (json["explanation"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            threatMessages: int("threat_messages"),
            totalMessages: int("total_messages"),
            method: json["method"] as? String,
            modelUsed: json["model_used"] as? String,
            inputTokens: int("input_tokens"),
            outputTokens: int("output_tokens"),
            costUSD: double("cost_usd"),
            triageEnabled: (json["triage"] as? String) == "on",
            reportPath: reportPath
        )
    }

    /// ADR's five tactics as sentences; anything else is prettified.
    static func title(forTactic tactic: String?) -> String {
        switch tactic?.lowercased() {
        case "initial_compromise": return String(localized: "Initial compromise attempt in this chat")
        case "permission_abuse": return String(localized: "Permission abuse in this chat")
        case "security_control_bypass": return String(localized: "Security control bypass in this chat")
        case "reasoning_data_manipulation": return String(localized: "Prompt or data manipulation in this chat")
        case "operational_impact": return String(localized: "Harmful operational impact in this chat")
        case .some(let other) where !other.isEmpty:
            let words = other.split(separator: "_").map(String.init)
            return (words.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "") + " " + words.dropFirst().joined(separator: " ") + String(localized: " in this chat")
        default: return String(localized: "Malicious activity in this chat")
        }
    }

    /// Short verdict for a card: "clean · 0.08", "permission abuse · 0.91".
    var shortLabel: String {
        let score = String(format: "%.2f", confidence)
        if !isMalicious { return String(localized: "clean · \(score)") }
        let what = (tactic ?? "malicious").replacingOccurrences(of: "_", with: " ")
        return "\(what) · \(score)"
    }

    /// A malicious verdict becomes a finding — high when the reasoning agent is confident
    /// (ADR's own triage threshold), medium otherwise. A clean verdict is a record, not a finding.
    static let rulePrefix = "detection_"

    func finding(existingFirstSeen: Date? = nil) -> AgentSecurityFinding? {
        guard isMalicious else { return nil }
        let rule = Self.rulePrefix + (tactic ?? "malicious_session")
        var evidence: [String] = [String(format: "confidence %.2f", confidence)]
        if let threat = threatMessages, let total = totalMessages { evidence.append("\(threat) of \(total) messages flagged") }
        if let model = modelUsed, !model.isEmpty { evidence.append("model \(model)") }
        let summary = explanation.isEmpty ? String(localized: "ADR Detection judged this chat malicious.") : String(explanation.prefix(240))
        return AgentSecurityFinding(
            id: AgentSecurityFinding.stableID(source: .detection, rule: rule, subject: conversationID, evidence: evidence),
            source: .detection,
            rule: rule,
            severity: confidence >= 0.8 ? .high : .medium,
            title: Self.title(forTactic: tactic),
            summary: summary,
            evidence: evidence,
            assetName: chatName,
            assetPath: reportPath,
            sessionID: conversationID,
            firstSeen: existingFirstSeen ?? date,
            revealPath: reportPath
        )
    }
}
