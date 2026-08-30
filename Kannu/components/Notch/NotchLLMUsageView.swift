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
    @ObservedObject private var manager = LLMUsageManager.shared

    /// Observed rather than read through `Defaults[...]` so the card redraws the moment the
    /// toggle below flips.
    @Default(.enableClaudeUsageDisplay) private var claudeUsageGaugesEnabled

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

    /// Claude's 5h/7d limits are the one figure that needs the network and a one-time keychain
    /// approval — everything else on the card is read from local files. The control lives here
    /// rather than in Settings so the cost is visible exactly where the benefit appears.
    private var claudeLimitsToggle: some View {
        Button {
            claudeUsageGaugesEnabled.toggle()
            // Skip the refresh floor so the gauges appear or vanish on the click, not on the
            // next poll. Nothing here prompts any more — the numbers come off disk.
            manager.refreshAll(force: true, interactive: false)
        } label: {
            Image(systemName: claudeUsageGaugesEnabled
                  ? "gauge.with.dots.needle.bottom.50percent"
                  : "gauge.with.dots.needle.bottom.50percent.badge.minus")
                .font(.caption)
                .foregroundStyle(claudeUsageGaugesEnabled ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help(claudeUsageGaugesEnabled
              ? "Hide rate-limit gauges. Plan, credits and token counts stay."
              : "Show the 5-hour and weekly rate-limit gauges.")
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
                    claudeLimitsToggle
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
                    quotaGauge(Self.rateLimitLabel(ClaudeUsageSnapshot.fiveHourKey), limit)
                } else {
                    localSessionRow(snap)
                }
                if let limit = snap.weekLimit {
                    quotaGauge(Self.rateLimitLabel(ClaudeUsageSnapshot.sevenDayKey), limit)
                }
                ForEach(snap.extraLimits, id: \.key) { extra in
                    quotaGauge(Self.extraLimitLabel(extra), extra.limit)
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

    @ViewBuilder
    private func quotaGauge(_ label: String, _ limit: UsageLimit) -> some View {
        let usedPct = Int(limit.used.rounded())
        let leftPct = max(0, 100 - usedPct)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let resets = resetsIn(limit.resetsAt) {
                    Text(resets).font(.caption2).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(gaugeTint(limit.fraction)).frame(width: max(4, geo.size.width * limit.fraction))
                }
            }
            .frame(height: 6)
            HStack {
                Text("\(usedPct)% used").font(.caption2).monospacedDigit()
                Spacer()
                Text("\(leftPct)% left").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func gaugeTint(_ fraction: Double) -> Color {
        if fraction > 0.95 { return .red }
        if fraction > 0.9 { return .orange }
        return .accentColor
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
