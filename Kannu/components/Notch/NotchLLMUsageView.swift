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

/// The Usage tab: one card per enabled provider, side by side, every size from
/// `UsageCardMetrics` so a card fits the open notch (the notch never grows for it) and its two
/// columns — the 5-hour window and the weekly stack — split in the golden ratio, in the timer
/// tab's type and fills.
struct NotchLLMUsageView: View {
    @Environment(\.notchForeground) private var notchForeground
    private typealias M = UsageCardMetrics

    @ObservedObject private var agentMonitor = CursorAgentStatusMonitor.shared
    @ObservedObject private var usageAlerts = UsageAlertManager.shared
    @ObservedObject private var manager = LLMUsageManager.shared
    @EnvironmentObject private var vm: KannuViewModel

    /// The snapshot board's overrides; nil in the app.
    var snapshotResults: [ProviderID: UsageResult]? = nil
    var snapshotRefreshStatus: ClaudeRefreshStatus? = nil
    var snapshotOutlooks: [String: UsageForecast.Outlook]? = nil
    var snapshotNotchWidth: CGFloat? = nil

    // Live only while the tab is visible. Fires faster than the manager's refresh floor so a
    // tick landing just inside the floor doesn't stretch the effective cadence.
    //
    // `static` for publisher identity: a plain `let` on a struct View is re-evaluated on every
    // re-render, and `manager` is an @ObservedObject that re-renders this card several times
    // per refresh — each re-render handed `.onReceive` a brand-new timer whose 30s countdown
    // restarted from zero, so the poll could starve indefinitely while the tab was open.
    private static let pollTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private func isEnabled(_ provider: ProviderID) -> Bool {
        if let snapshotResults { return snapshotResults[provider] != nil }
        return Defaults[provider.enabledKey]
    }

    private func result(for provider: ProviderID) -> UsageResult {
        (snapshotResults ?? manager.results)[provider] ?? .loading
    }

    private var outlooks: [String: UsageForecast.Outlook] { snapshotOutlooks ?? usageAlerts.outlooks }

    /// A provider is "active" (shows full card) when:
    /// - Antigravity: always shown (its quota bars when `agy` reports them, else session info)
    /// - Others: show unless result is a hard .failure, OR a .success where the provider
    ///   has neither local logs nor quota limits (e.g. Claude with a dead OAuth token, Codex
    ///   not installed — both return .success but have nothing useful to display).
    private func isActiveProvider(_ provider: ProviderID) -> Bool {
        if provider == .antigravity { return true }
        switch result(for: provider) {
        case .failure:
            return false   // hard API error
        case .success(let snap) where snap.isFatallyUnconfigured:
            return false   // signed out / not installed — omit the card entirely
        case .loading, .success:
            return true
        }
    }

    var body: some View {
        let active = ProviderID.allCases.filter { isEnabled($0) && isActiveProvider($0) }
        let innerWidth = M.cardInnerWidth(notchWidth: snapshotNotchWidth ?? vm.notchSize.width, cards: active.count)

        // The tab's Refresh control lives in KannuHeader's trailing row, with the items that come
        // and go, left of the fixed buttons (icon-only, shown while this tab is active).
        HStack(alignment: .top, spacing: M.cardSpacing) {
            ForEach(active) { provider in
                card(for: provider, innerWidth: innerWidth)
            }
        }
        .padding(.horizontal, M.tabHorizontalPadding)
        // Deliberately not forced: this fires on every open of the tab, and forcing bypasses
        // the refresh floor entirely — which is how the quota API ends up rate-limiting us.
        // The Refresh button above still forces, because a user pressing it means it.
        .onAppear {
            guard snapshotResults == nil else { return }
            manager.refreshAll()
            refreshClaudeLimitsIfStale()
        }
        // Keep the card current while it stays open; the manager's floor still paces the
        // actual work, so this can never poll harder than once a minute.
        .onReceive(Self.pollTimer) { _ in
            guard snapshotResults == nil else { return }
            manager.refreshAll()
            refreshClaudeLimitsIfStale()
        }
    }

    // MARK: - One card

    /// Header, body and (at most) one status row on the glass the timer's rows sit on. The body
    /// lives under a minute clock: "resets in" is computed from `now` at render, and without a
    /// clock this view only re-rendered when something republished (the 180 s refresh floor at
    /// best), so the countdown sat frozen for minutes. The same `now` drops a window whose reset
    /// has passed.
    @ViewBuilder
    private func card(for provider: ProviderID, innerWidth: CGFloat) -> some View {
        let result = result(for: provider)
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let status = statusLine(for: provider, result: result)
            let stale = staleLabel(for: result, now: now)
            VStack(alignment: .leading, spacing: M.rowSpacing) {
                header(for: provider, result: result, stale: stale)
                body(for: provider, result: result, innerWidth: innerWidth, hasStatus: status != nil, now: now)
                if let status {
                    statusRow(status)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(M.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: M.cardCornerRadius, style: .continuous)
                    .fill(notchForeground.opacity(M.cardFill))
            )
        }
    }

    @ViewBuilder
    private func header(for provider: ProviderID, result: UsageResult, stale: String?) -> some View {
        HStack(spacing: M.rowSpacing) {
            AgentProviderIconView(source: .init(providerID: provider), size: M.providerIconSize)
            Text(provider.displayName)
                .font(Self.font(M.titleFontSize, .semibold))
                .lineLimit(1)
            if case .success(let snap) = result, let tier = snap.accountTier {
                UsageChip(tier)
            }
            if case .success(let snap) = result, let note = snap.accountNote {
                UsageChip(note, tint: .orange, truncates: true)
            }
            Spacer(minLength: 0)
            if let stale {
                // A reading older than half an hour is said so in the header, not in a row of
                // its own: the card has no height to spare. Its bars are dimmed below.
                Image(systemName: "clock")
                    .font(Self.font(M.glyphFontSize, .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: M.headerRowHeight, height: M.headerRowHeight)
                    .contentShape(Rectangle())
                    .accessibilityLabel(stale)
                    .hoverTooltip(stale, edge: .below)
            }
            if provider == .claude {
                claudeRefreshButton
            }
        }
        .frame(height: M.headerRowHeight)
    }

    // MARK: - Bodies

    @ViewBuilder
    private func body(for provider: ProviderID, result: UsageResult, innerWidth: CGFloat,
                      hasStatus: Bool, now: Date) -> some View {
        switch result {
        case .loading:
            ProgressView().controlSize(.mini)
                .frame(height: M.barRowHeight)
        case .failure(let reason):
            note(reason, lines: 2)
        case .success(let snap):
            if provider == .antigravity && snap.sessionLimit == nil && snap.weekLimit == nil && snap.extraLimits.isEmpty {
                note(snap.quotaError ?? String(localized: "No recent sessions"), lines: 2)
            } else {
                quotaBody(snap, provider: provider, innerWidth: innerWidth, hasStatus: hasStatus, now: now)
            }
        }
    }

    @ViewBuilder
    private func quotaBody(_ snap: UsageSnapshot, provider: ProviderID, innerWidth: CGFloat,
                           hasStatus: Bool, now: Date) -> some View {
        let sessions = sessionBars(snap, provider: provider, now: now)
        let weekly = weeklyBars(snap, provider: provider, now: now)
        let showCost = !snap.billedCostOnly
        if sessions.isEmpty && weekly.isEmpty {
            // No server-side windows: the local token totals are all there is.
            VStack(alignment: .leading, spacing: M.noteRowSpacing) {
                if snap.logsUnavailable {
                    note(String(localized: "No local usage logs yet"))
                } else {
                    fact(String(localized: "Today"), snap.today, showCost: showCost)
                    fact(String(localized: "Week"), snap.week, showCost: showCost)
                    fact(String(localized: "Session"), snap.session, showCost: showCost)
                }
                if let block = snap.localSessionBlock {
                    note(String(localized: "Session (local) \(Self.compactTokens(block.totalTokens))")
                         + (resetsIn(block.resetsAt, now: now).map { " · " + $0 } ?? ""))
                }
            }
        } else if !sessions.isEmpty, let columns = M.columns(innerWidth: innerWidth) {
            // The card's two things, side by side in the golden ratio: the 5-hour window (now) is
            // the minor part, the weekly stack (the trend) the major one.
            HStack(alignment: .top, spacing: M.columnSpacing) {
                fiveHourColumn(sessions, now: now)
                    .frame(width: columns.minor, alignment: .leading)
                weeklyColumn(weekly, snap: snap, provider: provider, hasStatus: hasStatus, showCost: showCost, now: now)
                    .frame(width: columns.major, alignment: .leading)
            }
        } else if sessions.isEmpty {
            // One window only (Cursor's billing cycle): one column across the card.
            weeklyColumn(weekly, snap: snap, provider: provider, hasStatus: hasStatus, showCost: showCost, now: now)
        } else {
            stackedBody(sessions: sessions, weekly: weekly, now: now)
        }
    }

    /// Title, bar, the reset, and the forecast in the few words that fit — or an empty line,
    /// so the column's height never depends on the forecast. One bar, as `fiveHourColumnHeight`
    /// budgets: another pool's 5-hour window (Antigravity) folds into a "+n" chip beside the title,
    /// as the weekly column's overflow does.
    @ViewBuilder
    private func fiveHourColumn(_ bars: [QuotaBar], now: Date) -> some View {
        let first = bars[0]
        let folded = Array(bars.dropFirst())
        let forecast = outlooks[first.windowID].flatMap { UsageForecast.shortCaption($0, resetsAt: first.resetsAt, now: now) }
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(String(localized: "5 hour"), trailing: nil) {
                if !folded.isEmpty {
                    UsageChip("+\(folded.count)")
                        .accessibilityLabel(Self.foldedSummary(folded))
                        .hoverTooltip(Self.foldedSummary(folded), edge: .below)
                }
            }
            Spacer().frame(height: M.sectionTitleSpacing)
            barRow(first, warning: forecast?.isWarning == true, tooltip: nil)
                .opacity(Self.isStale(first, now: now) ? M.staleOpacity : 1)
            Spacer().frame(height: M.noteRowSpacing)
            note(resetsIn(first.resetsAt, now: now) ?? "")
            Spacer().frame(height: M.noteRowSpacing)
            note(forecast?.text ?? "", tint: forecast?.isWarning == true ? .orange : nil, quiet: true)
        }
    }

    /// "Weekly" (or "Billing cycle") with the shared reset beside it, then the bars — all models
    /// first, each per-model window after — capped at what fits; the rest fold into a "+n" chip.
    @ViewBuilder
    private func weeklyColumn(_ bars: [QuotaBar], snap: UsageSnapshot, provider: ProviderID,
                              hasStatus: Bool, showCost: Bool, now: Date) -> some View {
        let limit = M.maxWeeklyBars(statusRow: hasStatus, factRows: Self.showsTokenTotals(provider) ? 2 : 0)
        let shown = Array(bars.prefix(limit))
        let folded = Array(bars.dropFirst(limit))
        let reset = bars.first?.resetsAt
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(Self.cycleTitle(for: provider), trailing: resetsIn(reset, now: now)) {
                if !folded.isEmpty {
                    // The windows that did not fit, named on hover; beside the title so the reset
                    // keeps its room.
                    UsageChip("+\(folded.count)")
                        .accessibilityLabel(Self.foldedSummary(folded))
                        .hoverTooltip(Self.foldedSummary(folded), edge: .below)
                }
            }
            Spacer().frame(height: M.sectionTitleSpacing)
            VStack(alignment: .leading, spacing: M.barRowSpacing) {
                ForEach(shown) { bar in
                    let caption = outlooks[bar.windowID].flatMap { UsageForecast.caption($0, resetsAt: bar.resetsAt, now: now) }
                    barRow(bar, warning: caption?.isWarning == true, tooltip: caption?.text)
                        .opacity(Self.isStale(bar, now: now) ? M.staleOpacity : 1)
                }
            }
            if Self.showsTokenTotals(provider) {
                // Codex and Cursor keep their token totals, in the room under the single bar.
                // Antigravity keeps no token log at all, so there is no "unavailable" to report.
                Spacer().frame(height: M.noteRowSpacing)
                if snap.logsUnavailable {
                    note(String(localized: "Token totals unavailable"))
                } else {
                    fact(String(localized: "Today"), snap.today, showCost: false)
                    Spacer().frame(height: M.noteRowSpacing)
                    fact(String(localized: "Week"), snap.week, showCost: showCost, onDemand: snap.onDemandSpendUSD)
                }
            }
        }
    }

    /// Whether the weekly column draws the two token-total rows under its bars: Claude's gauges
    /// cover that ground, and Antigravity keeps no token log. `maxWeeklyBars` budgets for them.
    static func showsTokenTotals(_ provider: ProviderID) -> Bool {
        provider != .claude && provider != .antigravity
    }

    /// Too narrow for two columns (three cards in a 640 pt notch): every bar labelled, in one
    /// stack, then one line for both resets.
    @ViewBuilder
    private func stackedBody(sessions: [QuotaBar], weekly: [QuotaBar], now: Date) -> some View {
        // The lone 5-hour bar is named "5 hour" here, where it has no section title of its own.
        let first = sessions.enumerated().map { index, bar in
            index == 0 && bar.label == nil ? bar.labelled(String(localized: "5 hour")) : bar
        }
        let bars = Array((first + weekly).prefix(M.maxStackedBars))
        let resets = [sessions.first.flatMap { resetsIn($0.resetsAt, now: now) }.map { String(localized: "5h \($0)") },
                      weekly.first.flatMap { resetsIn($0.resetsAt, now: now) }.map { String(localized: "week \($0)") }]
            .compactMap { $0 }
        VStack(alignment: .leading, spacing: M.barRowSpacing) {
            ForEach(bars) { bar in
                let caption = outlooks[bar.windowID].flatMap { UsageForecast.caption($0, resetsAt: bar.resetsAt, now: now) }
                barRow(bar, warning: caption?.isWarning == true, tooltip: caption?.text)
                    .opacity(Self.isStale(bar, now: now) ? M.staleOpacity : 1)
            }
            note(resets.joined(separator: " · "))
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func sectionTitle<Badge: View>(_ title: String, trailing: String?,
                                           @ViewBuilder badge: () -> Badge = { EmptyView() }) -> some View {
        HStack(spacing: M.rowSpacing) {
            Text(title)
                .font(Self.font(M.textFontSize, .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            badge()
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(Self.font(M.textFontSize, .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .frame(height: M.sectionTitleHeight)
    }

    /// `[label] [bar] [percent]` on one line. A forecast that warns tints the bar and the percent
    /// orange; its words are the row's tooltip, since the card has no row to spare for them.
    @ViewBuilder
    private func barRow(_ bar: QuotaBar, warning: Bool, tooltip: String?) -> some View {
        let tint = warning && bar.tint == .accentColor ? Color.orange : bar.tint
        let row = HStack(spacing: M.rowSpacing) {
            if let label = bar.label {
                Text(label)
                    .font(Self.font(M.textFontSize, .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: M.barLabelWidth, alignment: .leading)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(notchForeground.opacity(M.barTrackOpacity))
                    Capsule().fill(tint)
                        .frame(width: max(M.barMinimumFill, geo.size.width * bar.fraction))
                }
            }
            .frame(height: M.barHeight)
            Text("\(bar.percent)%")
                .font(Self.font(M.valueFontSize, .semibold))
                .monospacedDigit()
                .foregroundStyle(tint == .accentColor ? Color.primary : tint)
                .frame(width: M.percentWidth, alignment: .trailing)
        }
        .frame(height: M.barRowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bar.label ?? String(localized: "5 hour"))
        .accessibilityValue(tooltip.map { "\(bar.percent)%, \($0)" } ?? "\(bar.percent)%")
        if let tooltip {
            row.contentShape(Rectangle()).hoverTooltip(tooltip, edge: .above)
        } else {
            row
        }
    }

    /// A line of quiet text: a reset, a forecast, a fact, a reason. Always one note row tall.
    @ViewBuilder
    private func note(_ text: String, tint: Color? = nil, quiet: Bool = false, lines: Int = 1) -> some View {
        Text(text)
            .font(Self.font(M.textFontSize, .medium))
            .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(quiet ? .tertiary : .secondary))
            .monospacedDigit()
            .lineLimit(lines)
            .truncationMode(.tail)
            .frame(height: M.noteRowHeight * CGFloat(lines), alignment: .leading)
    }

    /// "Today 1.2M · $3.40": a token window's total, and its cost when the provider prices it.
    private func fact(_ label: String, _ totals: UsageTotals, showCost: Bool, onDemand: Double? = nil) -> some View {
        note(Self.factText(label, totals, showCost: showCost, onDemand: onDemand))
    }

    static func factText(_ label: String, _ totals: UsageTotals, showCost: Bool, onDemand: Double?) -> String {
        var parts = [label + " " + tokens(totals.totalTokens)]
        if let onDemand {
            parts.append(String(localized: "On-demand \(money(onDemand))"))
        } else if showCost {
            parts.append(totals.hasUnpricedModel ? money(totals.costUSD) + "+" : money(totals.costUSD))
        }
        return parts.joined(separator: " · ")
    }

    /// One row for whatever the card needs the user to know, the action beside it: the card is a
    /// fixed height inside the notch, and stacked notes pushed the button out of view.
    @ViewBuilder
    private func statusRow(_ status: StatusLine) -> some View {
        HStack(spacing: M.rowSpacing) {
            // One line beside its button cuts a long message short; the whole of it is on hover.
            Text(status.text)
                .font(Self.font(M.textFontSize, .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .hoverTooltip(status.text, edge: .above, alignment: .leading)
            Spacer(minLength: 0)
            if let action = status.action {
                let button = Button(action: action.run) {
                    UsageChip(action.title, tint: .primary)
                }
                .buttonStyle(.plain)
                .fixedSize()
                if let tooltip = status.tooltip {
                    button.hoverTooltip(tooltip, edge: .above)
                } else {
                    button
                }
            }
        }
        .frame(height: M.statusRowHeight)
    }

    /// Fetches the latest Claude limits with Claude Code's own `/usage`, and starts Claude Code's
    /// claude.ai sign-in when that finds no plan data. Sits top-right of the Claude card.
    @ViewBuilder
    private var claudeRefreshButton: some View {
        let refreshing = snapshotRefreshStatus == .signingIn || agentMonitor.isRefreshingClaudeUsage
        Button {
            // Only kick off the fetch. Refreshing the providers here would race it: the fetch is
            // seconds long and async, so a refresh fired now reads the pre-fetch cache and paints
            // stale numbers. The monitor's completion handler redraws once the new data is in.
            agentMonitor.refreshClaudeUsageFromCLI()
        } label: {
            Group {
                if refreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(Self.font(M.glyphFontSize, .semibold))
                }
            }
            .frame(width: M.headerRowHeight, height: M.headerRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(refreshing)
        .foregroundStyle(.secondary)
        // Icon-only, so VoiceOver would otherwise announce the SF Symbol name.
        .accessibilityLabel(String(localized: "Fetch latest usage"))
        // Native .help() is dead in the notch: Kannu is an LSUIElement accessory app whose panel
        // never becomes active, so AppKit's tooltip manager never runs. This draws its own, below:
        // the button sits at the notch's top edge.
        .hoverTooltip(String(localized: "Fetch latest usage"), edge: .below)
    }

    // MARK: - What the card says

    private struct StatusLine {
        let text: String
        var action: (title: String, run: () -> Void)? = nil
        var tooltip: String? = nil
    }

    /// One status at a time, in this order: what the Claude refresh found (the user's own action
    /// is pending), then a quota failure with its one-tap fix, then a quota failure alone.
    private func statusLine(for provider: ProviderID, result: UsageResult) -> StatusLine? {
        if provider == .claude, let line = claudeStatus { return line }
        guard case .success(let snap) = result else { return nil }
        if let action = snap.quotaAction {
            return StatusLine(text: snap.quotaError ?? String(localized: "Limits need your approval"),
                              action: (action.buttonTitle, { manager.resolveQuotaAction(action) }))
        }
        if let error = snap.quotaError { return StatusLine(text: error) }
        if snap.sessionLimit == nil, snap.weekLimit == nil, snap.extraLimits.isEmpty,
           snap.localSessionBlock == nil, !snap.logsUnavailable, provider != .antigravity {
            return StatusLine(text: String(localized: "quota unavailable"))
        }
        return nil
    }

    /// What the last Refresh needs the user to know, with the one action that resolves it.
    /// Silent while a fetch runs, except for the sign-in, which is the user's to finish.
    private var claudeStatus: StatusLine? {
        let status = snapshotRefreshStatus ?? agentMonitor.claudeRefreshStatus
        let refreshing = snapshotRefreshStatus == nil && agentMonitor.isRefreshingClaudeUsage
        let terminal = (String(localized: "Sign in in Terminal"), { agentMonitor.openClaudeSignInInTerminal() })
        switch status {
        case .signingIn:
            return StatusLine(text: String(localized: "Finish signing in in your browser…"),
                              action: (String(localized: "Cancel"), { agentMonitor.cancelClaudeSignIn() }),
                              tooltip: String(localized: "Claude Code's own sign-in, the same as /login. Kannu never sees it."))
        case .signInNeeded where !refreshing:
            return StatusLine(text: String(localized: "Exact limits need Claude Code signed in to claude.ai. Press this card's ↻ to sign in."),
                              action: terminal)
        case .signInDidNotFinish where !refreshing:
            return StatusLine(text: String(localized: "The sign-in didn't finish. Press this card's ↻ to try again."),
                              action: terminal)
        case .noLimitsReturned where !refreshing:
            return StatusLine(text: String(localized: "Claude Code is signed in but returned no limits. Try ↻ again later."),
                              action: terminal)
        case .signInUnchecked where !refreshing:
            return StatusLine(text: String(localized: "Couldn't check how Claude Code signs in on this Mac."),
                              action: terminal)
        case .otherSignInMethod where !refreshing:
            return StatusLine(text: String(localized: "Claude Code here uses an API key or a cloud provider. Signing in with claude.ai replaces that for Claude Code."),
                              action: terminal)
        case .notInstalled where !refreshing:
            return StatusLine(text: String(localized: "No Claude Code signed by Anthropic was found, so exact limits can't be fetched."))
        case .fetchFailed where !refreshing:
            return StatusLine(text: String(localized: "Couldn't fetch the latest limits. Try ↻ again in a moment."))
        default:
            guard !refreshing else { return nil }
            switch agentMonitor.claudeUsageHint {
            case .signInNeeded:
                return StatusLine(text: String(localized: "Exact limits need a Claude Code sign-in. Press this card's ↻ to fetch them."))
            case .otherOrganization:
                let plans = agentMonitor.claudeOrganizationPlanNames
                if let code = plans.claudeCode, let desktop = plans.desktop, code != desktop {
                    return StatusLine(text: String(localized: "Claude Code is signed in to \(code), so these are Claude Desktop's (\(desktop)) readings. Sign Claude Code in to \(desktop), then press this card's ↻ for exact limits."),
                                      action: terminal)
                }
                return StatusLine(text: String(localized: "Claude Code is signed in to another organization, so these are Claude Desktop's readings. Sign it in to Claude Desktop's, then press this card's ↻."),
                                  action: terminal)
            case nil:
                return nil
            }
        }
    }

    /// The oldest reading on the card speaks for it: a value days old is said so in the header
    /// and dimmed, never passed off as current (a desktop sample can be that old).
    private func staleLabel(for result: UsageResult, now: Date) -> String? {
        guard case .success(let snap) = result else { return nil }
        let observed = ([snap.sessionLimit, snap.weekLimit].compactMap { $0 } + snap.extraLimits.map(\.limit))
            .compactMap(\.observedAt).min()
        return ClaudeUsageSnapshot.staleLabel(observedAt: observed, now: now)
    }

    private static func isStale(_ bar: QuotaBar, now: Date) -> Bool {
        ClaudeUsageSnapshot.staleLabel(observedAt: bar.observedAt, now: now) != nil
    }

    /// The weekly stack: all models first, then each per-model window, all live.
    private func weeklyBars(_ snap: UsageSnapshot, provider: ProviderID, now: Date) -> [QuotaBar] {
        var bars: [QuotaBar] = []
        if let week = snap.weekLimit, Self.isLive(week, now: now) {
            // Cursor's split plan names its first bar "Auto" and keys it apart from "week";
            // Antigravity's names the model pool it measures.
            bars.append(.init(week, label: snap.weekLimitLabel ?? snap.limitsLabel ?? String(localized: "All models"),
                              windowID: Self.windowID(provider, slot: snap.weekLimitKey)))
        }
        for extra in snap.extraLimits where !extra.isSessionWindow && Self.isLive(extra.limit, now: now) {
            bars.append(.init(extra.limit, label: extra.label ?? Self.extraLimitLabel(extra),
                              windowID: Self.windowID(provider, slot: extra.key)))
        }
        return bars
    }

    /// The 5-hour side: the main window, named by the pool it measures when that is not every
    /// model (Antigravity), then every other pool's 5-hour window — never under Weekly.
    private func sessionBars(_ snap: UsageSnapshot, provider: ProviderID, now: Date) -> [QuotaBar] {
        var bars: [QuotaBar] = []
        if let limit = snap.sessionLimit, Self.isLive(limit, now: now) {
            bars.append(.init(limit, label: snap.limitsLabel, windowID: Self.windowID(provider, slot: "session")))
        }
        for extra in snap.extraLimits where extra.isSessionWindow && Self.isLive(extra.limit, now: now) {
            bars.append(.init(extra.limit, label: extra.label ?? Self.extraLimitLabel(extra),
                              windowID: Self.windowID(provider, slot: extra.key)))
        }
        return bars
    }

    /// Cursor's one window is its billing cycle, not a week; the others report a real week.
    static func cycleTitle(for provider: ProviderID) -> String {
        provider == .cursor ? String(localized: "Billing cycle") : String(localized: "Weekly")
    }

    static func foldedSummary(_ bars: [QuotaBar]) -> String {
        bars.map { "\($0.label ?? "") \($0.percent)%" }.joined(separator: ", ")
    }

    /// Claude Code's cache is the only source with exact resets and the per-model weekly bars, and
    /// nothing refreshes it for someone who uses Claude only in the desktop app. While this tab is
    /// on screen the monitor runs `/usage` for it when it is old; the monitor paces that itself.
    private func refreshClaudeLimitsIfStale() {
        guard isEnabled(.claude) else { return }
        agentMonitor.refreshClaudeUsageIfStale()
    }

    // MARK: - Model

    /// One bar in a section: an optional label (nil for the lone 5-hour bar), the value, and the
    /// accent already resolved from severity-or-fraction.
    struct QuotaBar: Identifiable {
        let id = UUID()
        let label: String?
        let fraction: Double
        let percent: Int
        let tint: Color
        /// `UsageWindowReading.id` of this bar, for its forecast.
        let windowID: String
        let resetsAt: Date?
        /// When the value was read, when the provider says.
        let observedAt: Date?

        init(_ limit: UsageLimit, label: String? = nil, windowID: String) {
            self.label = label
            self.fraction = limit.fraction
            self.percent = Int(limit.used.rounded())
            self.tint = NotchLLMUsageView.accent(severity: limit.severity, fraction: limit.fraction)
            self.windowID = windowID
            self.resetsAt = limit.resetsAt
            self.observedAt = limit.observedAt
        }

        /// The same bar under another name.
        func labelled(_ label: String) -> QuotaBar {
            QuotaBar(copying: self, label: label)
        }

        private init(copying bar: QuotaBar, label: String?) {
            self.label = label
            fraction = bar.fraction
            percent = bar.percent
            tint = bar.tint
            windowID = bar.windowID
            resetsAt = bar.resetsAt
            observedAt = bar.observedAt
        }
    }

    /// The reading id a bar's forecast is kept under: Claude's bars carry the server's window keys,
    /// Codex and Cursor report a session and a week slot.
    static func windowID(_ provider: ProviderID, slot: String) -> String {
        let key: String
        switch (provider, slot) {
        case (.claude, "session"): key = ClaudeUsageSnapshot.fiveHourKey
        case (.claude, "week"): key = ClaudeUsageSnapshot.sevenDayKey
        default: key = slot
        }
        return UsageWindowReading.id(provider: provider.rawValue, key: key)
    }

    /// Names an extra window, preferring the label its provider supplied.
    ///
    /// Per-model weekly windows are named by the server ("Fable"), not by a key we could recognise,
    /// so a derived name would be a guess where a real one was already sent.
    static func extraLimitLabel(_ extra: NamedLimit) -> String {
        if let label = extra.label { return label }
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
            return String(localized: "5 hour")
        case ClaudeUsageSnapshot.sevenDayKey:
            return String(localized: "All models")
        default:
            let suffix = key.hasPrefix("seven_day_") ? String(key.dropFirst("seven_day_".count)) : key
            return suffix.split(separator: "_").map(\.capitalized).joined(separator: " ")
        }
    }

    /// The bar accent: the server's own severity when it reported one, else the fraction bands.
    static func accent(severity: String?, fraction: Double) -> Color {
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

    /// A limit with no reset is treated as live (nothing to expire against); one whose reset has
    /// passed is not shown, matching the fetch-time rule in `ClaudeUsageSnapshot.displayWindows`.
    private static func isLive(_ limit: UsageLimit, now: Date) -> Bool {
        limit.resetsAt.map { $0 > now } ?? true
    }

    private func resetsIn(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return nil }
        let minutes = seconds / 60
        let days = minutes / (60 * 24)
        let hours = (minutes / 60) % 24
        // Only the units that carry information: a span over a day reads "2d 22h 37m", a shorter one
        // "4h 56m", and under an hour just "56m" — a leading "0h" is noise on a glanceable gauge.
        if days > 0 {
            return String(localized: "resets in \(days)d \(hours)h \(minutes % 60)m")
        }
        if hours > 0 {
            return String(localized: "resets in \(hours)h \(minutes % 60)m")
        }
        return String(localized: "resets in \(minutes)m")
    }

    private static func font(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        .system(size: size, weight: weight)
    }

    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fk", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    private static func compactTokens(_ tokens: Int) -> String {
        switch tokens {
        case ..<1_000: return "\(tokens) tok"
        case ..<1_000_000: return String(format: "%.1fK tok", Double(tokens) / 1_000)
        default: return String(format: "%.1fM tok", Double(tokens) / 1_000_000)
        }
    }

    // Locale-aware formatting pinned to USD — amounts come from the USD pricing table, so the currency code stays fixed.
    private static let currencyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        return f
    }()

    static func money(_ v: Double) -> String {
        currencyFormatter.string(from: v as NSNumber) ?? String(format: "$%.2f", v)
    }
}

/// The house chip (the timer's `SideChip`, which stays private to its file): a small capsule,
/// exactly as wide as its text unless `truncates`, which shortens in the middle instead.
private struct UsageChip: View {
    @Environment(\.notchForeground) private var notchForeground
    private typealias M = UsageCardMetrics
    let text: String
    var tint: Color? = nil
    var truncates = false

    init(_ text: String, tint: Color? = nil, truncates: Bool = false) {
        self.text = text
        self.tint = tint
        self.truncates = truncates
    }

    var body: some View {
        let chip = Text(verbatim: text)
            .font(.system(size: M.glyphFontSize, weight: .semibold))
            .foregroundStyle(tint ?? Color.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, M.chipPaddingHorizontal)
            .padding(.vertical, M.chipPaddingVertical)
            .background(Capsule().fill(tint == .orange ? Color.orange.opacity(M.chipFill) : notchForeground.opacity(M.chipFill)))
        if truncates {
            chip.fixedSize(horizontal: false, vertical: true)
        } else {
            chip.fixedSize()
        }
    }
}
