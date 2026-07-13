import Foundation
import SwiftUI

struct NotchAgentStatusView: View {
    @EnvironmentObject private var vm: KannuViewModel
    @ObservedObject private var monitor = CursorAgentStatusMonitor.shared
    @State private var isSuppressingScrollGesture = false
    private let scrollSuppressionToken = UUID()

    private var dedupedSessions: [AgentSessionStatus] {
        deduplicateLatestSessions(monitor.sessions)
    }

    private var visibleSessions: [AgentSessionStatus] {
        dedupedSessions.filter(\.isVisible)
    }

    private var allSessions: [AgentSessionStatus] {
        visibleSessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var recentChats: [AgentSessionStatus] {
        guard let primaryID = primarySession?.id else { return allSessions }
        return allSessions.filter { $0.id != primaryID }
    }

    private var primarySession: AgentSessionStatus? {
        AgentTrafficLightMapper.primarySession(from: visibleSessions)
    }

    private func deduplicateLatestSessions(_ sessions: [AgentSessionStatus]) -> [AgentSessionStatus] {
        var latestByConversationID: [String: AgentSessionStatus] = [:]
        for session in sessions {
            guard let existing = latestByConversationID[session.conversationID] else {
                latestByConversationID[session.conversationID] = session
                continue
            }
            latestByConversationID[session.conversationID] = preferredSession(existing: existing, incoming: session)
        }
        return Array(latestByConversationID.values)
    }

    private func preferredSession(existing: AgentSessionStatus, incoming: AgentSessionStatus) -> AgentSessionStatus {
        if existing.displayState != incoming.displayState {
            return existing.displayState > incoming.displayState ? existing : incoming
        }
        let existingHasReliableTitle = hasReliableChatName(existing.chatName)
        let incomingHasReliableTitle = hasReliableChatName(incoming.chatName)
        if existingHasReliableTitle != incomingHasReliableTitle {
            return incomingHasReliableTitle ? incoming : existing
        }
        return incoming.updatedAt >= existing.updatedAt ? incoming : existing
    }

    private func hasReliableChatName(_ value: String?) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return false }
        return !CursorAgentStatusMonitor.looksLikeToolName(trimmed)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let primary = primarySession {
                    primaryCard(primary)
                } else {
                    Text("No active agent sessions")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                }

                if !recentChats.isEmpty {
                    Text("Recent chats")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(recentChats) { session in
                        sessionRow(session)
                    }
                } else if !allSessions.isEmpty, primarySession == nil {
                    ForEach(allSessions) { session in
                        sessionRow(session)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onHover { hovering in
            updateScrollGestureSuppression(for: hovering)
        }
        .onDisappear {
            updateScrollGestureSuppression(for: false)
        }
    }

    @ViewBuilder
    private func primaryCard(_ session: AgentSessionStatus) -> some View {
        HStack(spacing: 12) {
            AgentProviderIconView(source: .init(rawProvider: session.provider), size: 28)
            VStack(alignment: .leading, spacing: 4) {
                AgentChatNameLabel(
                    text: session.providerLabel,
                    secondarySuffix: session.displayProjectName,
                    maxStaticLength: 18,
                    font: .headline,
                    nsFont: .headline,
                    textColor: .primary,
                    secondaryTextColor: .secondary,
                    marqueeWidth: 220
                )
                statusText(for: session, font: .subheadline)
                AgentChatNameLabel(
                    text: session.displayChatName,
                    font: .caption2,
                    textColor: .secondary,
                    marqueeWidth: 180
                )
            }
            Spacer(minLength: 0)
            stateBadge(session.displayState, large: true)
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func sessionRow(_ session: AgentSessionStatus) -> some View {
        HStack(spacing: 10) {
            AgentProviderIconView(source: .init(rawProvider: session.provider), size: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    AgentChatNameLabel(
                        text: session.providerLabel,
                        secondarySuffix: session.displayProjectName,
                        maxStaticLength: 16,
                        font: .caption.weight(.semibold),
                        nsFont: .caption1,
                        textColor: .primary,
                        secondaryTextColor: .secondary,
                        marqueeWidth: 160
                    )
                }
                statusText(for: session, font: .caption2)
                AgentChatNameLabel(
                    text: session.displayChatName,
                    marqueeWidth: 140
                )
            }
            Spacer(minLength: 0)
            stateBadge(session.displayState, large: false)
        }
        .padding(10)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func statusText(for session: AgentSessionStatus, font: Font) -> some View {
        if session.displayState.isActiveRun, let startedAt = session.executionStartedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                (
                    Text(session.displayState.displayName).foregroundStyle(stateColor(session.displayState))
                    + Text(" " + formattedElapsed(since: startedAt, now: context.date))
                        .foregroundStyle(.secondary)
                )
                .font(font)
                .monospacedDigit()
            }
        } else {
            Text(session.displayState.displayName)
                .font(font)
                .foregroundStyle(stateColor(session.displayState))
        }
    }

    private func formattedElapsed(since start: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(start)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    @ViewBuilder
    private func stateBadge(_ state: AgentTrafficLightState, large: Bool) -> some View {
        let width: CGFloat = large ? 28 : 20
        let height: CGFloat = large ? 36 : 28
        VStack(spacing: 3) {
            Circle()
                .fill(Color.red.opacity(state.showsRedTrafficLight ? 1 : 0.25))
                .frame(width: large ? 8 : 6, height: large ? 8 : 6)
            Circle()
                .fill(Color.yellow.opacity(state.showsYellowTrafficLight ? 1 : 0.25))
                .frame(width: large ? 8 : 6, height: large ? 8 : 6)
            Circle()
                // Green is already exclusive of yellow/red via AgentTrafficLightState.
                .fill(Color.green.opacity(state.showsGreenTrafficLight ? 1 : 0.25))
                .frame(width: large ? 8 : 6, height: large ? 8 : 6)
        }
        .frame(width: width, height: height)
    }

    private func stateColor(_ state: AgentTrafficLightState) -> Color {
        switch state {
        case .executing, .thinking: return .green
        case .awaitingInput: return .yellow
        case .stopped: return .red
        case .inactive: return .secondary
        }
    }

    private func updateScrollGestureSuppression(for hovering: Bool) {
        guard hovering != isSuppressingScrollGesture else { return }
        isSuppressingScrollGesture = hovering
        vm.setScrollGestureSuppression(hovering, token: scrollSuppressionToken)
    }
}
