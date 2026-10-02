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

import AppKit
import Combine
import Defaults
import Foundation
import os

/// Kannu's end of the cloud-session relay (docs/CLOUD-SESSIONS.md): one long-lived stream from the
/// relay, open only while the user has turned the feature on.
///
/// The stream is read on a detached utility task through its own ephemeral `URLSession` — never
/// `URLSession.shared`, whose 60 s request timeout would cut a stream that is quiet between ntfy's
/// keepalives, and which shares cookies and caches with the rest of the app. Every line goes
/// through `ClaudeCloudRelay.parse`; only a changed snapshot reaches the main actor, and the monitor
/// turns it into cards on its next rescan (`CursorAgentStatusMonitor.cloudRelayDidChange`).
///
/// Logs never carry the key, the topic, the stream's URL, a session id or a repository name.
@MainActor
final class ClaudeCloudRelayManager: ObservableObject {
    static let shared = ClaudeCloudRelayManager()

    enum Status: Equatable {
        /// Off in Settings, or not consented to.
        case off
        /// The relay server is not one Kannu connects to (`SecurityURLPolicy`).
        case invalidServer
        case connecting
        case listening
        /// Waiting to try again: `httpStatus` is the relay's refusal, nil for a network failure.
        case retrying(at: Date, httpStatus: Int?)
    }

    @Published private(set) var snapshot = ClaudeCloudRelay.Snapshot()
    @Published private(set) var status: Status = .off

    nonisolated private static let log = os.Logger(subsystem: "com.kannu.app", category: "CloudRelay")

    private var isStarted = false
    private var streamTask: Task<Void, Never>?
    private var urlSession: URLSession?
    /// Bumped on every disconnect, so a superseded stream's late updates change nothing.
    private var generation = 0
    /// The server and topic of the current stream: a new relay or a new key starts from nothing.
    private var endpoint: String?
    /// The relay time of the last message, so a deliberate reconnect (wake, a setting) resumes there.
    private var lastMessageTime: Int?
    private var cancellables = Set<AnyCancellable>()
    private var wakeObserver: NSObjectProtocol?

    private init() {}

    var isEnabled: Bool {
        Defaults[.claudeCloudRelayEnabled] && Defaults[.claudeCloudRelayConsentedAt] != nil
    }

    // MARK: - Lifecycle

    /// Runs with the agent monitor: `continueLaunch()` and the Agents feature switch.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        // `options: []`: no event on subscribing (AGENTS.md); the reconnect below is the first.
        // Debounced, so typing a server address does not open a connection per keystroke.
        Defaults.publisher(keys: .claudeCloudRelayEnabled, .claudeCloudRelayConsentedAt, .claudeCloudRelayServerURL,
                           options: [])
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                Task { @MainActor in self?.reconnect() }
            }
            .store(in: &cancellables)
        // Sleep drops the connection without a word; a fresh one resumes where the last left off.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconnect() }
        }
        reconnect()
    }

    func stop() {
        isStarted = false
        cancellables.removeAll()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        disconnect()
        endpoint = nil
        lastMessageTime = nil
        status = .off
        publish(ClaudeCloudRelay.Snapshot())
    }

    /// Drops the stream and, when the feature is on, opens a fresh one.
    func reconnect() {
        disconnect()
        guard isStarted, isEnabled, let secret = ensureKey(),
              let credentials = ClaudeCloudRelay.credentials(secret: secret) else {
            endpoint = nil
            lastMessageTime = nil
            status = .off
            publish(ClaudeCloudRelay.Snapshot())
            return
        }
        let server = Defaults[.claudeCloudRelayServerURL].trimmingCharacters(in: .whitespacesAndNewlines)
        guard SecurityURLPolicy.isAllowedCloudRelayServerURL(server) else {
            status = .invalidServer
            var next = snapshot
            next.connected = false
            publish(next)
            return
        }
        let target = server + " " + credentials.topic
        if endpoint != target {
            endpoint = target
            lastMessageTime = nil
            publish(ClaudeCloudRelay.Snapshot())
        }
        connect(credentials: credentials, server: server)
    }

    private func disconnect() {
        generation &+= 1
        streamTask?.cancel()
        streamTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    // MARK: - The relay key

    /// The relay key, created the first time it is needed. Nil only if the system has no randomness.
    @discardableResult
    func ensureKey() -> String? {
        let stored = SecureSecretsStore.value(for: .claudeCloudRelaySecret)
        if ClaudeCloudRelay.credentials(secret: stored) != nil { return stored }
        guard let fresh = ClaudeCloudRelay.newSecret() else { return nil }
        SecureSecretsStore.set(fresh, for: .claudeCloudRelaySecret)
        return fresh
    }

    /// Replaces the key. Every cloud environment holding the old one stops reporting until it gets
    /// the new one, which is the point: it is how a leaked key is revoked.
    func regenerateKey() {
        guard let fresh = ClaudeCloudRelay.newSecret() else { return }
        SecureSecretsStore.set(fresh, for: .claudeCloudRelaySecret)
        Self.log.notice("cloud relay key replaced")
        reconnect()
    }

    /// The cloud environment's variables, copied concealed so clipboard managers skip them.
    @discardableResult
    func copyEnvironmentVariables() -> Bool {
        guard let key = ensureKey() else { return false }
        NSPasteboard.general.setConcealedString(
            ClaudeCloudRelaySetup.environmentLines(secret: key, server: Defaults[.claudeCloudRelayServerURL]))
        return true
    }

    // MARK: - The stream

    private enum Update: Sendable {
        case opened
        case line(ClaudeCloudRelay.Line)
        case closed(retryAt: Date, httpStatus: Int?, consecutiveFailures: Int)
    }

    private func connect(credentials: ClaudeCloudRelay.Credentials, server: String) {
        let generation = generation
        let session = URLSession(configuration: Self.streamConfiguration())
        urlSession = session
        status = .connecting
        let staleMinutes = Defaults[.agentStatusStaleMinutes]
        let resumeFrom = lastMessageTime
        streamTask = Task.detached(priority: .utility) { [weak self] in
            await Self.stream(session: session, credentials: credentials, server: server,
                              staleMinutes: staleMinutes, lastMessageTime: resumeFrom) { update in
                await self?.handle(update, generation: generation)
            }
        }
    }

    private func handle(_ update: Update, generation: Int) {
        guard generation == self.generation else { return }
        var next = snapshot
        switch update {
        case .opened:
            status = .listening
            next.connected = true
            Self.log.notice("listening to the cloud relay")
        case .line(.event(let report)):
            lastMessageTime = max(lastMessageTime ?? 0, Int(report.receivedAt.timeIntervalSince1970))
            next = ClaudeCloudRelay.applying(report, to: next, now: Date())
            // The state only: it comes from a closed set and names nobody's session or repository.
            let state = report.state
            Self.log.debug("a cloud session reported \(state, privacy: .public)")
        case .line(.check(_, let at)):
            lastMessageTime = max(lastMessageTime ?? 0, Int(at.timeIntervalSince1970))
            next.lastCheckAt = at
            Self.log.notice("cloud relay test message received")
        case .line:
            return
        case .closed(let retryAt, let httpStatus, let failures):
            status = .retrying(at: retryAt, httpStatus: httpStatus)
            // One quick retry keeps a held yellow: a stream that drops and comes straight back has
            // missed nothing, since it resumes from the last message. A second failure in a row, or
            // a refusal, means nothing is listening (REGRESSIONS entry 12).
            if httpStatus != nil || failures >= 2 {
                next.connected = false
            }
        }
        publish(next)
    }

    /// Publishes only a changed snapshot, and wakes the monitor only when its cards could change.
    private func publish(_ next: ClaudeCloudRelay.Snapshot) {
        guard next != snapshot else { return }
        let cardsChanged = next.events != snapshot.events || next.connected != snapshot.connected
        snapshot = next
        if cardsChanged {
            CursorAgentStatusMonitor.shared.cloudRelayDidChange()
        }
    }

    nonisolated private static func streamConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        // ntfy sends a keepalive every 45 s: a stream silent for 150 s is dead.
        configuration.timeoutIntervalForRequest = 150
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return configuration
    }

    /// The connect, read and retry loop, off the main actor until it has something to report.
    nonisolated private static func stream(
        session: URLSession,
        credentials: ClaudeCloudRelay.Credentials,
        server: String,
        staleMinutes: Int,
        lastMessageTime: Int?,
        deliver: @escaping @Sendable (Update) async -> Void
    ) async {
        var lastTime = lastMessageTime
        var backoff: TimeInterval = 0
        var failures = 0
        while !Task.isCancelled {
            let since = ClaudeCloudRelay.resumePoint(lastMessageTime: lastTime, staleMinutes: staleMinutes, now: Date())
            guard let url = ClaudeCloudRelay.subscribeURL(server: server, topic: credentials.topic, since: since) else {
                return
            }
            var refusal: Int?
            do {
                let (bytes, response) = try await session.bytes(from: url, delegate: RefuseRedirects())
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 {
                    backoff = 0
                    failures = 0
                    await deliver(.opened)
                    var splitter = ClaudeCloudRelay.LineSplitter()
                    for try await byte in bytes {
                        guard let raw = splitter.append(byte) else { continue }
                        let line = ClaudeCloudRelay.parse(line: raw, credentials: credentials)
                        switch line {
                        case .event(let event):
                            lastTime = max(lastTime ?? 0, Int(event.receivedAt.timeIntervalSince1970))
                            await deliver(.line(line))
                        case .check(_, let at):
                            lastTime = max(lastTime ?? 0, Int(at.timeIntervalSince1970))
                            await deliver(.line(line))
                        case .open, .keepalive:
                            break
                        case .ignored(let rejection):
                            log.debug("ignored a relay line: \(String(describing: rejection), privacy: .public)")
                        }
                    }
                    log.notice("the cloud relay stream ended")
                } else {
                    refusal = status
                    log.notice("the cloud relay refused the stream: HTTP \(status)")
                }
            } catch {
                if Task.isCancelled { return }
                let code = (error as? URLError)?.code.rawValue ?? -1
                log.notice("the cloud relay stream failed: error \(code)")
            }
            if Task.isCancelled { return }
            failures += 1
            backoff = ClaudeCloudRelay.nextBackoff(after: backoff, httpStatus: refusal)
            await deliver(.closed(retryAt: Date().addingTimeInterval(backoff), httpStatus: refusal,
                                  consecutiveFailures: failures))
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
        }
    }
}

/// The stream's URL carries the topic, so following a redirect would hand it to whatever server the
/// relay names. The redirect response itself ends the attempt instead.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
