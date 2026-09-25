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

import SwiftUI
import Defaults
import AtollExtensionKit

struct ExtensionsSettingsView: View {
    @ObservedObject private var authManager = ExtensionAuthorizationManager.shared
    @State private var searchText = ""
    @State private var selectedEntry: ExtensionAuthorizationEntry?
    @State private var showingRemoveConfirmation = false
    
    private func highlightID(_ title: String) -> String {
        "extensions-\(title)"
    }
    
    private var filteredEntries: [ExtensionAuthorizationEntry] {
        guard !searchText.isEmpty else { return authManager.entries }
        let query = searchText.lowercased()
        return authManager.entries.filter {
            $0.bundleIdentifier.lowercased().contains(query) ||
            $0.appName.lowercased().contains(query)
        }
    }
    
    var body: some View {
        Form {
            globalTogglesSection
            
            if authManager.isExtensionsFeatureEnabled {
                authorizedAppsSection
            }
        }
        .navigationTitle("Extensions")
        .alert("Remove Extension", isPresented: $showingRemoveConfirmation, presenting: selectedEntry) { entry in
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                authManager.removeEntry(bundleIdentifier: entry.bundleIdentifier)
                selectedEntry = nil
            }
        } message: { entry in
            Text("Remove \(entry.appName) from the authorized extensions list? This will dismiss all active live activities, lock screen widgets, and notch experiences from this app.")
        }
    }
    
    private var globalTogglesSection: some View {
        Section {
            Defaults.Toggle(String(localized:"Enable third-party extensions"), key: .enableThirdPartyExtensions)
                .settingsHighlight(id: highlightID("Enable third-party extensions"))
            
            if Defaults[.enableThirdPartyExtensions] {
                Defaults.Toggle(String(localized:"Allow extension live activities"), key: .enableExtensionLiveActivities)
                    .settingsHighlight(id: highlightID("Allow extension live activities"))


                Defaults.Toggle(String(localized:"Allow extension lock screen widgets"), key: .enableExtensionLockScreenWidgets)
                    .settingsHighlight(id: highlightID("Allow extension lock screen widgets"))

                Defaults.Toggle(String(localized:"Allow extension notch experiences"), key: .enableExtensionNotchExperiences)
                    .settingsHighlight(id: highlightID("Allow extension notch experiences"))

                if Defaults[.enableExtensionNotchExperiences] {
                    // One row each; they used to share a single packed row.
                    Defaults.Toggle(String(localized:"Show extension tabs"), key: .enableExtensionNotchTabs)
                    Defaults.Toggle(String(localized:"Allow minimalistic overrides"), key: .enableExtensionNotchMinimalisticOverrides)
                    Defaults.Toggle(String(localized:"Allow interactive web content"), key: .enableExtensionNotchInteractiveWebViews)
                }
                
                Defaults.Toggle(String(localized:"Enable extension diagnostics logging"), key: .extensionDiagnosticsLoggingEnabled)
                    .settingsHighlight(id: highlightID("Enable extension diagnostics logging"))
            }
        } header: {
            SettingsSectionHeader("Global Settings")
        } footer: {
            if Defaults[.enableThirdPartyExtensions] {
                SettingsFooter("Third-party apps using Extension Kit can display live activities, lock screen widgets, and dedicated notch experiences. Toggle features above or manage individual app permissions below.")
            } else {
                SettingsFooter("Enable extensions to allow third-party apps to display live activities and lock screen widgets in Kannu.")
            }
        }
    }
    
    private var authorizedAppsSection: some View {
        Section {
            if authManager.entries.isEmpty {
                // An empty state is a card, not a row: it is the one place in this section that
                // may pad and centre itself.
                VStack(alignment: .center, spacing: SettingsMetrics.cardPadding) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .accessibilityHidden(true)

                    Text("No extensions yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    Text("Apps using Extension Kit will appear here once they request permission")
                        .settingsDescriptionStyle()
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                if authManager.entries.count > 3 {
                    TextField("Search extensions...", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                }
                
                ForEach(filteredEntries) { entry in
                    ExtensionEntryRow(entry: entry, onRemove: {
                        selectedEntry = entry
                        showingRemoveConfirmation = true
                    })
                }
            }
        } header: {
            HStack {
                SettingsSectionHeader("App Permissions")
                Spacer()
                if !authManager.entries.isEmpty {
                    Text("\(authManager.entries.count) \(authManager.entries.count == 1 ? "app" : "apps")")
                        .settingsDescriptionStyle()
                }
            }
            .settingsHighlight(id: highlightID("App permissions list"))
        } footer: {
            if !authManager.entries.isEmpty {
                SettingsFooterStack {
                    Text("Permission States:")
                        .font(.subheadline.weight(.semibold))

                    HStack(spacing: 16) {
                        Label("Authorized", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Label("Pending", systemImage: "clock.fill")
                            .foregroundStyle(.orange)
                        Label("Denied/Revoked", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .font(.subheadline)
                }
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
    }
}

@MainActor
private struct ExtensionEntryRow: View {
    @ObservedObject private var authManager = ExtensionAuthorizationManager.shared
    @ObservedObject private var liveActivityManager = ExtensionLiveActivityManager.shared
    @ObservedObject private var widgetManager = ExtensionLockScreenWidgetManager.shared
    @ObservedObject private var notchExperienceManager = ExtensionNotchExperienceManager.shared
    let entry: ExtensionAuthorizationEntry
    let onRemove: () -> Void

    @State private var isExpanded: Bool

    init(entry: ExtensionAuthorizationEntry, onRemove: @escaping () -> Void, initiallyExpanded: Bool = false) {
        self.entry = entry
        self.onRemove = onRemove
        _isExpanded = State(initialValue: initiallyExpanded)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The row proper: the app's name and bundle id in the label column, the disclosure
            // chevron in the control column, so it lines up with every other Settings row.
            LabeledContent {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? Text("Hide details") : Text("Show details"))
            } label: {
                HStack(spacing: SettingsMetrics.rowContent) {
                    statusIndicator
                    SettingsRowLabel(verbatim: entry.appName, description: entry.bundleIdentifier)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }

            // Expanded details
            if isExpanded {
                expandedDetails
                    .padding(.top, SettingsMetrics.cardPadding)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var statusIndicator: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.15))
                .frame(width: 22, height: 22)

            Image(systemName: statusIcon)
                .imageScale(.small)
                .foregroundStyle(statusColor)
        }
        .accessibilityLabel(Text(entry.status.rawValue))
    }
    
    private var statusColor: Color {
        switch entry.status {
        case .authorized: return .green
        case .pending: return .orange
        case .denied, .revoked: return .red
        }
    }
    
    private var statusIcon: String {
        switch entry.status {
        case .authorized: return "checkmark.circle.fill"
        case .pending: return "clock.fill"
        case .denied, .revoked: return "xmark.circle.fill"
        }
    }
    
    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.cardPadding) {
            // Status info
            VStack(alignment: .leading, spacing: SettingsMetrics.footerStack) {
                HStack(spacing: SettingsMetrics.rowContent) {
                    Text("Status:")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(entry.status.rawValue.capitalized)
                        .font(.subheadline)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.15))
                        .foregroundStyle(statusColor)
                        .clipShape(Capsule())
                }
                
                if let grantedAt = entry.grantedAt {
                    infoRow(label: "Granted", value: formatDate(grantedAt))
                }
                
                if let lastActivity = entry.lastActivityAt {
                    infoRow(label: "Last Activity", value: formatDate(lastActivity))
                }
                
                if let deniedReason = entry.lastDeniedReason {
                    VStack(alignment: .leading, spacing: SettingsMetrics.labelStack) {
                        Text("Last Denied Reason:")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        SettingsErrorText(deniedReason)
                    }
                }
            }
            
            Divider()
            
            // Scopes section
            if entry.status == .authorized {
                scopeToggles
                Divider()
            }
            
            // Rate limits info
                if let rateLimitRecord = authManager.rateLimitRecords.first(where: { $0.bundleIdentifier == entry.bundleIdentifier }),
                    !rateLimitRecord.activityTimestamps.isEmpty || !rateLimitRecord.widgetTimestamps.isEmpty || !rateLimitRecord.notchExperienceTimestamps.isEmpty {
                rateLimitInfo(record: rateLimitRecord)
                Divider()
            }
            
            // Actions
            actionButtons
        }
        .padding(SettingsMetrics.cardPadding)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    
    private var scopeToggles: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowContent) {
            Text("Allowed Features")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            
            Toggle("Live Activities", isOn: Binding(
                get: { entry.allowedScopes.contains(.liveActivities) },
                set: { enabled in
                    var newScopes = entry.allowedScopes
                    if enabled {
                        newScopes.insert(.liveActivities)
                    } else {
                        newScopes.remove(.liveActivities)
                    }
                    authManager.updateAllowedScopes(bundleIdentifier: entry.bundleIdentifier, allowedScopes: newScopes)
                }
            ))
            .disabled(!authManager.areLiveActivitiesEnabled)
            
            Toggle("Lock Screen Widgets", isOn: Binding(
                get: { entry.allowedScopes.contains(.lockScreenWidgets) },
                set: { enabled in
                    var newScopes = entry.allowedScopes
                    if enabled {
                        newScopes.insert(.lockScreenWidgets)
                    } else {
                        newScopes.remove(.lockScreenWidgets)
                    }
                    authManager.updateAllowedScopes(bundleIdentifier: entry.bundleIdentifier, allowedScopes: newScopes)
                }
            ))
            .disabled(!authManager.areLockScreenWidgetsEnabled)

            Toggle("Notch Experiences", isOn: Binding(
                get: { entry.allowedScopes.contains(.notchExperiences) },
                set: { enabled in
                    var newScopes = entry.allowedScopes
                    if enabled {
                        newScopes.insert(.notchExperiences)
                    } else {
                        newScopes.remove(.notchExperiences)
                    }
                    authManager.updateAllowedScopes(bundleIdentifier: entry.bundleIdentifier, allowedScopes: newScopes)
                }
            ))
            .disabled(!authManager.areNotchExperiencesEnabled)
        }
    }
    
    private func rateLimitInfo(record: ExtensionRateLimitRecord) -> some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowContent) {
            Text("Recent Activity (last 5 minutes)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            
            HStack(spacing: 20) {
                if !record.activityTimestamps.isEmpty {
                    VStack(alignment: .leading, spacing: SettingsMetrics.labelStack) {
                        Text("Live Activities")
                            .settingsDescriptionStyle()
                        Text("\(record.activityTimestamps.count)")
                            .font(.subheadline.monospacedDigit())
                            .textSelection(.enabled)
                    }
                }
                
                if !record.widgetTimestamps.isEmpty {
                    VStack(alignment: .leading, spacing: SettingsMetrics.labelStack) {
                        Text("Widget Updates")
                            .settingsDescriptionStyle()
                        Text("\(record.widgetTimestamps.count)")
                            .font(.subheadline.monospacedDigit())
                            .textSelection(.enabled)
                    }
                }

                if !record.notchExperienceTimestamps.isEmpty {
                    VStack(alignment: .leading, spacing: SettingsMetrics.labelStack) {
                        Text("Notch Experiences")
                            .settingsDescriptionStyle()
                        Text("\(record.notchExperienceTimestamps.count)")
                            .font(.subheadline.monospacedDigit())
                            .textSelection(.enabled)
                    }
                }
            }
            
            Button("Reset Rate Limits") {
                authManager.resetRateLimits(for: entry.bundleIdentifier)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
    
    private var actionButtons: some View {
        HStack(spacing: SettingsMetrics.rowContent) {
            switch entry.status {
            case .pending:
                Button("Authorize") {
                    authManager.authorize(bundleIdentifier: entry.bundleIdentifier, appName: entry.appName)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                
                Button("Deny") {
                    authManager.deny(bundleIdentifier: entry.bundleIdentifier, reason: "Denied by user")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
            case .authorized:
                Button("Revoke Access") {
                    authManager.revoke(bundleIdentifier: entry.bundleIdentifier, reason: "Revoked by user")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.orange)
                
            case .denied, .revoked:
                Button("Re-authorize") {
                    authManager.authorize(bundleIdentifier: entry.bundleIdentifier, appName: entry.appName)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            
            Spacer()
            
            resetMenu

            Button("Remove") {
                onRemove()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
        }
    }

    private var resetMenu: some View {
        Menu {
            Button("Reset Live Activities") {
                liveActivityManager.dismissAll(for: entry.bundleIdentifier)
            }
            .disabled(!hasLiveActivities)

            Button("Reset Lock Screen Widgets") {
                widgetManager.dismissAll(for: entry.bundleIdentifier)
            }
            .disabled(!hasWidgets)

            Button("Reset Notch Experiences") {
                notchExperienceManager.dismissAll(for: entry.bundleIdentifier)
            }
            .disabled(!hasNotchExperiences)
        } label: {
            Label("Reset", systemImage: "arrow.counterclockwise.circle")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
    }

    private var hasLiveActivities: Bool {
        liveActivityManager.activeActivities.contains { $0.bundleIdentifier == entry.bundleIdentifier }
    }

    private var hasWidgets: Bool {
        widgetManager.activeWidgets.contains { $0.bundleIdentifier == entry.bundleIdentifier }
    }

    private var hasNotchExperiences: Bool {
        notchExperienceManager.activeExperiences.contains { $0.bundleIdentifier == entry.bundleIdentifier }
    }
    
    private func infoRow(label: String, value: String) -> some View {
        HStack(spacing: SettingsMetrics.rowContent) {
            Text("\(label):")
                .settingsDescriptionStyle()
            Text(verbatim: value)
                .font(.subheadline)
                .textSelection(.enabled)
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

#Preview {
    ExtensionsSettingsView()
}

#if DEBUG
extension ExtensionsSettingsView {
    /// DEBUG snapshot harness: the app rows, collapsed and expanded, without needing a real
    /// authorized extension on this Mac — the rows are the ones that must sit on the same grid as
    /// every other Settings row.
    static func snapshotEntryRows() -> AnyView {
        let granted = Date(timeIntervalSince1970: 1_757_600_000)
        let entries = [
            ExtensionAuthorizationEntry(bundleIdentifier: "com.example.weatherbar", appName: "WeatherBar",
                                        status: .authorized, grantedAt: granted, lastActivityAt: granted),
            ExtensionAuthorizationEntry(bundleIdentifier: "com.example.buildwatch", appName: "BuildWatch",
                                        status: .pending),
            ExtensionAuthorizationEntry(bundleIdentifier: "com.example.noisy", appName: "Noisy Widget Co.",
                                        status: .denied, grantedAt: granted,
                                        lastDeniedReason: "Asked for lock screen widgets 40 times in five minutes."),
        ]
        return AnyView(Form {
            Section {
                ForEach(entries) { entry in
                    ExtensionEntryRow(entry: entry, onRemove: {}, initiallyExpanded: entry.status == .denied)
                }
            } header: {
                SettingsSectionHeader("App Permissions")
            }
        })
    }
}
#endif
