import Foundation
import Defaults

enum ProviderID: String, CaseIterable, Identifiable {
    case claude, codex, cursor
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }
    var enabledKey: Defaults.Key<Bool> {
        switch self {
        case .claude: return .enableClaudeProvider
        case .codex: return .enableCodexProvider
        case .cursor: return .enableCursorProvider
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
    var fraction: Double { limit > 0 ? min(used / limit, 1) : 0 }
}

/// A user-fixable reason a quota fetch failed, surfaced as a button in the usage card.
enum QuotaAction: Equatable {
    case grantClaudeKeychainAccess
    var buttonTitle: String {
        switch self {
        case .grantClaudeKeychainAccess: return "Allow keychain access…"
        }
    }
}

struct UsageSnapshot: Equatable {
    var session: UsageTotals = .init()
    var today: UsageTotals = .init()
    var week: UsageTotals = .init()
    var sessionLimit: UsageLimit? = nil // 5h window quota
    var weekLimit: UsageLimit? = nil // 7d window quota
    var onDemandSpendUSD: Double? = nil // billing-cycle on-demand spend from usage-summary
    var models: [ModelUsage] = []
    var lastUpdated: Date = .distantPast
    var quotaError: String? = nil
    /// Set when the quota failure has a one-tap fix the user can trigger.
    var quotaAction: QuotaAction? = nil
    var logsUnavailable: Bool = false
    /// Show only provider-billed spend; never display pricing-table estimates.
    var billedCostOnly: Bool = false
    /// Account plan/tier label (e.g. "Pro", "Max") shown next to the provider name.
    var accountTier: String? = nil
}

struct QuotaFetchResult: Equatable {
    var session: UsageLimit?
    var week: UsageLimit?
    var onDemandSpendUSD: Double? = nil
    var accountTier: String? = nil
    var errorMessage: String?
    var action: QuotaAction? = nil

    var hasLimits: Bool { session != nil || week != nil }
}

enum UsageResult {
    case loading
    case success(UsageSnapshot)
    case failure(String)
}

protocol UsageProvider {
    var id: ProviderID { get }
    /// `interactive` is true only for a refresh the user explicitly asked for; providers may
    /// then take steps that can show a system dialog (e.g. a cross-app keychain read).
    func fetchSnapshot(now: Date, interactive: Bool) async throws -> UsageSnapshot
}

extension UsageProvider {
    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        try await fetchSnapshot(now: now, interactive: false)
    }
}
