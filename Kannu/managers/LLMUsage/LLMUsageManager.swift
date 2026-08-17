import Foundation
import SwiftUI
import Defaults

@MainActor
final class LLMUsageManager: ObservableObject {
    static let shared = LLMUsageManager()

    @Published var results: [ProviderID: UsageResult] = [:]
    @Published var isRefreshing = false

    private let injectedProviders: [UsageProvider]? // overrides the flag-based default when non-nil
    private var lastRefresh: Date = .distantPast
    /// A forced request that arrived while a refresh was already in flight. Dropping it lost
    /// the user's action (e.g. the limits toggle mid-poll) until the next timer tick, which the
    /// 180s floor could then reject — the card sat empty for minutes.
    private var pendingForcedRefresh: (force: Bool, interactive: Bool)?
    // 180s matches the documented safe polling cadence for Anthropic's oauth/usage endpoint;
    // anything faster earns per-token 429s even with a correct User-Agent.
    private static let minRefreshInterval: TimeInterval = 180
    /// How stale a kept last-good result may grow before a failure is allowed through. Without
    /// a bound, one early success made every later failure invisible for the process lifetime.
    private static let maxPreservedResultAge: TimeInterval = minRefreshInterval * 3

    init(providers: [UsageProvider]? = nil) {
        self.injectedProviders = providers
    }

    // Runs once on first launch to enable only the providers that are actually installed.
    // Uses UserDefaults.standard directly (thread-safe, no @MainActor needed) so it can
    // be called synchronously from KannuApp.init() before any UI reads these keys.
    nonisolated static func configureProviderDefaultsIfNeeded() {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: "llmProviderDefaultsConfigured") else { return }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        ud.set(fm.fileExists(atPath: home.appendingPathComponent(".claude/projects").path), forKey: "enableClaudeProvider")
        ud.set(fm.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path), forKey: "enableCursorProvider")
        ud.set(fm.fileExists(atPath: home.appendingPathComponent(".codex/sessions").path), forKey: "enableCodexProvider")
        ud.set(true, forKey: "llmProviderDefaultsConfigured")
    }

    private static let allProviders: [UsageProvider] = [ClaudeUsageProvider(), CodexUsageProvider(), CursorUsageProvider()]

    private var enabledProviders: [UsageProvider] {
        if let injectedProviders { return injectedProviders }
        return Self.allProviders.filter { Defaults[$0.id.enabledKey] }
    }

    /// `interactive` marks a refresh the user asked for directly, letting providers take
    /// steps that may show a system prompt (e.g. approving a cross-app keychain read).
    /// Automatic and timer-driven refreshes must leave it false so nothing blocks on a dialog.
    func refreshAll(force: Bool = false, interactive: Bool = false) {
        guard !isRefreshing else {
            // Remember an explicit request rather than dropping it; runRefresh drains this.
            if force || interactive {
                pendingForcedRefresh = (
                    force: force || (pendingForcedRefresh?.force ?? false),
                    interactive: interactive || (pendingForcedRefresh?.interactive ?? false)
                )
            }
            return
        }
        guard force || interactive || Date().timeIntervalSince(lastRefresh) >= Self.minRefreshInterval else { return }
        lastRefresh = Date()
        isRefreshing = true
        let providers = enabledProviders
        let enabledIDs = Set(providers.map { $0.id })
        results = results.filter { enabledIDs.contains($0.key) }
        for provider in providers {
            // Keep showing the last snapshot while refreshing — blanking every card to a
            // spinner made each poll/tab-open feel like a full reload.
            if case .success = results[provider.id] ?? .loading { continue }
            results[provider.id] = .loading
        }
        Task { await runRefresh(providers: providers, interactive: interactive) }
    }

    /// Retries a provider's quota with prompts allowed, after the user taps the card's fix-it button.
    func resolveQuotaAction(_ action: QuotaAction) {
        switch action {
        case .grantClaudeKeychainAccess: refreshAll(force: true, interactive: true)
        }
    }

    private func runRefresh(providers: [UsageProvider], interactive: Bool) async {
        let now = Date()
        await withTaskGroup(of: (ProviderID, UsageResult).self) { group in
            for provider in providers {
                group.addTask {
                    do { return (provider.id, .success(try await provider.fetchSnapshot(now: now, interactive: interactive))) }
                    catch { return (provider.id, .failure(error.localizedDescription)) }
                }
            }
            for await (id, result) in group {
                // A failed refresh shouldn't wipe figures that were valid moments ago — a
                // transient network blip or rate limit would otherwise blank a populated card.
                // Age-bounded: without a cutoff, one early success hid every later failure
                // (sign out of the CLI and the card kept stale numbers forever, no error).
                if case .failure(let reason) = result,
                   case .success(let previous) = results[id],
                   now.timeIntervalSince(previous.lastUpdated) < Self.maxPreservedResultAge {
                    QuotaDebugLog.log("UsageManager", "\(id) refresh failed (\(reason)) — kept previous good result")
                    continue
                }
                if case .failure(let reason) = result {
                    QuotaDebugLog.log("UsageManager", "\(id) refresh failed: \(reason)")
                } else if case .success(let snap) = result, let quotaError = snap.quotaError {
                    // Providers return degraded snapshots instead of throwing, so a bare "ok"
                    // here would hide a failed quota lookup — say what actually happened.
                    QuotaDebugLog.log("UsageManager", "\(id) refresh ok (quota: \(quotaError))")
                } else {
                    QuotaDebugLog.log("UsageManager", "\(id) refresh ok")
                }
                results[id] = result
            }
        }
        isRefreshing = false

        // Drain a request that arrived mid-flight, on the next runloop turn so the
        // published state settles first.
        if let pending = pendingForcedRefresh {
            pendingForcedRefresh = nil
            Task { @MainActor in
                self.refreshAll(force: pending.force, interactive: pending.interactive)
            }
        }
    }
}
