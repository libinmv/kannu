import Defaults
import SwiftUI

/// The three-dot (or single-dot) traffic light itself, independent of any live state.
///
/// Shared by the notch indicator and by the Settings / onboarding pickers so a preview can
/// never drift from what the notch actually draws.
struct AgentTrafficLightDots: View {
    let style: AgentTrafficLightStyle
    let state: AgentTrafficLightState
    /// Whether the lit dot should breathe. Previews pass false; the live indicator decides
    /// per-state (red only inside its completion window, yellow/green for as long as they're lit).
    var isPulsing: Bool = false
    var dotSize: CGFloat = 10
    var spacing: CGFloat = 6

    @Default(.agentActiveColor) private var activeColor
    @Default(.agentAwaitingInputColor) private var awaitingColor
    @Default(.agentStoppedColor) private var stoppedColor

    /// The one colour the current state lights up, or nil when nothing is lit (`.inactive`).
    /// The three `shows…TrafficLight` booleans are mutually exclusive by construction.
    private var litColor: Color? {
        state.litPalette(active: activeColor, awaiting: awaitingColor, stopped: stoppedColor)?.color
    }

    var body: some View {
        HStack(spacing: spacing) {
            switch style {
            case .classic:
                dot(stoppedColor.color, isActive: state.showsRedTrafficLight)
                dot(awaitingColor.color, isActive: state.showsYellowTrafficLight)
                dot(activeColor.color, isActive: state.showsGreenTrafficLight)
            case .minimal:
                // Nothing is lit when inactive, and the indicator is hidden in that case
                // anyway — draw nothing rather than inventing a colour.
                if let litColor {
                    dot(litColor, isActive: true)
                }
            }
        }
    }

    @ViewBuilder
    private func dot(_ color: Color, isActive: Bool) -> some View {
        Circle()
            .fill(color.opacity(isActive ? 1.0 : 0.2))
            .frame(width: dotSize, height: dotSize)
            .modifier(ConditionalPulseModifier(isEnabled: isActive && isPulsing))
    }
}

struct AgentTrafficLightIndicator: View {
    @ObservedObject var agentStatusMonitor = CursorAgentStatusMonitor.shared
    @Default(.showAgentStoppedIndicator) private var showAgentStoppedIndicator
    @Default(.agentTrafficLightStyle) private var trafficLightStyle
    /// Keyed by session ID — records when a session first became non-active (stopped/inactive),
    /// so a just-finished run can pulse red briefly before settling.
    @State private var completionTimestamps: [String: Date] = [:]

    /// How long a just-finished session keeps pulsing before settling into the static lit dot.
    /// Without this, completion was a silent switch to a static red — easy to miss entirely.
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

    var body: some View {
        // The notch shows exactly ONE light regardless of how many agents are running: the
        // highest-priority state across all of them (stopped > awaiting input > executing >
        // thinking), with the most recently updated chat breaking ties. There is deliberately
        // no per-agent row — the earlier one rendered provider logos instead of lights, and
        // pulsed those logos, which read as the notch blinking at you.
        //
        // TimelineView ticks every second purely so the completion window above is re-evaluated.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            AgentTrafficLightDots(
                style: trafficLightStyle,
                state: activeState,
                isPulsing: shouldPulse(at: context.date)
            )
        }
        // Track when sessions leave an active run so the completion pulse has a start time.
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
                    completionTimestamps[session.id] = now
                }
            }
        }
    }

    /// Yellow and green breathe for as long as they are lit — they mean "something is happening".
    /// Red means finished, so it pulses only for `attentionWindow` after the run actually ends
    /// and then holds steady; otherwise a finished agent would blink indefinitely.
    private func shouldPulse(at now: Date) -> Bool {
        if activeState.showsRedTrafficLight {
            return primarySession.map { isRecentlyCompleted($0.id, at: now) } ?? false
        }
        return activeState.showsYellowTrafficLight || activeState.showsGreenTrafficLight
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
