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

struct NotchLLMUsageView: View {
    @ObservedObject private var agentMonitor = CursorAgentStatusMonitor.shared
    @ObservedObject private var manager = LLMUsageManager.shared

    // Live only while the tab is visible. Fires faster than the manager's refresh floor so a
    // tick landing just inside the floor doesn't stretch the effective cadence.
    //
    // `static` for publisher identity: a plain `let` on a struct View is re-evaluated on every
    // re-render, and `manager` is an @ObservedObject that re-renders this card several times
    // per refresh — each re-render handed `.onReceive` a brand-new timer whose 30s countdown
    // restarted from zero, so the poll could starve indefinitely while the tab was open.
    private static let pollTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private func isEnabled(_ provider: ProviderID) -> Bool { Defaults[provider.enabledKey] }

    /// A provider is "active" (shows full card) when:
    /// - Antigravity: always shown (session info instead of token counts)
    /// - Others: show unless result is a hard .failure, OR a .success where the provider
    ///   has neither local logs nor quota limits (e.g. Claude with a dead OAuth token, Codex
    ///   not installed — both return .success but have nothing useful to display).
    private func isActiveProvider(_ provider: ProviderID) -> Bool {
        if provider == .antigravity { return true }
        switch manager.results[provider] {
        case .failure:
            return false   // hard API error
        case .success(let snap) where snap.isFatallyUnconfigured:
            return false   // signed out / not installed — omit the card entirely
        case .loading, .success, .none:
            return true
        }
    }

    var body: some View {
        let enabled = ProviderID.allCases.filter { isEnabled($0) }
        let active = enabled.filter { isActiveProvider($0) }

        VStack(alignment: .leading, spacing: 6) {
            // Refresh control moved to KannuHeader, next to the clipboard icon
            // (icon-only, shown while this tab is active) — no longer needed here.
            HStack(alignment: .top, spacing: 10) {
                ForEach(active) { provider in
                    card(for: provider)
                }
            }
        }
        .padding(.horizontal, 8)
        // Deliberately not forced: this fires on every open of the tab, and forcing bypasses
        // the refresh floor entirely — which is how the quota API ends up rate-limiting us.
        // The Refresh button above still forces, because a user pressing it means it.
        .onAppear { manager.refreshAll() }
        // Keep the card current while it stays open; the manager's floor still paces the
        // actual work, so this can never poll harder than once a minute.
        .onReceive(Self.pollTimer) { _ in manager.refreshAll() }
    }

    @ViewBuilder
    private func card(for provider: ProviderID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AgentProviderIconView(source: .init(providerID: provider), size: 24)
                Text(provider.displayName).font(.headline)
                if case .success(let snap) = manager.results[provider] ?? .loading,
                   let tier = snap.accountTier {
                    Text(tier)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if provider == .claude {
                    claudeRefreshButton
                }
            }
            if case .success(let snap) = manager.results[provider] ?? .loading,
               let note = snap.accountNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.9))
            }
            switch manager.results[provider] ?? .loading {
            case .loading:
                ProgressView().controlSize(.small)
            case .failure(let reason):
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            case .success(let snap):
                if provider == .antigravity {
                    antigravitySessionInfo(snap)
                } else {
                    success(snap, provider: provider)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func antigravitySessionInfo(_ snap: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let info = snap.quotaError {
                Text(info)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else {
                Text("No recent sessions")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }


    @ViewBuilder
    private func success(_ snap: UsageSnapshot, provider: ProviderID) -> some View {
        let hasPartialEstimate = snap.today.hasUnpricedModel || snap.week.hasUnpricedModel || snap.session.hasUnpricedModel
        let showsQuota = snap.sessionLimit != nil || snap.weekLimit != nil || !snap.extraLimits.isEmpty
        let showEstimatedCost = !snap.billedCostOnly
        VStack(alignment: .leading, spacing: 6) {
            if !showsQuota {
                if snap.logsUnavailable {
                    Text("No local usage logs yet").font(.caption2).foregroundStyle(.secondary)
                } else {
                    window("Today", snap.today, prominent: true, showCost: showEstimatedCost)
                    window("Week", snap.week, showCost: showEstimatedCost)
                    window("Session", snap.session, showCost: showEstimatedCost)
                }
                localSessionRow(snap)
                if let quotaError = snap.quotaError {
                    Text(quotaError).font(.caption2).foregroundStyle(.orange).lineLimit(4)
                } else if snap.localSessionBlock == nil {
                    Text("quota unavailable").font(.caption2).foregroundStyle(.secondary.opacity(0.7))
                }
                quotaActionButton(snap.quotaAction)
            } else {
                if let limit = snap.sessionLimit {
                    quotaSection(title: "Session", reset: limit.resetsAt, bars: [.init(limit)])
                } else {
                    localSessionRow(snap)
                }
                if let week = snap.weekLimit {
                    // The word "Weekly" and the shared reset live once on the header; the bars below
                    // are just "All models" and each per-model name. Per-model windows share the
                    // week's reset, so the header countdown covers them.
                    quotaSection(
                        title: "Weekly",
                        reset: week.resetsAt,
                        bars: [.init(week, label: "All models")]
                            + snap.extraLimits.map { .init($0.limit, label: $0.label ?? Self.extraLimitLabel($0)) }
                    )
                } else if !snap.extraLimits.isEmpty {
                    quotaSection(
                        title: "Weekly",
                        reset: snap.extraLimits.first?.limit.resetsAt,
                        bars: snap.extraLimits.map { .init($0.limit, label: $0.label ?? Self.extraLimitLabel($0)) }
                    )
                }
                // Claude's Session/Week quota gauges above already cover this ground —
                // the compact Today/Week token counts were redundant for Claude specifically.
                // Other providers (e.g. Cursor, Codex) keep them.
                if provider != .claude {
                    if snap.logsUnavailable {
                        Text("Token totals unavailable").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            window("Today", snap.today, compact: true, showCost: false)
                            window("Week", snap.week, compact: true, showCost: false)
                        }
                    }
                }
                if let onDemand = snap.onDemandSpendUSD {
                    onDemandSpendRow(onDemand)
                } else if !snap.logsUnavailable && showEstimatedCost {
                    onDemandSpendRow(snap.week.costUSD, partial: snap.week.hasUnpricedModel)
                }
                if let quotaError = snap.quotaError {
                    Text(quotaError).font(.caption2).foregroundStyle(.secondary).lineLimit(4)
                }
                quotaActionButton(snap.quotaAction)
            }
            if hasPartialEstimate && !showsQuota && showEstimatedCost {
                Text("Some models are unpriced; totals are partial estimates.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One-tap fix for a quota failure the user can actually resolve (e.g. approving the
    /// keychain read Claude Code's login lives behind). Only this button may trigger a prompt.
    @ViewBuilder
    private func quotaActionButton(_ action: QuotaAction?) -> some View {
        if let action {
            Button {
                manager.resolveQuotaAction(action)
            } label: {
                Text(action.buttonTitle)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func onDemandSpendRow(_ amount: Double, partial: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("On-demand")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Spacer(minLength: 4)
            Text(partial ? money(amount) + "+" : money(amount))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// Locally reconstructed 5-hour block: tokens spent + reset countdown. Labeled local and
    /// never a percentage — the plan's budget only exists server-side.
    @ViewBuilder
    private func localSessionRow(_ snap: UsageSnapshot) -> some View {
        if let block = snap.localSessionBlock {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Session (local)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(compactTokens(block.totalTokens))
                    .font(.caption2)
                    .monospacedDigit()
                if let resets = resetsIn(block.resetsAt) {
                    Text(resets)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func compactTokens(_ tokens: Int) -> String {
        switch tokens {
        case ..<1_000: return "\(tokens) tok"
        case ..<1_000_000: return String(format: "%.1fK tok", Double(tokens) / 1_000)
        default: return String(format: "%.1fM tok", Double(tokens) / 1_000_000)
        }
    }

    @ViewBuilder
    /// Names an extra window, preferring the label its provider supplied.
    ///
    /// Per-model weekly windows are named by the server ("Fable"), not by a key we could recognise,
    /// so a derived name would be a guess where a real one was already sent.
    static func extraLimitLabel(_ extra: NamedLimit) -> String {
        if let label = extra.label {
            return String(localized: "Weekly (\(label))")
        }
        return rateLimitLabel(extra.key)
    }

    /// Names a rate-limit window for display.
    ///
    /// These are usage caps, not the token/cost windows listed below them, so they must not reuse
    /// "Session" and "Week" — the same two words meaning something else in the same card was the
    /// original confusion. Windows beyond the two universal ones are named from the provider's own
    /// key, so a newly added cap renders with a sensible label rather than being dropped.
    static func rateLimitLabel(_ key: String) -> String {
        switch key {
        case ClaudeUsageSnapshot.fiveHourKey:
            return String(localized: "5-hour session")
        case ClaudeUsageSnapshot.sevenDayKey:
            return String(localized: "Weekly (all models)")
        default:
            let suffix = key.hasPrefix("seven_day_")
                ? String(key.dropFirst("seven_day_".count))
                : key
            let name = suffix.split(separator: "_").map(\.capitalized).joined(separator: " ")
            return key.hasPrefix("seven_day")
                ? String(localized: "Weekly (\(name))")
                : name
        }
    }

    /// One bar in a quota section: an optional label (nil for a single-bar section), the value,
    /// and the accent already resolved from severity-or-fraction.
    private struct QuotaBar: Identifiable {
        let id = UUID()
        let label: String?
        let fraction: Double
        let percent: Int
        let tint: Color

        init(_ limit: UsageLimit, label: String? = nil) {
            self.label = label
            self.fraction = limit.fraction
            self.percent = Int(limit.used.rounded())
            self.tint = NotchLLMUsageView.accent(severity: limit.severity, fraction: limit.fraction)
        }
    }

    /// Pulls the latest usage from Claude Code, including the per-model (Fable) weekly window that
    /// only its own `/usage` fetch produces. Sits top-right of the Claude card with a help tooltip.
    @ViewBuilder
    private var claudeRefreshButton: some View {
        Button {
            agentMonitor.refreshClaudeUsageFromCLI()
        } label: {
            if agentMonitor.isRefreshingClaudeUsage {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "arrow.clockwise").font(.caption)
            }
        }
        .buttonStyle(.plain)
        .disabled(agentMonitor.isRefreshingClaudeUsage)
        .foregroundStyle(.secondary)
        .help("Fetch your latest Claude usage, including the per-model weekly limit. Uses your existing Claude login — one-time keychain approval, no message cost.")
    }

    /// A titled group of bars sharing one reset countdown — "Session" (one bar) or "Weekly"
    /// (all-models plus any per-model windows). The title and the countdown appear once.
    @ViewBuilder
    private func quotaSection(title: String, reset: Date?, bars: [QuotaBar]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let resets = resetsIn(reset) {
                    Text(resets).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            ForEach(bars) { bar in quotaBar(bar) }
        }
    }

    @ViewBuilder
    private func quotaBar(_ bar: QuotaBar) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(bar.tint)
                        .frame(width: max(4, geo.size.width * bar.fraction))
                }
            }
            .frame(height: 6)
            HStack(spacing: 6) {
                if let label = bar.label {
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("\(bar.percent)%").font(.caption2.weight(.medium)).monospacedDigit()
                    .foregroundStyle(bar.tint == .accentColor ? Color.primary : bar.tint)
            }
        }
    }

    /// The bar accent: the server's own severity when it reported one, else the fraction bands.
    private static func accent(severity: String?, fraction: Double) -> Color {
        switch severity?.lowercased() {
        case "critical": return .red
        case "warning": return .orange
        case "normal": return .accentColor
        default:
            if fraction > 0.95 { return .red }
            if fraction > 0.9 { return .orange }
            return .accentColor
        }
    }

    private func resetsIn(_ date: Date?) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSinceNow)
        guard seconds > 0 else { return nil }
        let minutes = seconds / 60
        let days = minutes / (60 * 24)
        let hours = (minutes / 60) % 24
        // Only the units that carry information: a span over a day reads "2d 22h 37m", a shorter one
        // "4h 56m", and under an hour just "56m" — a leading "0h" is noise on a glanceable gauge.
        if days > 0 {
            return "resets in \(days)d \(hours)h \(minutes % 60)m"
        }
        if hours > 0 {
            return "resets in \(hours)h \(minutes % 60)m"
        }
        return "resets in \(minutes)m"
    }

    private func window(
        _ label: String,
        _ totals: UsageTotals,
        prominent: Bool = false,
        compact: Bool = false,
        showCost: Bool = true
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: compact ? 34 : 48, alignment: .leading)
            Text(tokens(totals.totalTokens))
                .font(.system(size: compact ? 11 : (prominent ? 17 : 13), weight: prominent ? .bold : .semibold, design: .rounded))
                .monospacedDigit()
            Spacer(minLength: 4)
            if showCost {
                Text(totals.hasUnpricedModel ? money(totals.costUSD) + "+" : money(totals.costUSD))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fk", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    // Locale-aware formatting pinned to USD — amounts come from the USD pricing table, so the currency code stays fixed.
    private static let currencyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        return f
    }()

    private func money(_ v: Double) -> String {
        Self.currencyFormatter.string(from: v as NSNumber) ?? String(format: "$%.2f", v)
    }
}
