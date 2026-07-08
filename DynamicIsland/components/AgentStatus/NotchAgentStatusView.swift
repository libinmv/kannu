import SwiftUI

struct NotchAgentStatusView: View {
    @ObservedObject private var monitor = CursorAgentStatusMonitor.shared

    private var visibleSessions: [AgentSessionStatus] {
        monitor.sessions.filter(\.isVisible)
    }

    private var allSessions: [AgentSessionStatus] {
        monitor.sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var primarySession: AgentSessionStatus? {
        visibleSessions.max { lhs, rhs in
            if lhs.displayState != rhs.displayState {
                return lhs.displayState < rhs.displayState
            }
            return lhs.updatedAt < rhs.updatedAt
        }
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

                if allSessions.count > 1 {
                    Text("All sessions")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(allSessions) { session in
                        sessionRow(session, isPrimary: session.id == primarySession?.id)
                    }
                } else if allSessions.count == 1, primarySession == nil {
                    ForEach(allSessions) { session in
                        sessionRow(session, isPrimary: false)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func primaryCard(_ session: AgentSessionStatus) -> some View {
        HStack(spacing: 12) {
            AgentProviderIconView(source: .init(rawProvider: session.provider), size: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.providerLabel)
                    .font(.headline)
                Text(session.displayState.displayName)
                    .font(.subheadline)
                    .foregroundStyle(stateColor(session.displayState))
                AgentChatNameLabel(
                    text: session.displayChatName,
                    font: .caption2,
                    textColor: .secondary,
                    marqueeWidth: 180
                )
                Text(session.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            stateBadge(session.displayState, large: true)
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func sessionRow(_ session: AgentSessionStatus, isPrimary: Bool) -> some View {
        HStack(spacing: 10) {
            AgentProviderIconView(source: .init(rawProvider: session.provider), size: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.providerLabel)
                        .font(.caption.weight(.semibold))
                    if isPrimary {
                        Text("Latest")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                }
                Text(session.displayState.displayName)
                    .font(.caption2)
                    .foregroundStyle(session.isVisible ? stateColor(session.displayState) : .secondary)
                AgentChatNameLabel(
                    text: session.displayChatName,
                    marqueeWidth: 140
                )
                Text(session.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            stateBadge(session.displayState, large: false)
        }
        .padding(10)
        .opacity(session.isVisible ? 1 : 0.55)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
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
}
