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

/// Onboarding step: the macOS permissions this setup needs, each explained, each asked only when
/// the user presses Allow, one dialog at a time. A tester used to meet four system dialogs at once,
/// over the welcome music; now nothing asks before this step, and the music waits for Finish.
struct PermissionsStepView: View {
    let rows: [LaunchPermission]
    let musicSource: MediaControllerType
    /// Whether the login item should be registered; the caller registers it.
    let onLaunchAtLoginChoice: (Bool) -> Void
    let onContinue: () -> Void

    @ObservedObject private var permissions = LaunchPermissionManager.shared
    @State private var launchAtLogin = true
    @State private var focusMode: FocusMonitoringMode = Defaults[.focusMonitoringMode]

    var body: some View {
        VStack(spacing: 16) {
            Text("A Few Permissions")
                .font(.title)
                .fontWeight(.bold)
                .padding(.top, 24)

            Text("macOS asks for each one only when you press Allow. Skip any: what it powers stays off until you allow it in Brain.")
                .multilineTextAlignment(.center)
                .font(.body)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(rows) { permission in
                        LaunchPermissionRow(permission: permission, musicSource: musicSource)
                    }
                    focusRow
                    Toggle(isOn: $launchAtLogin) {
                        PermissionRowLabel(
                            symbol: "power",
                            title: String(localized: "Open Kannu at login"),
                            reason: String(localized: "So the notch is there whenever your agents are.")
                        )
                    }
                    .toggleStyle(.switch)
                    .permissionCard()
                }
                .padding(.horizontal)
            }

            Text("Change these any time in Brain › General › Permissions, or System Settings › Privacy & Security.")
                .multilineTextAlignment(.center)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            Button("Continue") {
                // A row left unanswered is a Not now: its feature waits, and nothing asks later.
                for permission in rows where LaunchPermissionManager.answer(for: permission) == .notAsked {
                    permissions.postpone(permission)
                }
                Defaults[.focusMonitoringMode] = focusMode
                onLaunchAtLoginChoice(launchAtLogin)
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(permissions.requestInFlight != nil)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
        .onAppear { permissions.refresh() }
    }

    /// The choice the onboarding window used to pop up over its Welcome screen.
    private var focusRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            PermissionRowLabel(
                symbol: "moon",
                title: String(localized: "Focus detection"),
                reason: String(localized: "Developer Tools access reads Focus more reliably; without it, Kannu reads it as it can.")
            )
            Picker("Focus detection", selection: $focusMode) {
                Text("Without DevTools").tag(FocusMonitoringMode.withoutDevTools)
                Text("Use DevTools").tag(FocusMonitoringMode.useDevTools)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if focusMode == .useDevTools {
                Button("Open Developer Tools settings") { DeveloperToolsSettings.open() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .permissionCard()
    }
}

/// One permission: why Kannu wants it, where it stands, and Allow / Not now. Shared by the
/// onboarding step and Brain › General › Permissions.
struct LaunchPermissionRow: View {
    let permission: LaunchPermission
    let musicSource: MediaControllerType

    @ObservedObject private var permissions = LaunchPermissionManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PermissionRowLabel(symbol: symbol, title: title, reason: reason)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                controls
            }
        }
        .permissionCard()
    }

    private var status: LaunchPermissionStatus { permissions.statuses[permission] ?? .notAsked }

    @ViewBuilder
    private var controls: some View {
        switch status {
        case .notAsked, .deferred:
            if status == .notAsked {
                Button("Not now") { permissions.postpone(permission) }
                    .buttonStyle(.bordered)
            } else {
                Text("Not now").font(.caption).foregroundColor(.secondary)
            }
            Button("Allow") { permissions.request(permission, musicSource: musicSource) }
                .buttonStyle(.borderedProminent)
                .disabled(permissions.requestInFlight != nil)
        case .waiting:
            ProgressView().controlSize(.small)
            Text("Waiting for macOS…").font(.caption).foregroundColor(.secondary)
        case .allowed:
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.green)
        case .notAllowed:
            Text("Not allowed").font(.caption).foregroundColor(.secondary)
            Button("Open System Settings") { permissions.openSystemSettings(for: permission) }
                .buttonStyle(.bordered)
        case .askedWhenAppOpens:
            Text("macOS asks when \(permission == .notesAutomation ? String(localized: "Notes") : musicSource.localizedName) opens")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var symbol: String {
        switch permission {
        case .accessibility: return "accessibility"
        case .bluetooth: return "headphones"
        case .downloads: return "arrow.down.circle"
        case .location: return "location"
        case .musicAutomation: return "music.note"
        case .notesAutomation: return "note.text"
        case .warp: return "terminal"
        }
    }

    private var title: String {
        switch permission {
        case .accessibility: return String(localized: "Accessibility")
        case .bluetooth: return String(localized: "Bluetooth")
        case .downloads: return String(localized: "Downloads folder")
        case .location: return String(localized: "Location")
        case .musicAutomation: return String(localized: "Control \(musicSource.localizedName)")
        case .notesAutomation: return String(localized: "Control Notes")
        case .warp: return String(localized: "Warp's agent sessions")
        }
    }

    private var reason: String {
        switch permission {
        case .accessibility:
            return String(localized: "Shows volume, brightness and the media keys in the notch.")
        case .bluetooth:
            return String(localized: "Shows your headphones and their battery when they connect.")
        case .downloads:
            return String(localized: "Shows download progress in the notch.")
        case .location:
            return String(localized: "Shows your local weather on the lock screen.")
        case .musicAutomation:
            return String(localized: "Lets the notch play, pause and skip in \(musicSource.localizedName).")
        case .notesAutomation:
            return String(localized: "Keeps the notch's notes in sync with Apple Notes.")
        case .warp:
            return String(localized: "Lets the agent light follow agents running in Warp.")
        }
    }
}

private struct PermissionRowLabel: View {
    let symbol: String
    let title: String
    let reason: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private extension View {
    func permissionCard() -> some View {
        padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.08)))
    }
}
