import Defaults
import SwiftUI

struct AgentTrafficLightIndicator: View {
    @ObservedObject var agentStatusMonitor = CursorAgentStatusMonitor.shared
    @Default(.showAgentStoppedIndicator) private var showAgentStoppedIndicator
    /// Keyed by session ID — records when a session first became non-active (stopped/inactive).
    /// Used to drive the 30-second "linger then disappear" window in multi-agent mode.
    @State private var completionTimestamps: [String: Date] = [:]

    private static let completionWindow: TimeInterval = 30
    /// How long a just-finished session keeps pulsing at full brightness before settling into
    /// the dim, static linger state. Without this, completion was a silent drop straight to
    /// 35% opacity — easy to miss entirely if you weren't already looking.
    private static let attentionWindow: TimeInterval = 4

    private func isRecentlyCompleted(_ sessionID: String, at now: Date) -> Bool {
        guard let ts = completionTimestamps[sessionID] else { return false }
        return now.timeIntervalSince(ts) < Self.attentionWindow
    }

    private var activeState: AgentTrafficLightState {
        if agentStatusMonitor.trafficLightState == .inactive && showAgentStoppedIndicator {
            return .stopped
        }
        return agentStatusMonitor.trafficLightState
    }

    private var primarySession: AgentSessionStatus? {
        let visible = agentStatusMonitor.sessions.filter { $0.isVisible && !AgentTrafficLightMapper.isSimulationSession($0) }
        return AgentTrafficLightMapper.primarySession(from: visible)
    }

    /// All non-simulation visible sessions, newest-first.
    private var visibleSessions: [AgentSessionStatus] {
        agentStatusMonitor.sessions
            .filter { $0.isVisible && !AgentTrafficLightMapper.isSimulationSession($0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Sessions to render: active ones + recently-stopped ones still within the 30-second linger window.
    private func displaySessions(at now: Date) -> [AgentSessionStatus] {
        visibleSessions.filter { session in
            if session.displayState.isActiveRun { return true }
            guard let ts = completionTimestamps[session.id] else { return false }
            return now.timeIntervalSince(ts) < Self.completionWindow
        }
    }

    var body: some View {
        // TimelineView ticks every second so the 30-second linger window is evaluated
        // continuously. In single-agent mode the overhead is negligible.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let toDisplay = displaySessions(at: context.date)
            if toDisplay.count >= 2 {
                multiAgentRow(toDisplay, now: context.date)
            } else {
                singleAgentRow(now: context.date)
            }
        }
        // Track when sessions transition out of an active run so we can start their linger clocks.
        .onChange(of: visibleSessions) { _, newSessions in
            let now = Date()
            // Drop timestamps for sessions that have left the visible list entirely.
            let newIDs = Set(newSessions.map(\.id))
            completionTimestamps = completionTimestamps.filter { newIDs.contains($0.key) }
            for session in newSessions {
                if session.displayState.isActiveRun {
                    // Back to active — clear any stale completion stamp.
                    completionTimestamps.removeValue(forKey: session.id)
                } else if completionTimestamps[session.id] == nil {
                    // First time we see this session as non-active; start the linger clock.
                    completionTimestamps[session.id] = now
                }
            }
        }
    }

    // MARK: - Single agent

    @ViewBuilder
    private func singleAgentRow(now: Date) -> some View {
        // Red already means "done" here (unchanged) — what was missing was any transition
        // moment: it used to jump straight to a static dot with no pulse at all. Give it a
        // few seconds of pulsing right after completion so finishing is noticeable, then let
        // it settle to the existing static red.
        let justCompleted = primarySession.map { isRecentlyCompleted($0.id, at: now) } ?? false
        HStack(spacing: 6) {
            if let primarySession {
                AgentProviderIconView(source: .init(rawProvider: primarySession.provider), size: 14)
                Text(primarySession.providerLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            trafficLightCircle(
                color: .red,
                isActive: activeState.showsRedTrafficLight,
                shouldPulse: activeState.showsRedTrafficLight && justCompleted
            )
            trafficLightCircle(
                color: .yellow,
                isActive: activeState.showsYellowTrafficLight,
                shouldPulse: activeState.showsYellowTrafficLight
            )
            trafficLightCircle(
                color: .green,
                isActive: activeState.showsGreenTrafficLight,
                shouldPulse: activeState.showsGreenTrafficLight
            )
        }
    }

    // MARK: - Multi-agent: icon-only, equally divided across the notch width

    @ViewBuilder
    private func multiAgentRow(_ sessions: [AgentSessionStatus], now: Date) -> some View {
        HStack(spacing: 0) {
            ForEach(sessions) { session in
                let isActive = session.displayState.isActiveRun
                let justCompleted = !isActive && isRecentlyCompleted(session.id, at: now)
                // Active, or just finished: full brightness + pulse, so completion actually
                // gets noticed. Only settles to dimmed/static once the attention window passes.
                let isAttentionGrabbing = isActive || justCompleted
                AgentProviderIconView(source: .init(rawProvider: session.provider), size: 14)
                    .opacity(isAttentionGrabbing ? 1.0 : 0.35)
                    .modifier(ConditionalPulseModifier(isEnabled: isAttentionGrabbing))
                    // Each icon takes an equal slice of the available notch width.
                    .frame(maxWidth: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.75)))
            }
        }
        // Animate icons in/out as sessions appear and expire.
        .animation(.easeInOut(duration: 0.3), value: sessions.map(\.id))
    }

    // MARK: - Helpers

    @ViewBuilder
    private func trafficLightCircle(color: Color, isActive: Bool, shouldPulse: Bool) -> some View {
        Circle()
            .fill(color.opacity(isActive ? 1.0 : 0.2))
            .frame(width: 10, height: 10)
            .modifier(ConditionalPulseModifier(isEnabled: isActive && shouldPulse))
    }
}

struct AgentTrafficLightLiveActivity: View {
    @EnvironmentObject var vm: KannuViewModel
    @ObservedObject private var monitor = CursorAgentStatusMonitor.shared

    let isHovering: Bool
    let gestureProgress: CGFloat

    /// Only supplied when rendering on a display with a physical notch.
    /// Non-notch displays receive nil and retain their existing sizing.
    var physicalNotchExpandedHeight: CGFloat? = nil

    /// Must remain zero on non-notch displays.
    var trafficLightVerticalOffset: CGFloat = 0

    var onHoverAgentCenter: ((Bool) -> Void)? = nil

    private var notchContentHeight: CGFloat {
        let normalHeight = max(
            0,
            vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12)
        )

        guard let physicalNotchExpandedHeight else {
            return normalHeight
        }

        return max(normalHeight, physicalNotchExpandedHeight)
    }

    private var outerHeight: CGFloat {
        let normalHeight = max(
            0,
            vm.effectiveClosedNotchHeight + (isHovering ? 8 : 0)
        )

        guard let physicalNotchExpandedHeight else {
            return normalHeight
        }

        return max(
            normalHeight,
            physicalNotchExpandedHeight + (isHovering ? 8 : 0)
        )
    }

    private var contentWidth: CGFloat {
        max(
            0,
            vm.closedNotchSize.width + (isHovering ? 8 : 0)
        )
    }

    var body: some View {
        AgentTrafficLightIndicator()
            .offset(y: trafficLightVerticalOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(width: contentWidth, height: notchContentHeight)
            .frame(height: outerHeight)
            .contentShape(Rectangle())
            .onHover { hovering in
                onHoverAgentCenter?(hovering)
            }
    }
}

private struct ConditionalPulseModifier: ViewModifier {
    let isEnabled: Bool
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            // Previously 1.0 → 1.15 scale / 1.0 → 0.75 opacity — reported as too subtle to
            // read as "breathing" at the small icon sizes used here. Widened the swing.
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.5 : 1.0)
            // Using .animation(value:) instead of withAnimation so that flipping
            // isPulsing back to false replaces the repeatForever animation and
            // actually stops the pulse (withAnimation-started repeatForever
            // animations are not cancelled by a plain state write).
            .animation(
                isPulsing
                    ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.15),
                value: isPulsing
            )
            .onAppear { isPulsing = isEnabled }
            .onChange(of: isEnabled) { _, enabled in
                isPulsing = enabled
            }
    }
}
