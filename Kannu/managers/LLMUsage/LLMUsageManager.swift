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
    private static let minRefreshInterval: TimeInterval = 60
    /// `force`/`interactive` refreshes (opening the Usage tab, tapping "Refresh", retrying a
    /// fix-it button) used to skip the throttle entirely. That's fine for the local providers,
    /// but for network providers it meant reopening the tab a few times in a row — or a user
    /// mashing "Allow keychain access…" — fired unlimited requests at Claude's `oauth/usage`
    /// endpoint, which has its own tight per-account rate limit. Give those a much shorter
    /// floor instead of zero, so intent ("give me fresh data now") still works.
    private static let minInteractiveRefreshInterval: TimeInterval = 10

    init(providers: [UsageProvider]? = nil) {
        self.injectedProviders = providers
    }

    // Runs once on first launch to enable only the providers that are actually installed.
    // Uses UserDefaults.standard directly (thread-safe, no @MainActor needed) so it can
    // be called synchronously from KannuApp.init() before any UI reads these keys.
    nonisolated static func configureProviderDefaultsIfNeeded() {
        let ud = UserDefaults.standard
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        if !ud.bool(forKey: "llmProviderDefaultsConfigured") {
            ud.set(fm.fileExists(atPath: home.appendingPathComponent(".claude/projects").path), forKey: "enableClaudeProvider")
            ud.set(fm.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path), forKey: "enableCursorProvider")
            ud.set(fm.fileExists(atPath: home.appendingPathComponent(".codex/sessions").path), forKey: "enableCodexProvider")
            ud.set(true, forKey: "llmProviderDefaultsConfigured")
        }
        // Antigravity detection runs independently each launch so existing installs
        // that already have llmProviderDefaultsConfigured=true pick it up automatically.
        if !ud.bool(forKey: "antigravityProviderDefaultsConfigured") {
            // Both distributions, not just the IDE: the CLI keeps its state under
            // ~/.gemini/antigravity-cli, so checking only the IDE directory left every
            // CLI-only user with the provider silently disabled.
            let antigravityInstalled = ["antigravity-ide", "antigravity-cli"].contains { dir in
                fm.fileExists(atPath: home.appendingPathComponent(".gemini/\(dir)").path)
            }
            ud.set(antigravityInstalled, forKey: "enableAntigravityProvider")
            ud.set(true, forKey: "antigravityProviderDefaultsConfigured")
        }
    }

    private static let allProviders: [UsageProvider] = [AntigravityUsageProvider(), ClaudeUsageProvider(), CodexUsageProvider(), CursorUsageProvider()]

    private var enabledProviders: [UsageProvider] {
        if let injectedProviders { return injectedProviders }
        return Self.allProviders.filter { Defaults[$0.id.enabledKey] }
    }

    /// `interactive` marks a refresh the user asked for directly, letting providers take
    /// steps that may show a system prompt (e.g. approving a cross-app keychain read).
    /// Automatic and timer-driven refreshes must leave it false so nothing blocks on a dialog.
    func refreshAll(force: Bool = false, interactive: Bool = false) {
        guard !isRefreshing else { return }
        let allEnabled = enabledProviders
        let localProviders = allEnabled.filter { $0.isLocalFileProvider }
        let networkProviders = allEnabled.filter { !$0.isLocalFileProvider }

        // Local file providers (e.g. Antigravity) refresh on every open — no throttle.
        if !localProviders.isEmpty {
            for provider in localProviders {
                results[provider.id] = .loading
            }
            Task { await runRefresh(providers: localProviders, interactive: interactive) }
        }

        // Network providers respect the 60-second throttle to avoid hammering APIs. A
        // force/interactive refresh may jump the queue early, but never below the shorter
        // interactive floor — see `minInteractiveRefreshInterval`.
        let elapsed = Date().timeIntervalSince(lastRefresh)
        let requiredInterval = (force || interactive) ? Self.minInteractiveRefreshInterval : Self.minRefreshInterval
        guard elapsed >= requiredInterval else { return }
        guard !networkProviders.isEmpty else { return }
        lastRefresh = Date()
        isRefreshing = true
        let enabledIDs = Set(networkProviders.map { $0.id })
        results = results.filter { localProviders.map(\.id).contains($0.key) || enabledIDs.contains($0.key) }
        for provider in networkProviders {
            results[provider.id] = .loading
        }
        Task { await runRefresh(providers: networkProviders, interactive: interactive) }
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
            for await (id, result) in group { results[id] = result }
        }
        isRefreshing = false
    }
}
