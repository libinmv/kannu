import Combine
import Defaults
import Foundation

@MainActor
final class AgentStatusNotificationBridge: ObservableObject {
    static let shared = AgentStatusNotificationBridge()

    @Published private(set) var lastError: String?
    @Published private(set) var lastSentAt: Date?

    private var cancellables = Set<AnyCancellable>()
    private var debounceTask: Task<Void, Never>?
    private var lastNotifiedState: AgentTrafficLightState?
    private let debounceInterval: TimeInterval = 2.0
    /// Findings already pushed, persisted and pruned to what is still open so a relaunch stays
    /// quiet and a finding that returns after vanishing is pushed once more.
    private var pushedFindingIDs: Set<String> = Set(Defaults[.adrPushedFindingIDs])
    /// Usage windows already pushed, one key per window instance (see `UsageAlertPolicy.pushKey`).
    private var pushedUsageKeys: Set<String> = Set(Defaults[.usageAlertPushedKeys])

    private init() {}

    func start() {
        cancellables.removeAll()
        lastNotifiedState = nil

        CursorAgentStatusMonitor.shared.$trafficLightState
            .removeDuplicates()
            .sink { [weak self] state in
                self?.handleStateChange(state)
            }
            .store(in: &cancellables)

        Defaults.publisher(.enableAgentStatusMobileNotifications, options: [])
            .sink { [weak self] _ in
                self?.lastNotifiedState = nil
            }
            .store(in: &cancellables)

        // Security findings ride on the findings store, not on the traffic light.
        let store = SecurityFindingsStore.shared
        store.$findings.map { _ in () }
            .merge(with: store.$acknowledgedIDs.map { _ in () }, store.$snoozes.map { _ in () })
            .sink { [weak self] in self?.handleFindingsChange() }
            .store(in: &cancellables)

        UsageAlertManager.shared.$nearLimit
            .sink { [weak self] near in self?.handleUsageAlerts(near) }
            .store(in: &cancellables)
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        cancellables.removeAll()
        lastNotifiedState = nil
    }

    // MARK: - Security findings

    private func handleFindingsChange() {
        guard Defaults[.enableAgentStatusMobileNotifications], Defaults[.adrPushHighFindings] else { return }
        let ranking = SecurityFindingsStore.shared.ranking
        let candidates = ranking.visible.filter {
            $0.severity == .high || ($0.severity == .medium && Defaults[.adrPushMediumFindings])
        }
        pushedFindingIDs.formIntersection(Set(candidates.map(\.id)))
        let fresh = candidates.filter { !pushedFindingIDs.contains($0.id) }
        pushedFindingIDs.formUnion(fresh.map(\.id))
        let persisted = pushedFindingIDs.sorted()
        if persisted != Defaults[.adrPushedFindingIDs] { Defaults[.adrPushedFindingIDs] = persisted }
        guard !fresh.isEmpty else { return }
        Task { [weak self] in
            for finding in fresh { await self?.deliverFinding(finding) }
        }
    }

    private func deliverFinding(_ finding: AgentSecurityFinding) async {
        let payload = NotificationPayload(
            title: String(localized: "Security finding: \(finding.title)"),
            body: finding.summary,
            priority: finding.severity == .high ? 5 : 4,
            tag: "security-finding"
        )
        await send(payload, webhookState: "security_finding", extra: [
            "rule": finding.rule,
            "severity": finding.severity == .high ? "high" : "medium",
            // Not "source": the base body's "source": "Kannu" wins that merge and dropped it.
            "finding_source": finding.source.rawValue,
            "asset": finding.assetName ?? "",
            "summary": finding.summary
        ])
    }

    /// One delivery through whichever provider the user configured; records the outcome.
    private func send(_ payload: NotificationPayload, webhookState: String, extra: [String: Any]) async {
        do {
            switch Defaults[.agentStatusNotificationProvider] {
            case .ntfy:
                try await sendViaNtfy(payload: payload)
            case .pushover:
                try await sendViaPushover(payload: payload)
            case .webhook:
                try await sendViaWebhook(payload: payload, stateKey: webhookState, extra: extra)
            }
            lastError = nil
            lastSentAt = .now
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Usage limits

    /// Once per window instance, pruned to windows still near their limit so the next cycle of
    /// the same window can push again. Provider, window and reset only — no chat names.
    private func handleUsageAlerts(_ near: [UsageWindowReading]) {
        pushedUsageKeys.formIntersection(Set(near.map(UsageAlertPolicy.pushKey)))
        var fresh: [UsageWindowReading] = []
        if Defaults[.enableAgentStatusMobileNotifications], Defaults[.pushUsageLimitAlerts] {
            fresh = near.filter { !pushedUsageKeys.contains(UsageAlertPolicy.pushKey($0)) }
            pushedUsageKeys.formUnion(fresh.map(UsageAlertPolicy.pushKey))
        }
        let persisted = pushedUsageKeys.sorted()
        if persisted != Defaults[.usageAlertPushedKeys] { Defaults[.usageAlertPushedKeys] = persisted }
        guard !fresh.isEmpty else { return }
        Task { [weak self] in
            for reading in fresh { await self?.deliverUsageAlert(reading) }
        }
    }

    private func deliverUsageAlert(_ reading: UsageWindowReading) async {
        let text = UsageAlertPolicy.pushText(reading, now: Date())
        let payload = NotificationPayload(title: text.title, body: text.body, priority: 4, tag: "usage-limit")
        await send(payload, webhookState: "usage_limit", extra: [
            "provider": reading.provider,
            "window": reading.key,
            "percent": Int(reading.percent.rounded()),
            "resets_at": reading.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        ])
    }

    func sendTestNotification() async {
        await deliverNotification(for: .thinking, isTest: true)
    }

    private func handleStateChange(_ state: AgentTrafficLightState) {
        guard Defaults[.enableAgentStatusMobileNotifications] else { return }
        guard state != .inactive || Defaults[.agentStatusNotifyOnInactive] else { return }

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.debounceInterval ?? 2) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.deliverNotification(for: state, isTest: false)
        }
    }

    private func deliverNotification(for state: AgentTrafficLightState, isTest: Bool) async {
        guard Defaults[.enableAgentStatusMobileNotifications] || isTest else { return }
        if !isTest, lastNotifiedState == state { return }

        let payload = notificationPayload(for: state, isTest: isTest)
        let provider = Defaults[.agentStatusNotificationProvider]

        do {
            switch provider {
            case .ntfy:
                try await sendViaNtfy(payload: payload)
            case .pushover:
                try await sendViaPushover(payload: payload)
            case .webhook:
                try await sendViaWebhook(payload: payload, stateKey: state.notificationKey)
            }
            lastError = nil
            lastSentAt = .now
            if !isTest {
                lastNotifiedState = state
            }
        } catch is CancellationError {
            // A newer state change cancelled this debounce task while the request was already
            // in flight; the replacement delivery reports its own outcome.
        } catch let error as URLError where error.code == .cancelled {
            // Same cancellation, surfaced through URLSession.
        } catch {
            lastError = error.localizedDescription
        }
    }

    private struct NotificationPayload {
        let title: String
        let body: String
        let priority: Int
        let tag: String
    }

    private func notificationPayload(for state: AgentTrafficLightState, isTest: Bool) -> NotificationPayload {
        if isTest {
            return NotificationPayload(
                title: "Kannu Test",
                body: "Mobile notifications are configured correctly.",
                priority: 3,
                tag: "kannu-test"
            )
        }

        switch state {
        case .thinking:
            return NotificationPayload(
                title: "Agent Thinking",
                body: "Your AI agent is reasoning or composing a response.",
                priority: 3,
                tag: "agent-thinking"
            )
        case .executing:
            return NotificationPayload(
                title: "Agent Executing",
                body: "Your AI agent is running tools and doing work.",
                priority: 4,
                tag: "agent-executing"
            )
        case .awaitingInput:
            return NotificationPayload(
                title: "Agent Needs Input",
                body: "Your AI agent is waiting for your approval or response.",
                priority: 5,
                tag: "agent-awaiting-input"
            )
        case .stopped:
            return NotificationPayload(
                title: "Agent Stopped",
                body: "Your AI agent has finished or was aborted.",
                priority: 2,
                tag: "agent-stopped"
            )
        case .inactive:
            return NotificationPayload(
                title: "Agent Inactive",
                body: "No active AI agent detected.",
                priority: 1,
                tag: "agent-inactive"
            )
        }
    }

    private func sendViaNtfy(payload: NotificationPayload) async throws {
        let topic = Defaults[.agentStatusNtfyTopic].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else {
            throw BridgeError.missingConfiguration("ntfy topic is required")
        }

        let base = Defaults[.agentStatusNtfyServerURL].trimmingCharacters(in: .whitespacesAndNewlines)
        guard SecurityURLPolicy.isAllowedNtfyServerURL(base) else {
            throw BridgeError.missingConfiguration("ntfy server URL must use https and a public host")
        }
        let server = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: "\(server)/\(topic)") else {
            throw BridgeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload.body.data(using: .utf8)
        request.setValue(payload.title, forHTTPHeaderField: "Title")
        request.setValue(String(payload.priority), forHTTPHeaderField: "Priority")
        request.setValue(payload.tag, forHTTPHeaderField: "Tags")
        request.setValue("kannu", forHTTPHeaderField: "X-Kannu")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw BridgeError.requestFailed
        }
    }

    private func sendViaPushover(payload: NotificationPayload) async throws {
        let userKey = SecureSecretsStore.value(for: .pushoverUserKey).trimmingCharacters(in: .whitespacesAndNewlines)
        let appToken = SecureSecretsStore.value(for: .pushoverAppToken).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userKey.isEmpty, !appToken.isEmpty else {
            throw BridgeError.missingConfiguration("Pushover user key and app token are required")
        }

        guard let url = URL(string: "https://api.pushover.net/1/messages.json") else {
            throw BridgeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let priority = max(-2, min(2, payload.priority - 2))
        let form = [
            "token": appToken,
            "user": userKey,
            "title": payload.title,
            "message": payload.body,
            "priority": String(priority)
        ]
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw BridgeError.requestFailed
        }
    }

    private func sendViaWebhook(payload: NotificationPayload, stateKey: String, extra: [String: Any] = [:]) async throws {
        let webhook = SecureSecretsStore.value(for: .webhookURL).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !webhook.isEmpty, SecurityURLPolicy.isAllowedWebhookURL(webhook), let url = URL(string: webhook) else {
            throw BridgeError.missingConfiguration("Webhook URL is required")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "state": stateKey,
            "title": payload.title,
            "body": payload.body,
            "timestamp": ISO8601DateFormatter().string(from: .now),
            "source": "Kannu"
        ]
        body.merge(extra) { current, _ in current }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw BridgeError.requestFailed
        }
    }

    private enum BridgeError: LocalizedError {
        case missingConfiguration(String)
        case invalidURL
        case requestFailed

        var errorDescription: String? {
            switch self {
            case .missingConfiguration(let message): return message
            case .invalidURL: return "Invalid notification URL."
            case .requestFailed: return "Notification request failed."
            }
        }
    }
}
