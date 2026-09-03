import Foundation
import Defaults

enum ProviderID: String, CaseIterable, Identifiable {
    case claude, codex, cursor, antigravity
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .antigravity: return "Antigravity"
        }
    }
    var enabledKey: Defaults.Key<Bool> {
        switch self {
        case .claude: return .enableClaudeProvider
        case .codex: return .enableCodexProvider
        case .cursor: return .enableCursorProvider
        case .antigravity: return .enableAntigravityProvider
        }
    }
}

struct UsageTotals: Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var costUSD: Double = 0
    var hasUnpricedModel: Bool = false
    var totalTokens: Int { inputTokens + outputTokens }
}

struct ModelUsage: Equatable, Identifiable {
    let model: String
    let totals: UsageTotals
    var id: String { model }
}

struct UsageLimit: Equatable {
    let used: Double
    let limit: Double
    var resetsAt: Date? = nil
    /// Server-reported severity ("normal"/"warning"/"critical") when available; drives the accent.
    var severity: String? = nil
    var fraction: Double { limit > 0 ? min(used / limit, 1) : 0 }
}

/// A user-fixable reason a quota fetch failed, surfaced as a button in the usage card.
enum QuotaAction: Equatable {
    case grantClaudeKeychainAccess
    var buttonTitle: String {
        switch self {
        // Says what approving buys, not what it costs. Plan tier already shows without it;
        // the keychain read is only needed for live 5h/7d limits.
        case .grantClaudeKeychainAccess: return "Show usage limits…"
        }
    }
}

/// A rate-limit window with no dedicated field on `UsageSnapshot` — a per-model or per-surface
/// weekly cap that only some plans report. Keyed by the provider's own window name so the view can
/// label it without the model having to know every name up front.
struct NamedLimit: Equatable {
    let key: String
    let limit: UsageLimit
    /// The provider's own name for this window, preferred over anything derived from the key.
    var label: String? = nil
}

extension NamedLimit {
    /// Severity rides on the inner limit, so views read it uniformly across session/week/extra.
    var severity: String? { limit.severity }
}

struct UsageSnapshot: Equatable {
    var session: UsageTotals = .init()
    var today: UsageTotals = .init()
    var week: UsageTotals = .init()
    var sessionLimit: UsageLimit? = nil // 5h window quota
    var weekLimit: UsageLimit? = nil // 7d all-models window quota
    /// Additional rate-limit windows beyond the 5h/7d pair, in the order the provider reported them.
    var extraLimits: [NamedLimit] = []
    var onDemandSpendUSD: Double? = nil // billing-cycle on-demand spend from usage-summary
    var models: [ModelUsage] = []
    var lastUpdated: Date = .distantPast
    var quotaError: String? = nil
    /// Set when the quota failure has a one-tap fix the user can trigger.
    var quotaAction: QuotaAction? = nil
    /// Locally reconstructed current 5-hour block (Claude): tokens + reset time, shown when
    /// the server-side limit gauge is unavailable. Never a percentage — no local denominator.
    var localSessionBlock: ClaudeSessionBlocks.CurrentBlock? = nil
    var logsUnavailable: Bool = false
    /// Show only provider-billed spend; never display pricing-table estimates.
    var billedCostOnly: Bool = false
    /// Account plan/tier label (e.g. "Pro", "Max") shown next to the provider name.
    var accountTier: String? = nil
    /// Set when the quota failure is a definitive auth failure (not-signed-in, 401, 403,
    /// expired token) rather than a transient error (429, 500+).
    /// Used by `isFatallyUnconfigured` to drop the card from the Usage tab.
    var isAuthFailure: Bool = false

    /// True when the provider has nothing useful to show AND the reason is a definitive
    /// auth failure (not signed-in / expired token / 401 / 403) — NOT a transient error
    /// like 429 or 500. Only those cases drop the card from the Usage tab.
    var isFatallyUnconfigured: Bool {
        // A card carrying a fix-it button or an explanatory quota message must stay visible:
        // hiding it strands the user with no path to recovery.
        if quotaAction != nil || quotaError != nil { return false }
        let hasNoRealUsage = logsUnavailable
            || (today.totalTokens == 0 && week.totalTokens == 0 && session.totalTokens == 0)
        let hasNoQuota = sessionLimit == nil && weekLimit == nil
        return hasNoRealUsage && hasNoQuota && isAuthFailure
    }

    /// Short account-status note (e.g. "Out of extra credits"). Distinct from `quotaError`:
    /// this is a fact about the account, not a failure to fetch anything.
    var accountNote: String? = nil
}

struct QuotaFetchResult: Equatable {
    var session: UsageLimit?
    var week: UsageLimit?
    var onDemandSpendUSD: Double? = nil
    var accountTier: String? = nil
    var errorMessage: String?
    var action: QuotaAction? = nil
    /// True for definitive auth failures (not-signed-in, 401, 403, expired refresh token).
    /// False for transient errors (429, 500+, network hiccup) — those should NOT move the
    /// card from the Usage tab, since the provider IS configured.
    var isAuthFailure: Bool = false

    var hasLimits: Bool { session != nil || week != nil }
}

enum UsageResult {
    case loading
    case success(UsageSnapshot)
    case failure(String)
}

protocol UsageProvider {
    var id: ProviderID { get }
    /// True for providers that read local files (near-instant, no network).
    /// These bypass the 60-second shared throttle and refresh on every panel open.
    var isLocalFileProvider: Bool { get }
    /// `interactive` is true only for a refresh the user explicitly asked for; providers may
    /// then take steps that can show a system dialog (e.g. a cross-app keychain read).
    func fetchSnapshot(now: Date, interactive: Bool) async throws -> UsageSnapshot
}

extension UsageProvider {
    var isLocalFileProvider: Bool { false }
    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        try await fetchSnapshot(now: now, interactive: false)
    }
}
