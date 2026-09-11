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

import Combine
import Defaults
import Foundation

extension UsageForecast.Sample: Defaults.Serializable {}

/// Keeps usage readings from every provider in one place, remembers them over time for the
/// forecast, and says which windows are near their limit. Claude readings come from the agent
/// monitor (local files); Codex and Cursor from the Usage tab's own refreshes — and, only if the
/// user opted in, from a light background check while such an agent is working.
@MainActor
final class UsageAlertManager: ObservableObject {
    static let shared = UsageAlertManager()

    @Published private(set) var readings: [UsageWindowReading] = []
    @Published private(set) var outlooks: [String: UsageForecast.Outlook] = [:]
    @Published private(set) var nearLimit: [UsageWindowReading] = []

    static let backgroundPollInterval: TimeInterval = 300
    private static let persistInterval: TimeInterval = 300
    private static let sampleRetention: TimeInterval = 8 * 24 * 3600

    private var samples: [String: [UsageForecast.Sample]]
    private var claudeReadings: [UsageWindowReading] = []
    private var providerReadings: [String: [UsageWindowReading]] = [:]
    /// Providers whose quota read succeeded in the foreground this launch: proof that their
    /// credentials read without a prompt, so a background check can never raise one out of the blue.
    private var foregroundSucceeded: Set<String> = []
    private var backgroundInFlight: Set<String> = []
    private var cancellables = Set<AnyCancellable>()
    private var lastPersistAt: Date = .distantPast
    private var resetTask: Task<Void, Never>?
    private var backgroundTimer: Timer?

    private init() {
        samples = Defaults[.usageForecastSamples]
    }

    func start() {
        cancellables.removeAll()
        CursorAgentStatusMonitor.shared.$claudeUsage
            .sink { [weak self] snapshot in
                self?.claudeReadings = UsageWindowReading.readings(fromClaude: snapshot, now: Date())
                self?.evaluate()
            }
            .store(in: &cancellables)
        LLMUsageManager.shared.$results
            .sink { [weak self] results in self?.ingest(results) }
            .store(in: &cancellables)
        Defaults.publisher(.checkQuotaInBackground)
            .sink { [weak self] _ in Task { @MainActor in self?.syncBackgroundTimer() } }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        resetTask?.cancel()
        resetTask = nil
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        persist(force: true, now: Date())
    }

    // MARK: - Readings

    private func ingest(_ results: [ProviderID: UsageResult]) {
        for provider in [ProviderID.codex, ProviderID.cursor] {
            guard case .success(let snapshot)? = results[provider] else { continue }
            let readings = Self.readings(provider: provider.rawValue, session: snapshot.sessionLimit, week: snapshot.weekLimit,
                                         extra: snapshot.extraLimits, observedAt: snapshot.lastUpdated)
            guard !readings.isEmpty else { continue }
            foregroundSucceeded.insert(provider.rawValue)
            providerReadings[provider.rawValue] = readings
        }
        evaluate()
    }

    private static func readings(provider: String, session: UsageLimit?, week: UsageLimit?, extra: [NamedLimit],
                                 observedAt: Date) -> [UsageWindowReading] {
        var out: [UsageWindowReading] = []
        func add(_ key: String, _ limit: UsageLimit?, label: String? = nil) {
            guard let limit, limit.limit > 0 else { return }
            out.append(UsageWindowReading(provider: provider, key: key,
                                          label: label ?? UsageWindowReading.label(provider: provider, key: key),
                                          percent: limit.fraction * 100, resetsAt: limit.resetsAt,
                                          severity: limit.severity, observedAt: observedAt))
        }
        add("session", session)
        add("week", week)
        for named in extra { add(named.key, named.limit, label: named.label) }
        return out
    }

    private func isEnabled(_ provider: String) -> Bool {
        guard Defaults[.enableLLMUsageFeature] else { return false }
        switch provider {
        case "claude": return Defaults[.enableClaudeProvider]
        case "codex": return Defaults[.enableCodexProvider]
        case "cursor": return Defaults[.enableCursorProvider]
        default: return false
        }
    }

    private func evaluate(now: Date = Date()) {
        let all = (claudeReadings + providerReadings.values.flatMap { $0 })
            .filter { $0.isLive(now: now) && isEnabled($0.provider) }
            .sorted { $0.id < $1.id }
        var samplesChanged = false
        var nextOutlooks: [String: UsageForecast.Outlook] = [:]
        for reading in all {
            let before = samples[reading.id] ?? []
            let after = UsageForecast.admitting(.init(at: reading.observedAt, percent: reading.percent, resetsAt: reading.resetsAt),
                                                to: before)
            if after != before {
                samples[reading.id] = after
                samplesChanged = true
            }
            nextOutlooks[reading.id] = UsageForecast.outlook(after, current: reading, now: now)
        }
        if all != readings { readings = all }
        if nextOutlooks != outlooks { outlooks = nextOutlooks }
        let near = UsageAlertPolicy.nearLimit(all, now: now)
        if near != nearLimit { nearLimit = near }
        if samplesChanged { persist(force: false, now: now) }
        scheduleResetRecheck(now: now)
    }

    /// Nothing republishes when a window resets, so the gauge and "resumes at" would outlive it.
    private func scheduleResetRecheck(now: Date) {
        resetTask?.cancel()
        resetTask = nil
        guard let next = UsageAlertPolicy.nextReset(readings, now: now) else { return }
        let delay = max(1, next.timeIntervalSince(now) + 1)
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }

    private func persist(force: Bool, now: Date) {
        guard force || now.timeIntervalSince(lastPersistAt) >= Self.persistInterval else { return }
        lastPersistAt = now
        let cutoff = now.addingTimeInterval(-Self.sampleRetention)
        samples = samples.compactMapValues { list in
            let kept = list.filter { $0.at >= cutoff }
            return kept.isEmpty ? nil : kept
        }
        Defaults[.usageForecastSamples] = samples
    }

    // MARK: - Background check (opt-in)

    private func syncBackgroundTimer() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        guard Defaults[.checkQuotaInBackground] else { return }
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: Self.backgroundPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollInBackground() }
        }
    }

    /// The same request the Usage tab makes, only while that provider's agent is working and
    /// only after a foreground read succeeded this launch.
    private func pollInBackground() {
        let sessions = CursorAgentStatusMonitor.shared.sessions
        for provider in ["codex", "cursor"] {
            guard foregroundSucceeded.contains(provider), !backgroundInFlight.contains(provider), isEnabled(provider),
                  sessions.contains(where: { $0.isVisible && $0.provider.lowercased() == provider && $0.displayState.isActiveRun })
            else { continue }
            backgroundInFlight.insert(provider)
            Task { @MainActor [weak self] in
                let result = provider == "codex" ? await CodexQuotaClient().fetchLimits() : await CursorQuotaClient().fetchLimits()
                self?.applyBackground(result, provider: provider)
            }
        }
    }

    private func applyBackground(_ result: QuotaFetchResult, provider: String) {
        backgroundInFlight.remove(provider)
        let readings = Self.readings(provider: provider, session: result.session, week: result.week, extra: [], observedAt: Date())
        guard !readings.isEmpty else { return }
        providerReadings[provider] = readings
        evaluate()
    }
}
