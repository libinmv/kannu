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

    func refreshAll(force: Bool = false) {
        guard !isRefreshing else { return }
        guard force || Date().timeIntervalSince(lastRefresh) >= Self.minRefreshInterval else { return }
        lastRefresh = Date()
        isRefreshing = true
        let providers = enabledProviders
        let enabledIDs = Set(providers.map { $0.id })
        results = results.filter { enabledIDs.contains($0.key) }
        for provider in providers {
            results[provider.id] = .loading
        }
        Task { await runRefresh(providers: providers) }
    }

    private func runRefresh(providers: [UsageProvider]) async {
        let now = Date()
        await withTaskGroup(of: (ProviderID, UsageResult).self) { group in
            for provider in providers {
                group.addTask {
                    do { return (provider.id, .success(try await provider.fetchSnapshot(now: now))) }
                    catch { return (provider.id, .failure(error.localizedDescription)) }
                }
            }
            for await (id, result) in group { results[id] = result }
        }
        isRefreshing = false
    }
}
