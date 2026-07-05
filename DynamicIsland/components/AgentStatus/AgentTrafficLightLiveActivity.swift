import Defaults
import SwiftUI

struct AgentTrafficLightLiveActivity: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject var agentStatusMonitor = CursorAgentStatusMonitor.shared
    @Default(.showAgentStoppedIndicator) private var showAgentStoppedIndicator
    @State private var isExpanded = false

    let isHovering: Bool
    let gestureProgress: CGFloat

    private var activeState: AgentTrafficLightState {
        if agentStatusMonitor.trafficLightState == .inactive && showAgentStoppedIndicator {
            return .stopped
        }
        return agentStatusMonitor.trafficLightState
    }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .background {
                    if isExpanded {
                        HStack(spacing: 4) {
                            trafficLightCircle(color: .red, isActive: activeState == .stopped, shouldPulse: false)
                            trafficLightCircle(color: .yellow, isActive: activeState == .thinking, shouldPulse: true)
                            trafficLightCircle(color: .green, isActive: activeState == .executing, shouldPulse: true)
                        }
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
                .frame(
                    width: isExpanded ? max(0, vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12) + gestureProgress / 2 + 28) : 0,
                    height: vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12)
                )

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width + (isHovering ? 8 : 0))

            Color.clear
                .frame(
                    width: isExpanded ? max(0, vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12) + gestureProgress / 2) : 0,
                    height: vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12)
                )
        }
        .frame(height: vm.effectiveClosedNotchHeight + (isHovering ? 8 : 0))
        .onAppear {
            withAnimation(.smooth(duration: 0.4)) {
                isExpanded = true
            }
        }
        .onChange(of: activeState) { _, newValue in
            if newValue == .inactive {
                withAnimation(.smooth(duration: 0.4)) {
                    isExpanded = false
                }
            } else {
                withAnimation(.smooth(duration: 0.4)) {
                    isExpanded = true
                }
            }
        }
        .onChange(of: showAgentStoppedIndicator) { _, _ in
            withAnimation(.smooth(duration: 0.4)) {
                isExpanded = activeState != .inactive
            }
        }
    }

    @ViewBuilder
    private func trafficLightCircle(color: Color, isActive: Bool, shouldPulse: Bool) -> some View {
        Circle()
            .fill(color.opacity(isActive ? 1.0 : 0.2))
            .frame(width: 8, height: 8)
            .modifier(ConditionalPulseModifier(isEnabled: isActive && shouldPulse))
    }
}

private struct ConditionalPulseModifier: ViewModifier {
    let isEnabled: Bool
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.15 : 1.0)
            .opacity(isPulsing ? 0.75 : 1.0)
            .onAppear {
                guard isEnabled else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                if enabled {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        isPulsing = true
                    }
                } else {
                    isPulsing = false
                }
            }
    }
}
