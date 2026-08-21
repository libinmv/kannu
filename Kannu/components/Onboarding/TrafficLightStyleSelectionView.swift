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

import Defaults
import SwiftUI

/// Onboarding step: pick how the agent traffic light looks in the closed notch.
///
/// The selection is held in local state and only written to Defaults on Continue, matching
/// `MusicControllerSelectionView` — so backing out of onboarding doesn't leave a half-applied
/// choice behind.
struct TrafficLightStyleSelectionView: View {
    let onContinue: () -> Void

    @Default(.agentTrafficLightStyle) var agentTrafficLightStyle
    @State private var selectedStyle: AgentTrafficLightStyle = Defaults[.agentTrafficLightStyle]

    var body: some View {
        VStack(spacing: 20) {
            Text("Agent Traffic Light")
                .font(.title)
                .fontWeight(.bold)
                .padding(.top, 24)

            Text("Kannu shows a light in the notch while your AI agents work — green while running, yellow when one needs you, red when it finishes. Choose how it looks. You can change this later in settings.")
                .multilineTextAlignment(.center)
                .font(.body)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            VStack(spacing: 12) {
                ForEach(AgentTrafficLightStyle.allCases) { style in
                    TrafficLightStyleCard(
                        style: style,
                        isSelected: selectedStyle == style,
                        onTap: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedStyle = style
                            }
                        }
                    )
                }
            }
            .padding(.horizontal)

            Spacer()

            Button("Continue") {
                agentTrafficLightStyle = selectedStyle
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
    }
}

private struct TrafficLightStyleCard: View {
    let style: AgentTrafficLightStyle
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                // A real notch preview: same view the closed notch draws, on the same dark
                // background, showing the "agent is running" state.
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black)
                    AgentTrafficLightDots(style: style, state: .executing)
                }
                .frame(width: 76, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    Text(style.localizedName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(style.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: isSelected ? 2 : 0)
            )
            .scaleEffect(isHovering ? 1.02 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

#Preview {
    TrafficLightStyleSelectionView(onContinue: {})
        .frame(width: 400, height: 600)
}
