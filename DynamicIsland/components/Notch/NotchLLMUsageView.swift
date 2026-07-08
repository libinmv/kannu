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

    private func isEnabled(_ provider: ProviderID) -> Bool { Defaults[provider.enabledKey] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button {
                    manager.refreshAll(force: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(manager.isRefreshing)
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(ProviderID.allCases.filter { isEnabled($0) }) { provider in
                    card(for: provider)
                }
            }
        }
        .padding(.horizontal, 8)
        .onAppear { manager.refreshAll(force: true) }
    }

    @ViewBuilder
    private func card(for provider: ProviderID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AgentProviderIconView(source: .init(providerID: provider), size: 24)
                Text(provider.displayName).font(.headline)
                Spacer(minLength: 0)
            }
            switch manager.results[provider] ?? .loading {
            case .loading:
                ProgressView().controlSize(.small)
            case .failure(let reason):
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            case .success(let snap):
                success(snap)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func success(_ snap: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if snap.sessionLimit == nil && snap.weekLimit == nil {
                if snap.logsUnavailable {
                    Text("No local usage logs yet").font(.caption2).foregroundStyle(.secondary)
                } else {
                    window("Today", snap.today, prominent: true)
                    window("Week", snap.week)
                    window("Session", snap.session)
                }
                if let quotaError = snap.quotaError {
                    Text(quotaError).font(.caption2).foregroundStyle(.orange).lineLimit(3)
                } else {
                    Text("quota unavailable").font(.caption2).foregroundStyle(.secondary.opacity(0.7))
                }
            } else {
                if let limit = snap.sessionLimit { quotaGauge("Session", limit) }
                if let limit = snap.weekLimit { quotaGauge("Week", limit) }
                if snap.logsUnavailable {
                    Text("Token totals unavailable (no local logs)").font(.caption2).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        window("Today", snap.today, compact: true)
                        window("Week", snap.week, compact: true)
                    }
                }
                if let quotaError = snap.quotaError {
                    Text(quotaError).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
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
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "resets in \(hours)h \(minutes)m" : "resets in \(minutes)m"
    }

    private func window(_ label: String, _ totals: UsageTotals, prominent: Bool = false, compact: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: compact ? 34 : 48, alignment: .leading)
            Text(tokens(totals.totalTokens))
                .font(.system(size: compact ? 11 : (prominent ? 17 : 13), weight: prominent ? .bold : .semibold, design: .rounded))
                .monospacedDigit()
            Spacer(minLength: 4)
            Text(totals.hasUnpricedModel ? money(totals.costUSD) + "+" : money(totals.costUSD))
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
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
