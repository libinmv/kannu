import Defaults
import SwiftUI

struct AgentTrafficLightIndicator: View {
    @ObservedObject var agentStatusMonitor = CursorAgentStatusMonitor.shared
    @Default(.showAgentStoppedIndicator) private var showAgentStoppedIndicator

    private var activeState: AgentTrafficLightState {
        if agentStatusMonitor.trafficLightState == .inactive && showAgentStoppedIndicator {
            return .stopped
        }
        return agentStatusMonitor.trafficLightState
    }

    var body: some View {
        HStack(spacing: 6) {
            trafficLightCircle(color: .red, isActive: activeState.showsRedTrafficLight, shouldPulse: false)
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

    @ViewBuilder
    private func trafficLightCircle(color: Color, isActive: Bool, shouldPulse: Bool) -> some View {
        Circle()
            .fill(color.opacity(isActive ? 1.0 : 0.2))
            .frame(width: 10, height: 10)
            .modifier(ConditionalPulseModifier(isEnabled: isActive && shouldPulse))
    }
}

struct AgentTrafficLightLiveActivity: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject private var monitor = CursorAgentStatusMonitor.shared
    let isHovering: Bool
    let gestureProgress: CGFloat
    var onHoverAgentCenter: ((Bool) -> Void)? = nil

    private var notchContentHeight: CGFloat {
        max(0, vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12))
    }

    private var outerHeight: CGFloat {
        max(0, vm.effectiveClosedNotchHeight + (isHovering ? 8 : 0))
    }

    private var contentWidth: CGFloat {
        max(0, vm.closedNotchSize.width + (isHovering ? 8 : 0))
    }

    var body: some View {
        AgentTrafficLightIndicator()
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
            .scaleEffect(isPulsing ? 1.15 : 1.0)
            .opacity(isPulsing ? 0.75 : 1.0)
            // Using .animation(value:) instead of withAnimation so that flipping
            // isPulsing back to false replaces the repeatForever animation and
            // actually stops the pulse (withAnimation-started repeatForever
            // animations are not cancelled by a plain state write).
            .animation(
                isPulsing
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.15),
                value: isPulsing
            )
            .onAppear { isPulsing = isEnabled }
            .onChange(of: isEnabled) { _, enabled in
                isPulsing = enabled
            }
    }
}
