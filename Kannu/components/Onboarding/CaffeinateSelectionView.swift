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

/// Onboarding step: choose how Kannu keeps the Mac awake for agent work.
/// Selection is local state, written to Defaults only on Continue.
struct CaffeinateSelectionView: View {
    let onContinue: () -> Void

    @Default(.smartCaffeinate) var smartCaffeinate
    @State private var selectedSmart: Bool = true

    var body: some View {
        VStack(spacing: 20) {
            Text("Keep the Mac Awake?")
                .font(.title)
                .fontWeight(.bold)
                .padding(.top, 24)

            Text("Long agent runs die if the Mac falls asleep. Choose how Kannu should handle it — you can change this later in settings.")
                .multilineTextAlignment(.center)
                .font(.body)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            VStack(spacing: 12) {
                CaffeinateOptionCard(
                    icon: "sparkles",
                    title: String(localized: "Smart caffeinate"),
                    subtitle: String(localized: "Recommended — the Mac stays awake automatically while agents run, and sleeps normally when they stop."),
                    isSelected: selectedSmart,
                    onTap: { withAnimation(.easeInOut(duration: 0.2)) { selectedSmart = true } }
                )
                CaffeinateOptionCard(
                    icon: "switch.2",
                    title: String(localized: "Manual switch"),
                    subtitle: String(localized: "A switch in the notch's agent panel keeps the Mac awake while it's on — you decide when."),
                    isSelected: !selectedSmart,
                    onTap: { withAnimation(.easeInOut(duration: 0.2)) { selectedSmart = false } }
                )
            }
            .padding(.horizontal)

            Spacer()

            Button("Continue") {
                smartCaffeinate = selectedSmart
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

private struct CaffeinateOptionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black)
                    HStack(spacing: 2) {
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.orange)
                        Image(systemName: icon)
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(width: 56, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(subtitle)
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
            withAnimation(.easeInOut(duration: 0.2)) { isHovering = hovering }
        }
    }
}

#Preview {
    CaffeinateSelectionView(onContinue: {})
        .frame(width: 400, height: 600)
}
