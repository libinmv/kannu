import AppKit
import Foundation
import Defaults
import SwiftUI

struct NotchAgentStatusView: View {
    @EnvironmentObject private var vm: KannuViewModel
    @ObservedObject private var monitor = CursorAgentStatusMonitor.shared
    @ObservedObject private var skinManager = NotchSkinManager.shared
    @ObservedObject private var caffeinate = CaffeinateManager.shared
    /// Defaults-backed, not @State: this tab is torn down and rebuilt on every tab switch.
    @Default(.caffeinateEnabled) private var caffeinateEnabled
    @Default(.smartCaffeinate) private var smartCaffeinate
    @Default(.agentActiveColor) private var activePaletteColor
    @Default(.agentAwaitingInputColor) private var awaitingPaletteColor
    @Default(.agentStoppedColor) private var stoppedPaletteColor
    @State private var isSuppressingScrollGesture = false
    @State private var redBlinkStartTimes: [String: Date] = [:]
    private let scrollSuppressionToken = UUID()

    private var hasSkin: Bool { skinManager.selectedSkinImage != nil }

    private var dedupedSessions: [AgentSessionStatus] {
        deduplicateLatestSessions(monitor.sessions)
    }

    private var visibleSessions: [AgentSessionStatus] {
        dedupedSessions.filter(\.isVisible)
    }

    private var allSessions: [AgentSessionStatus] {
        visibleSessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var recentChats: [AgentSessionStatus] {
        guard let primaryID = primarySession?.id else { return allSessions }
        return allSessions.filter { $0.id != primaryID }
    }

    private var primarySession: AgentSessionStatus? {
        AgentTrafficLightMapper.primarySession(from: visibleSessions)
    }

    private func deduplicateLatestSessions(_ sessions: [AgentSessionStatus]) -> [AgentSessionStatus] {
        var latestByConversationID: [String: AgentSessionStatus] = [:]
        for session in sessions {
            guard let existing = latestByConversationID[session.conversationID] else {
                latestByConversationID[session.conversationID] = session
                continue
            }
            latestByConversationID[session.conversationID] = preferredSession(existing: existing, incoming: session)
        }
        return Array(latestByConversationID.values)
    }

    private func preferredSession(existing: AgentSessionStatus, incoming: AgentSessionStatus) -> AgentSessionStatus {
        if existing.displayState != incoming.displayState {
            return existing.displayState > incoming.displayState ? existing : incoming
        }
        let existingHasReliableTitle = hasReliableChatName(existing.chatName)
        let incomingHasReliableTitle = hasReliableChatName(incoming.chatName)
        if existingHasReliableTitle != incomingHasReliableTitle {
            return incomingHasReliableTitle ? incoming : existing
        }
        return incoming.updatedAt >= existing.updatedAt ? incoming : existing
    }

    private func hasReliableChatName(_ value: String?) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return false }
        return !CursorAgentStatusMonitor.looksLikeToolName(trimmed)
    }

    private struct ProviderInstallStatus {
        let source: AgentProviderIconSource
        let name: String
        let detected: Bool
    }

    private var providerStatuses: [ProviderInstallStatus] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return [
            ProviderInstallStatus(
                source: .cursor, name: "Cursor",
                detected: fm.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path)
            ),
            ProviderInstallStatus(
                source: .claude, name: "Claude Code",
                detected: fm.fileExists(atPath: home.appendingPathComponent(".claude/projects").path)
            ),
            ProviderInstallStatus(
                source: .codex, name: "Codex",
                detected: fm.fileExists(atPath: home.appendingPathComponent(".codex/sessions").path)
            ),
            ProviderInstallStatus(
                source: .antigravity, name: "Antigravity",
                detected: fm.fileExists(atPath: home.appendingPathComponent(".gemini").path)
            ),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                caffeinateRow

                if let primary = primarySession {
                    clickableSession(primary) { primaryCard(primary) }
                } else if dedupedSessions.isEmpty {
                    emptyStateView
                }

                if !recentChats.isEmpty {
                    ForEach(recentChats) { session in
                        clickableSession(session) { sessionRow(session) }
                    }
                } else if !allSessions.isEmpty, primarySession == nil {
                    ForEach(allSessions) { session in
                        clickableSession(session) { sessionRow(session) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onHover { hovering in
            updateScrollGestureSuppression(for: hovering)
        }
        .onDisappear {
            updateScrollGestureSuppression(for: false)
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 10) {
            Text("Your agents are taking a coffee break ☕")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Text("Fire up Cursor, Claude Code, Codex, or Antigravity and start a session — we'll watch the lights for you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 0) {
                ForEach(providerStatuses, id: \.name) { status in
                    HStack(spacing: 5) {
                        AgentProviderIconView(source: status.source, size: 14)
                            .opacity(status.detected ? 1 : 0.3)
                        Text(status.name)
                            .font(.system(size: 10))
                            .foregroundStyle(status.detected ? .primary : .tertiary)
                            .lineLimit(1)
                        if status.detected {
                            Circle()
                                .fill(Color.green.opacity(0.85))
                                .frame(width: 5, height: 5)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 6)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(hasSkin ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.white.opacity(0.05)))
                if hasSkin {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.1))
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    /// Top-right caffeinate control, visible in every panel state. Two faces:
    /// - Smart mode on: a status-only indicator (cup + sparkle) — the Mac stays awake
    ///   automatically while agents run; clicking opens Settings to change the mode.
    /// - Smart mode off: the manual switch — on keeps the Mac awake right now, until off.
    /// In both faces the cup fills and warms only while the assertion is actually held,
    /// so the icon reports truth, not the switch position.
    @ViewBuilder
    private var caffeinateRow: some View {
        HStack(spacing: 6) {
            // The chat-list label lives on this line now — it fills the gap left of the
            // caffeinate control instead of costing its own row. Hidden in the empty state:
            // a "Recent chats" heading over the coffee-break message would label nothing.
            if !allSessions.isEmpty {
                Text("Recent chats")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if smartCaffeinate {
                Button {
                    SettingsWindowController.shared.showWindow(
                        navigatingToAgentStatusHighlight: SettingsDeepLink.smartCaffeinateHighlightID
                    )
                } label: {
                    HStack(spacing: 3) {
                        // Bare image, not `cupIcon` — `cupIcon`'s own .help would sit inside
                        // this Button's hit area and shadow the Button-level tooltip below
                        // whenever the pointer is directly over the cup glyph.
                        cupImage
                        // The sparkle marks "smart mode is on" — it stays lit whenever the
                        // mode is enabled, independent of whether an assertion is currently
                        // held. Before, an idle smart mode looked identical to everything-off.
                        Image(systemName: "sparkles")
                            .font(.system(size: 7))
                            .foregroundStyle(caffeinate.isKeepingAwake ? Color.orange : Color.accentColor)
                    }
                }
                .buttonStyle(.plain)
                .help(
                    caffeinate.isKeepingAwake
                        ? String(localized: "Keeping the Mac awake — an agent is running. Smart caffeinate is on; click to change in Settings.")
                        : String(localized: "Smart caffeinate is on — the Mac stays awake automatically while agents run. Click to change in Settings.")
                )
                .accessibilityLabel("Smart caffeinate is on")
                .accessibilityHint("Opens caffeinate settings")
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
            } else {
                cupIcon
                Toggle("Keep the Mac awake", isOn: $caffeinateEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    // The default accent tint at .mini size is nearly unreadable against
                    // the dark notch material — ON and OFF looked the same. Orange matches
                    // the lit cup, so one colour consistently means "caffeinated". The cup
                    // itself still shows assertion truth (it can lag the switch by the
                    // reconcile hop, and stays dark if the assertion ever fails) — the
                    // switch shows intent, the cup shows reality.
                    .tint(.orange)
                    .help(
                        caffeinate.isKeepingAwake
                            ? String(localized: "Keeping the Mac awake — switch off to allow sleep")
                            : String(localized: "Keep the Mac awake")
                    )
                    .accessibilityLabel("Keep the Mac awake")
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Bare cup glyph, no tooltip — use inside a container that supplies its own `.help`.
    private var cupImage: some View {
        Image(systemName: caffeinate.isKeepingAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
            .font(.caption)
            .foregroundStyle(caffeinate.isKeepingAwake ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .symbolRenderingMode(.hierarchical)
    }

    /// Cup glyph with its own tooltip — use standalone (not nested inside another control
    /// that already has a `.help`, or the two will shadow each other).
    private var cupIcon: some View {
        cupImage
            .help(
                caffeinate.isKeepingAwake
                    ? String(localized: "Keeping the Mac awake")
                    : String(localized: "Caffeinate — keep the Mac awake")
            )
    }

    /// Wraps a card/row in a click-through Button when the session's hosting app can be
    /// located — otherwise returns the content untouched: no hand cursor, no tooltip, no
    /// dead click. Help text lives on the Button only (a nested .help would shadow it).
    @ViewBuilder
    private func clickableSession<Content: View>(_ session: AgentSessionStatus, @ViewBuilder content: () -> Content) -> some View {
        if let target = AgentSessionOpener.target(for: session) {
            Button {
                if AgentSessionOpener.open(session) {
                    // The user is leaving for the other app; get the notch out of the way.
                    vm.close()
                }
            } label: {
                content()
            }
            .buttonStyle(.plain)
            .help(String(localized: "Open in \(target.appName)"))
            .accessibilityHint("Opens \(target.appName)")
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
        } else {
            content()
        }
    }

    @ViewBuilder
    private func primaryCard(_ session: AgentSessionStatus) -> some View {
        HStack(spacing: 12) {
            AgentProviderIconView(source: .init(rawProvider: session.provider), size: 28)
            VStack(alignment: .leading, spacing: 4) {
                AgentChatNameLabel(
                    text: session.providerLabel,
                    secondarySuffix: session.displayProjectName,
                    maxStaticLength: 18,
                    font: .headline,
                    nsFont: .headline,
                    textColor: .primary,
                    secondaryTextColor: .secondary,
                    marqueeWidth: 220
                )
                statusText(for: session, font: .subheadline)
                AgentChatNameLabel(
                    text: session.displayChatName,
                    font: .caption2,
                    textColor: .secondary,
                    marqueeWidth: 180
                )
            }
            Spacer(minLength: 0)
            stateBadge(session.displayState, sessionId: session.id, large: true)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(hasSkin ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.white.opacity(0.06)))
            if hasSkin {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.12))
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: AgentSessionStatus) -> some View {
        HStack(spacing: 10) {
            AgentProviderIconView(source: .init(rawProvider: session.provider), size: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    AgentChatNameLabel(
                        text: session.providerLabel,
                        secondarySuffix: session.displayProjectName,
                        maxStaticLength: 16,
                        font: .caption.weight(.semibold),
                        nsFont: .caption1,
                        textColor: .primary,
                        secondaryTextColor: .secondary,
                        marqueeWidth: 160
                    )
                }
                statusText(for: session, font: .caption2)
                AgentChatNameLabel(
                    text: session.displayChatName,
                    marqueeWidth: 140
                )
            }
            Spacer(minLength: 0)
            stateBadge(session.displayState, sessionId: session.id, large: false)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(hasSkin ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.white.opacity(0.04)))
            if hasSkin {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
            }
        }
    }

    @ViewBuilder
    private func statusText(for session: AgentSessionStatus, font: Font) -> some View {
        if session.displayState.isActiveRun, let startedAt = session.executionStartedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                (
                    Text(session.displayState.displayName).foregroundStyle(stateColor(session.displayState))
                    + Text(" " + formattedElapsed(since: startedAt, now: context.date))
                        .foregroundStyle(.secondary)
                )
                .font(font)
                .monospacedDigit()
            }
        } else {
            Text(session.displayState.displayName)
                .font(font)
                .foregroundStyle(stateColor(session.displayState))
        }
    }

    private func formattedElapsed(since start: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(start)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // Neon variants come from the user's palette choices; the defaults reproduce the
    // hand-tuned values this panel always used (see AgentTrafficLightPaletteColor.neonColor).
    private var neonRed: Color { stoppedPaletteColor.neonColor }
    private var neonYellow: Color { awaitingPaletteColor.neonColor }
    private var neonGreen: Color { activePaletteColor.neonColor }

    @ViewBuilder
    private func stateBadge(_ state: AgentTrafficLightState, sessionId: String, large: Bool) -> some View {
        let width: CGFloat = large ? 28 : 20
        let height: CGFloat = large ? 36 : 28
        let dotSize: CGFloat = large ? 8 : 6
        let blinkStart = redBlinkStartTimes[sessionId]
        let shouldBlink = state.showsRedTrafficLight && blinkStart.map { Date().timeIntervalSince($0) < 5 } ?? false

        VStack(spacing: 3) {
            if shouldBlink {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    let elapsed = context.date.timeIntervalSince(blinkStart ?? .now)
                    let pulse = (sin(elapsed * .pi * 4) + 1) / 2 // smooth 0...1 pulse, ~2 blinks/sec
                    neonDot(neonRed, size: dotSize, opacity: 0.35 + pulse * 0.65, glowRadius: 2 + pulse * (large ? 7 : 5))
                }
            } else {
                neonDot(neonRed, size: dotSize, opacity: state.showsRedTrafficLight ? 1 : 0.2, glowRadius: state.showsRedTrafficLight ? (large ? 5 : 3.5) : 0)
            }
            neonDot(neonYellow, size: dotSize, opacity: state.showsYellowTrafficLight ? 1 : 0.2, glowRadius: state.showsYellowTrafficLight ? (large ? 5 : 3.5) : 0)
            neonDot(neonGreen, size: dotSize, opacity: state.showsGreenTrafficLight ? 1 : 0.2, glowRadius: state.showsGreenTrafficLight ? (large ? 5 : 3.5) : 0)
        }
        .frame(width: width, height: height)
        .onChange(of: state.showsRedTrafficLight) { _, isRed in
            if isRed && (blinkStart == nil || Date().timeIntervalSince(blinkStart!) > 5) {
                redBlinkStartTimes[sessionId] = Date()
            }
        }
    }

    private func neonDot(_ color: Color, size: CGFloat, opacity: Double, glowRadius: CGFloat) -> some View {
        Circle()
            .fill(color.opacity(opacity))
            .frame(width: size, height: size)
            .shadow(color: color.opacity(opacity * 0.9), radius: glowRadius)
            .shadow(color: color.opacity(opacity * 0.5), radius: glowRadius * 2)
    }

    private func stateColor(_ state: AgentTrafficLightState) -> Color {
        switch state {
        case .executing, .thinking: return neonGreen
        case .awaitingInput: return neonYellow
        case .stopped: return neonRed
        case .inactive: return .secondary
        }
    }

    private func updateScrollGestureSuppression(for hovering: Bool) {
        guard hovering != isSuppressingScrollGesture else { return }
        isSuppressingScrollGesture = hovering
        vm.setScrollGestureSuppression(hovering, token: scrollSuppressionToken)
    }
}
