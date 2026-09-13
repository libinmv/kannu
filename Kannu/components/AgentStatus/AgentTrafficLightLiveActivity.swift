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
    /// The live notch indicator draws its dots with Core Animation (`TrafficLightDot`), so the
    /// breath costs the main thread nothing; previews keep plain SwiftUI circles.
    var live: Bool = false
    var dotSize: CGFloat = 10
    var spacing: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        let tint = color.opacity(isActive ? 1.0 : 0.2)
        if live {
            // The inner frame leaves room for the breath (1.3×); the outer keeps the layout slot.
            TrafficLightDot(color: tint, diameter: dotSize, pulsing: isActive && isPulsing && !reduceMotion)
                .frame(width: dotSize * TrafficLightPulseSpec.scale, height: dotSize * TrafficLightPulseSpec.scale)
                .frame(width: dotSize, height: dotSize)
        } else {
            Circle()
                .fill(tint)
                .frame(width: dotSize, height: dotSize)
        }
    }
}

/// The closed-notch cue for an unacknowledged high-severity security finding. Deliberately
/// monochrome: white on the notch, never one of the three light colours, so it cannot be read
/// as an agent state and cannot collide with a custom palette. The *shape* carries the meaning.
struct SecurityShieldGlyph: View {
    var size: CGFloat = 9

    var body: some View {
        Image(systemName: "exclamationmark.shield.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.9))
            .accessibilityLabel(String(localized: "Unacknowledged high-severity security finding"))
    }
}

struct AgentTrafficLightIndicator: View {
    @ObservedObject var agentStatusMonitor = CursorAgentStatusMonitor.shared
    @ObservedObject private var findingsStore = SecurityFindingsStore.shared
    @Default(.showAgentStoppedIndicator) private var showAgentStoppedIndicator
    @Default(.agentTrafficLightStyle) private var trafficLightStyle
    @Default(.adrHighAlertMode) private var highAlertMode

    /// A pending high finding shows a shield beside the dots in every mode but Off. It rides
    /// along wherever the dots are drawn (standalone, or inside the music pill).
    private var showsSecurityGlyph: Bool {
        highAlertMode.showsGlyph && findingsStore.ranking.pendingHighCount > 0
    }
    /// Keyed by session ID — records when a session first became non-active (stopped/inactive),
    /// so a just-finished run can pulse red briefly before settling.
    @State private var completionTimestamps: [String: Date] = [:]
    /// Bumped once when the red pulse window ends, so the body re-evaluates at that moment. (A
    /// 1 Hz `TimelineView` used to redraw this view every second for the whole run just for that.)
    @State private var attentionWake = Date.distantPast

    /// When the primary session finished, if it did (the red pulse window starts there).
    private var primaryCompletion: Date? {
        primarySession.flatMap { completionTimestamps[$0.id] }
    }

    /// Spoken description of the aggregate state. `displayName` is a raw literal used for
    /// on-screen text, so it is not reused here — VoiceOver output is localized.
    private var accessibilityStateDescription: String {
        switch activeState {
        case .executing, .thinking:
            return String(localized: "Agent status: working")
        case .awaitingInput:
            return String(localized: "Agent status: needs your input")
        case .stopped:
            return String(localized: "Agent status: stopped")
        case .inactive:
            return String(localized: "Agent status: no agents running")
        }
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
        // The red pulse window is re-evaluated by one wake at its end (`.task(id:)` below), not by
        // a periodic timer.
        let now = Date()
        let _ = attentionWake
        HStack(spacing: 6) {
                AgentTrafficLightDots(
                    style: trafficLightStyle,
                    state: activeState,
                    isPulsing: shouldPulse(at: now),
                    live: true
                )
                // The dots carry the aggregate state in colour alone, and it is rendered as text
                // nowhere — the panel shows per-session state, and only on hover.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityStateDescription)
                if showsSecurityGlyph {
                    SecurityShieldGlyph()
                }
        }
        .task(id: AgentTrafficLightAttention.pulseChange(red: activeState.showsRedTrafficLight, completedAt: primaryCompletion, now: now)) {
            guard let end = AgentTrafficLightAttention.pulseChange(red: activeState.showsRedTrafficLight,
                                                                   completedAt: primaryCompletion, now: Date()) else { return }
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow) + 0.05))
            if !Task.isCancelled { attentionWake = Date() }
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
        AgentTrafficLightAttention.pulses(
            yellowOrGreen: activeState.showsYellowTrafficLight || activeState.showsGreenTrafficLight,
            red: activeState.showsRedTrafficLight,
            completedAt: primaryCompletion,
            now: now
        )
    }
}

struct AgentTrafficLightLiveActivity: View {
    @EnvironmentObject var vm: KannuViewModel
    @ObservedObject private var monitor = CursorAgentStatusMonitor.shared
    @ObservedObject private var findingsStore = SecurityFindingsStore.shared
    @ObservedObject private var doNotDisturb = DoNotDisturbManager.shared
    @Default(.adrHighAlertMode) private var highAlertMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isHovering: Bool
    let gestureProgress: CGFloat

    /// Only supplied when rendering on a display with a physical notch.
    /// Non-notch displays receive nil and retain their existing sizing.
    var physicalNotchExpandedHeight: CGFloat? = nil

    /// Must remain zero on non-notch displays.
    var trafficLightVerticalOffset: CGFloat = 0

    /// Clicking the security pill opens the panel on the agent tab, where the pinned card is.
    var onTapSecurityPill: (() -> Void)? = nil

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

    /// The pill is not a sneak peek: sneak peeks are timed HUDs that auto-hide. It lives here,
    /// beside the light, and stays until the user acts (default) — or for five seconds in that
    /// mode. Deferred to glyph-only while Focus is on, so a Do Not Disturb session is not
    /// interrupted; it appears when Focus ends.
    private func pillIsVisible(at now: Date, pinned: AgentSecurityFinding) -> Bool {
        guard highAlertMode.showsPill, !doNotDisturb.isDoNotDisturbActive else { return false }
        return AgentTrafficLightAttention.pillVisible(fiveSecondMode: highAlertMode == .fiveSeconds,
                                                      firstSeen: pinned.firstSeen, now: now)
    }

    /// Bumped once when a five-second pill's time is up; the store's own snooze wake covers the
    /// rest. (A 1 Hz `TimelineView` used to re-rank every second instead.)
    @State private var pillWake = Date.distantPast

    var body: some View {
        let now = Date()
        let _ = pillWake
        let ranking = findingsStore.ranking
        let pillEnd = ranking.pinned.flatMap {
            AgentTrafficLightAttention.pillChange(fiveSecondMode: highAlertMode == .fiveSeconds, firstSeen: $0.firstSeen, now: now)
        }
        HStack(spacing: 8) {
            AgentTrafficLightIndicator()
            if let pinned = ranking.pinned, pillIsVisible(at: now, pinned: pinned) {
                SecurityAlertPill(
                    finding: pinned,
                    extraCount: max(0, ranking.pendingHighCount - 1),
                    maxWidth: min(contentWidth * 0.62, 190)
                )
                .onTapGesture { onTapSecurityPill?() }
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .task(id: pillEnd) {
            guard let pillEnd else { return }
            try? await Task.sleep(for: .seconds(max(0, pillEnd.timeIntervalSinceNow) + 0.05))
            if !Task.isCancelled { pillWake = Date() }
        }
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

/// "⚠ Running MCP server nobody declared  +2" — the one high finding that owns the closed
/// notch, and how many more are waiting. Monochrome on purpose (see `SecurityShieldGlyph`).
struct SecurityAlertPill: View {
    let finding: AgentSecurityFinding
    let extraCount: Int
    let maxWidth: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            SecurityShieldGlyph(size: 9)
            Text(finding.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
            if extraCount > 0 {
                Text("+\(extraCount)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.14)))
        .frame(maxWidth: maxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Security finding, high: \(finding.title). Click to open."))
    }
}
