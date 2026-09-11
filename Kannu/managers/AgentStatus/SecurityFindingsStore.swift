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

/// What the last ingested snapshot said about itself — shown in Settings so a partial scan is
/// never mistaken for a clean one.
struct ADRScanRecord: Codable, Equatable, Defaults.Serializable {
    enum Origin: String, Codable {
        /// A file that appeared in the watched directory (written by the user's own scheduler).
        case watched
        /// A scan Kannu ran itself (phase 1).
        case kannu
    }

    let date: Date
    let origin: Origin
    let fileName: String
    let assetCount: Int
    let findingCount: Int
    let reviewCount: Int
    let coverageComplete: Bool
    let coverageGaps: Int
    let catalogVersion: String
    let schemaVersion: String
}

extension SecurityFindingSnooze: Defaults.Serializable {}
extension ADRSessionAnalysis: Defaults.Serializable {}
extension HookSightingRecords: Defaults.Serializable {}
extension MCPServerWatch.Baseline: Defaults.Serializable {}
extension MCPServerWatch.Addition: Defaults.Serializable {}

/// Owns the findings the user sees, their acknowledgements and snoozes, and the watch on the
/// snapshot directory. Watch mode is the whole of phase 0: whoever runs `adr-discovery` (a
/// launchd job, a fleet scheduler, the user by hand), the newest `snapshot-*.json` in the
/// directory is what Kannu shows.
@MainActor
final class SecurityFindingsStore: ObservableObject {
    static let shared = SecurityFindingsStore()

    /// Discovery findings from the newest snapshot plus Kannu's own native ones.
    @Published private(set) var findings: [AgentSecurityFinding] = []
    @Published private(set) var reviewQueue: [ADRSnapshot.ReviewItem] = []
    @Published private(set) var lastScan: ADRScanRecord?
    /// Why the newest snapshot could not be read, if it could not.
    @Published private(set) var snapshotError: String?
    @Published private(set) var acknowledgedIDs: Set<String>
    @Published private(set) var snoozes: [SecurityFindingSnooze]
    /// A scan Kannu started is in flight.
    @Published private(set) var isScanning = false
    @Published private(set) var lastKannuScanAt: Date?
    @Published private(set) var lastScanError: String?

    private static let logger = os.Logger(subsystem: "com.kannu.app", category: "SecurityFindings")

    private var directorySource: DispatchSourceFileSystemObject?
    private var reloadTask: Task<Void, Never>?
    private var watchedPath: String?
    private var reloadGeneration = 0
    private var discoveryFindings: [AgentSecurityFinding] = []
    private var nativeFindings: [AgentSecurityFinding] = []
    private var detectionFindings: [AgentSecurityFinding] = []
    /// Sightings from the hook's local checks, kept past their session until acknowledged.
    private var sightingRecords = HookSightingRecords()
    private var sightingFindings: [AgentSecurityFinding] = []
    /// ADR Detection verdicts, newest first, one per conversation (capped).
    @Published private(set) var analyses: [ADRSessionAnalysis] = []
    @Published private(set) var analyzingConversationIDs: Set<String> = []
    @Published private(set) var lastAnalysisError: String?
    private static let analysisCap = 50
    private var cancellables = Set<AnyCancellable>()
    private var cadenceTimer: Timer?
    /// When Kannu's own scan started, so the snapshot it writes is recorded as Kannu's even when
    /// the directory watcher ingests it first.
    private var kannuScanStartedAt: Date?
    /// Daily scans, and sooner ones when an agent's MCP servers changed (Kannu-run scans only).
    private var scanTrigger = ADRScanTrigger(interval: automaticScanInterval, debounce: configChangeScanDebounce)
    /// Kannu's own "new MCP server" check: what each settings file declared, and what appeared.
    private var mcpBaseline = MCPServerWatch.Baseline()
    private var mcpAdditions: [MCPServerWatch.Addition] = []
    private var mcpFindings: [AgentSecurityFinding] = []
    private var mcpReadCache: [String: MCPServerWatch.CachedRead] = [:]
    private var mcpRefreshInFlight = false
    static let mcpAdditionCap = 50

    /// Kannu-run scans: at most daily on their own, sooner when a config changed.
    static let automaticScanInterval: TimeInterval = 24 * 3600
    static let configChangeScanDebounce: TimeInterval = 300
    static let cadenceTickInterval: TimeInterval = 60

    private init() {
        acknowledgedIDs = Set(Defaults[.adrAcknowledgedFindingIDs])
        snoozes = Defaults[.adrFindingSnoozes]
        lastScan = Defaults[.adrLastScan]
        lastKannuScanAt = Defaults[.adrLastKannuScanAt]
        analyses = Defaults[.adrSessionAnalyses]
        detectionFindings = analyses.compactMap { $0.finding() }
        sightingRecords = Defaults[.hookSightingRecords]
        sightingFindings = sightingRecords.findings
        mcpBaseline = Defaults[.mcpServerBaseline]
        mcpAdditions = Defaults[.mcpServerAdditions]
        mcpFindings = mcpAdditions.map { $0.finding(home: Self.homePath) }
    }

    func analysis(for conversationID: String) -> ADRSessionAnalysis? {
        analyses.first { $0.conversationID == conversationID }
    }

    func isAnalyzing(_ conversationID: String) -> Bool {
        analyzingConversationIDs.contains(conversationID)
    }

    /// The MCP configuration files whose edits should prompt a fresh scan. Read for mtime only.
    static var homePath: String { FileManager.default.homeDirectoryForCurrentUser.path }

    static var policyFileURL: URL? {
        let raw = Defaults[.adrPolicyFile].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The directory Kannu watches for snapshots: the user's choice, else `~/.kannu/adr/discovery`.
    static var snapshotDirectory: URL {
        let custom = Defaults[.adrSnapshotDirectory].trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kannu/adr/discovery", isDirectory: true)
    }

    var ranking: SecurityFindingPriority.Ranking {
        SecurityFindingPriority.rank(findings, acknowledged: acknowledgedIDs, snoozes: snoozes)
    }

    // MARK: - Lifecycle

    func start() {
        installDirectoryWatcher()
        reloadNewestSnapshot()
        // Kannu's own findings ride on the session list the monitor already publishes.
        cancellables.removeAll()
        CursorAgentStatusMonitor.shared.$sessions
            .sink { [weak self] sessions in
                self?.updateNativeFindings(from: sessions)
                self?.recordSightings(from: sessions)
            }
            .store(in: &cancellables)
        // The hook reads marker files for the local-check settings; keep them in step.
        for key in [Defaults.Keys.detectHiddenText, .warnAgentAboutHiddenText, .detectSecrets, .detectSensitivePaths] {
            Defaults.publisher(key, options: [])
                .sink { [weak self] _ in Task { @MainActor in self?.syncLocalCheckSettings() } }
                .store(in: &cancellables)
        }
        syncLocalCheckSettings()
        // Know whether the tool is there before the first cadence tick; cheap and bounded.
        ADRConnection.shared.checkAgain()
        Defaults.publisher(.watchMCPServers, options: [])
            .sink { [weak self] change in
                Task { @MainActor in
                    if change.newValue { self?.cadenceTick() } else { self?.forgetMCPServers() }
                }
            }
            .store(in: &cancellables)
        // The first tick only learns what each file declares (and seeds the scan trigger).
        cadenceTick()
        cadenceTimer?.invalidate()
        cadenceTimer = Timer.scheduledTimer(withTimeInterval: Self.cadenceTickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.cadenceTick() }
        }
        // Saved hidden-text sightings must show after a relaunch even when no ADR snapshot is
        // ever ingested and the native findings never change.
        publishFindings()
    }

    func stop() {
        directorySource?.cancel()
        directorySource = nil
        watchedPath = nil
        reloadTask?.cancel()
        reloadTask = nil
        cancellables.removeAll()
        cadenceTimer?.invalidate()
        cadenceTimer = nil
    }

    /// Re-points the watcher after the user changes the directory in Settings.
    func directoryChanged() {
        stop()
        start()
    }

    // MARK: - User actions

    func acknowledge(_ id: String) {
        acknowledgedIDs.insert(id)
        Defaults[.adrAcknowledgedFindingIDs] = Array(acknowledgedIDs).sorted()
    }

    func snooze(_ id: String, for interval: TimeInterval) {
        let until = Date().addingTimeInterval(interval)
        snoozes = SecurityFindingPriority.pruned(snoozes.filter { $0.id != id }, keeping: Set(findings.map(\.id)))
            + [SecurityFindingSnooze(id: id, until: until)]
        Defaults[.adrFindingSnoozes] = snoozes
    }

    func clearAcknowledgements() {
        acknowledgedIDs = []
        snoozes = []
        Defaults[.adrAcknowledgedFindingIDs] = []
        Defaults[.adrFindingSnoozes] = []
    }

    /// Puts a request about this finding on the clipboard, ready to paste into the user's agent.
    /// Built by `SecurityFindingGuide` — no key, hidden text or chat name — and never logged.
    func copyAgentPrompt(for finding: AgentSecurityFinding) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(SecurityFindingGuide.agentPrompt(for: finding), forType: .string)
    }

    // MARK: - Kannu-run scans

    /// Runs the connected `adr-discovery` into the snapshot folder. The watcher then picks up
    /// the file like any other; the explicit reload after exit only shortens the wait. The
    /// invocation is `ADRDiscoveryCommand`, pinned by tests — never assembled here.
    func runScanNow(reason: String = "manual") {
        guard !isScanning else { return }
        scanTrigger.scanStarted()
        guard let executable = ADRConnection.shared.discovery.executable else {
            lastScanError = String(localized: "ADR Discovery is not connected.")
            return
        }
        let directory = Self.snapshotDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let arguments = ADRDiscoveryCommand.arguments(outputDirectory: directory, policyFile: Self.policyFileURL)
        guard ADRDiscoveryCommand.isValidScan(arguments: arguments) else { return }

        isScanning = true
        lastScanError = nil
        kannuScanStartedAt = Date()
        Self.logger.info("adr-discovery scan starting (\(reason, privacy: .public))")

        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = directory
            // `--json` also prints the whole snapshot to stdout; the file is what we read.
            process.standardOutput = FileHandle.nullDevice
            let stderr = Pipe()
            process.standardError = stderr
            var collected = Data()
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if collected.count < 16_384 { collected.append(chunk) }
            }
            var status: Int32 = -1
            var failure: String?
            do {
                try process.run()
                let deadline = Date().addingTimeInterval(ADRDiscoveryCommand.timeout)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
                if process.isRunning {
                    process.terminate()
                    let killDeadline = Date().addingTimeInterval(3)
                    while process.isRunning && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.1) }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    failure = String(localized: "adr-discovery did not finish within \(Int(ADRDiscoveryCommand.timeout)) s and was stopped.")
                }
                process.waitUntilExit()
                status = process.terminationStatus
            } catch {
                failure = error.localizedDescription
            }
            stderr.fileHandleForReading.readabilityHandler = nil
            let stderrTail = String(decoding: collected.suffix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isScanning = false
                    self.lastKannuScanAt = Date()
                    Defaults[.adrLastKannuScanAt] = self.lastKannuScanAt
                    if let failure {
                        self.lastScanError = failure
                    } else if ADRDiscoveryCommand.producedSnapshot(exitStatus: status) {
                        self.lastScanError = nil
                        self.reloadNewestSnapshot()
                    } else {
                        self.lastScanError = String(localized: "adr-discovery exited \(status). \(stderrTail)")
                    }
                    Self.logger.info("adr-discovery scan finished status=\(status, privacy: .public)")
                }
            }
        }
    }

    /// Once a minute: read the agents' MCP settings (only files that changed are parsed, off the
    /// main thread), then decide on a Kannu-run scan — daily, or sooner when servers changed.
    private func cadenceTick() {
        refreshMCPServers { [weak self] inventory in self?.evaluateAutomaticScan(inventory: inventory) }
    }

    private func evaluateAutomaticScan(inventory: [String: [String]]?) {
        guard Defaults[.adrRunScansEnabled], ADRConnection.shared.isConnected, !isScanning else { return }
        if let reason = scanTrigger.evaluate(now: Date(), lastScan: lastKannuScanAt, inventory: inventory) {
            runScanNow(reason: reason.rawValue)
        }
    }

    // MARK: - New MCP servers (Kannu's own check)

    /// Reads when either the watch or Kannu-run scans need it. Files are 60 KB–1 MB and rewritten
    /// often, so the read happens on a utility queue (REGRESSIONS entry 11) and only for files
    /// whose modification date or size moved.
    private func refreshMCPServers(then completion: @escaping @MainActor ([String: [String]]?) -> Void) {
        let watching = Defaults[.watchMCPServers]
        let forScans = Defaults[.adrRunScansEnabled] && ADRConnection.shared.isConnected
        guard watching || forScans, !mcpRefreshInFlight else {
            completion(nil)
            return
        }
        mcpRefreshInFlight = true
        let home = Self.homePath
        let roots = watching ? MCPServerWatch.projectRoots(CursorAgentStatusMonitor.shared.sessions.map(\.cwd), home: home) : []
        let locations = MCPServerWatch.globalLocations(home: home) + roots.flatMap(MCPServerWatch.projectLocations(root:))
        let cache = mcpReadCache
        DispatchQueue.global(qos: .utility).async {
            let result = MCPServerWatch.read(locations, cache: cache)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.mcpRefreshInFlight = false
                    self.mcpReadCache = result.cache
                    if watching, Defaults[.watchMCPServers] {
                        self.applyMCPReads(result.reads, locations: locations)
                    }
                    completion(MCPServerWatch.inventory(result.reads, home: home))
                }
            }
        }
    }

    private func applyMCPReads(_ reads: [String: [MCPServerWatch.Server]], locations: [MCPServerWatch.Location]) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let (baseline, additions) = MCPServerWatch.compare(baseline: mcpBaseline, reads: reads, locations: locations, nowMs: nowMs)
        if baseline != mcpBaseline {
            mcpBaseline = baseline
            Defaults[.mcpServerBaseline] = baseline
        }
        if !additions.isEmpty {
            Self.logger.info("new MCP servers: \(additions.count, privacy: .public)")
        }
        let updated = Array(MCPServerWatch.pruning(mcpAdditions + additions, reads: reads).suffix(Self.mcpAdditionCap))
        guard updated != mcpAdditions else { return }
        mcpAdditions = updated
        Defaults[.mcpServerAdditions] = updated
        mcpFindings = updated.map { $0.finding(home: Self.homePath) }
        publishFindings()
    }

    /// Turning the watch off forgets everything, so turning it back on learns afresh instead of
    /// reporting whatever changed in between.
    private func forgetMCPServers() {
        mcpBaseline = MCPServerWatch.Baseline()
        Defaults[.mcpServerBaseline] = mcpBaseline
        mcpAdditions = []
        Defaults[.mcpServerAdditions] = []
        mcpReadCache = [:]
        if !mcpFindings.isEmpty {
            mcpFindings = []
            publishFindings()
        }
    }

    // MARK: - Native findings

    private func updateNativeFindings(from sessions: [AgentSessionStatus]) {
        let mapped = AgentSecurityFinding.nativeFindings(from: sessions, existing: nativeFindings)
        guard mapped != nativeFindings else { return }
        nativeFindings = mapped
        publishFindings()
    }

    // MARK: - Sightings (Kannu's own local checks in the hook, v34+)

    private var enabledLocalChecks: HookSightingRecords.Enabled {
        HookSightingRecords.Enabled(hiddenText: Defaults[.detectHiddenText], secrets: Defaults[.detectSecrets],
                                    sensitivePaths: Defaults[.detectSensitivePaths])
    }

    private func recordSightings(from sessions: [AgentSessionStatus]) {
        let updated = sightingRecords.upserting(sessions, enabled: enabledLocalChecks)
        guard updated != sightingRecords else { return }
        storeSightingRecords(updated)
    }

    private func storeSightingRecords(_ records: HookSightingRecords) {
        sightingRecords = records
        Defaults[.hookSightingRecords] = records
        sightingFindings = records.findings
        publishFindings()
    }

    /// Writes or removes the hook's marker files. Turning a check off also forgets its saved
    /// sightings: kept, their acknowledgements would be pruned and turning it back on would show
    /// and push them all again.
    private func syncLocalCheckSettings() {
        let enabled = enabledLocalChecks
        let detect = enabled.hiddenText
        let warn = detect && Defaults[.warnAgentAboutHiddenText]
        let directory = AgentHookInstaller.statusDirectory
        let fileManager = FileManager.default
        func place(_ name: String, present: Bool) {
            let url = directory.appendingPathComponent(name)
            if present {
                guard !fileManager.fileExists(atPath: url.path) else { return }
                try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
                fileManager.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
            } else if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }
        place(HiddenTextIncident.detectionOffMarker, present: !detect)
        place(HiddenTextIncident.warnAgentMarker, present: warn)
        place(SecretSighting.detectionOffMarker, present: !enabled.secrets)
        place(SensitivePathSighting.detectionOffMarker, present: !enabled.sensitivePaths)
        let kept = sightingRecords.keepingOnly(enabled)
        if kept != sightingRecords { storeSightingRecords(kept) }
    }

    private func publishFindings() {
        let combined = discoveryFindings + nativeFindings + detectionFindings + sightingFindings + mcpFindings
        if combined != findings { findings = combined }
    }

    // MARK: - ADR Detection (session analysis, explicit request only)

    private static let detectionLogger = os.Logger(subsystem: "com.kannu.app", category: "SessionAnalysis")

    /// Everything the run needs, read on the main actor before the worker starts. Nil with a
    /// reason when the feature is off, the checkout is not ready, or the chat has no transcript.
    struct AnalysisFailure: LocalizedError, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    struct AnalysisPlan {
        let conversationID: String
        let chatName: String?
        let transcript: URL
        let arguments: [String]
        let environment: [String: String]
        let uv: URL
        let checkout: URL
        let report: URL
        let timeout: TimeInterval
    }

    static func analysisOptions() -> ADRDetectionCommand.Options {
        ADRDetectionCommand.Options(
            triageEnabled: Defaults[.adrDetectionTriageEnabled],
            triageModel: Defaults[.adrDetectionTriageModel].trimmingCharacters(in: .whitespaces),
            reasoningModel: Defaults[.adrDetectionReasoningModel].trimmingCharacters(in: .whitespaces),
            threatIntelligence: Defaults[.adrDetectionContextThreatIntelligence],
            sourceCode: Defaults[.adrDetectionContextSourceCode],
            policy: Defaults[.adrDetectionContextPolicy],
            timeoutSeconds: max(60, Defaults[.adrDetectionTimeoutSeconds]),
            maxTurns: 60,
            maxMessages: max(20, Defaults[.adrDetectionMaxMessages])
        )
    }

    func analysisPlan(for session: AgentSessionStatus) -> Result<AnalysisPlan, AnalysisFailure> {
        guard Defaults[.adrDetectionEnabled] else { return .failure(AnalysisFailure(String(localized: "Session analysis is off (Settings › Security findings)."))) }
        guard let uv = ADRConnection.shared.detection.uv else {
            return .failure(AnalysisFailure(String(localized: "ADR Detection checkout is not ready: \(ADRConnection.shared.detection.caption)")))
        }
        guard session.provider.lowercased() == "claude",
              let transcript = CursorAgentStatusMonitor.shared.claudeTranscriptURL(forConversationID: session.conversationID) else {
            return .failure(AnalysisFailure(String(localized: "Only Claude Code chats with an on-disk transcript can be analysed.")))
        }
        let checkout = URL(fileURLWithPath: (Defaults[.adrDetectionCheckout] as NSString).expandingTildeInPath, isDirectory: true)
        let directory = ADRDetectionCommand.defaultDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let adapter = directory.appendingPathComponent(ADRDetectionCommand.adapterFileName)
        let report = directory.appendingPathComponent("\(session.conversationID).json")
        let options = Self.analysisOptions()
        let arguments = ADRDetectionCommand.arguments(checkout: checkout, adapter: adapter, transcript: transcript,
                                                      report: report, options: options)
        guard ADRDetectionCommand.isValidAnalysis(arguments: arguments) else { return .failure(AnalysisFailure("invalid invocation")) }
        let path = [uv.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
            .joined(separator: ":")
        let environment = ADRDetectionCommand.environment(
            openAIKey: options.triageEnabled ? SecureSecretsStore.value(for: .openaiAPIKey) : nil,
            anthropicKey: Defaults[.adrDetectionUseAnthropicAPIKey] ? SecureSecretsStore.value(for: .claudeAPIKey) : nil,
            path: path,
            home: FileManager.default.homeDirectoryForCurrentUser.path
        )
        if options.triageEnabled, environment["OPENAI_API_KEY"] == nil {
            return .failure(AnalysisFailure(String(localized: "Triage is on but no OpenAI API key is stored.")))
        }
        if Defaults[.adrDetectionUseAnthropicAPIKey], environment["ANTHROPIC_API_KEY"] == nil {
            return .failure(AnalysisFailure(String(localized: "\"Use an Anthropic API key\" is on but no key is stored.")))
        }
        return .success(AnalysisPlan(conversationID: session.conversationID, chatName: session.chatName, transcript: transcript,
                                     arguments: arguments, environment: environment, uv: uv, checkout: checkout, report: report,
                                     timeout: ADRDetectionCommand.processTimeout(forReasoningTimeout: options.timeoutSeconds)))
    }

    /// Runs one analysis. The adapter is (re)written first so the copy on disk is always this
    /// build's; the process runs on a utility worker with a whitelisted environment.
    func runAnalysis(_ plan: AnalysisPlan) {
        guard !analyzingConversationIDs.contains(plan.conversationID) else { return }
        analyzingConversationIDs.insert(plan.conversationID)
        lastAnalysisError = nil
        Self.detectionLogger.notice("session analysis starting (\(plan.conversationID.prefix(8), privacy: .public))")
        let adapterURL = URL(fileURLWithPath: plan.arguments[4])
        DispatchQueue.global(qos: .utility).async {
            do {
                try Data(ADRDetectionCommand.adapterSource.utf8).write(to: adapterURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: adapterURL.path)
            } catch {
                self.finishAnalysis(plan, outcome: .failure(AnalysisFailure(error.localizedDescription)))
                return
            }
            let process = Process()
            process.executableURL = plan.uv
            process.arguments = plan.arguments
            process.currentDirectoryURL = plan.checkout
            process.environment = plan.environment
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            var out = Data(), err = Data()
            stdout.fileHandleForReading.readabilityHandler = { h in let c = h.availableData; if out.count < 1_000_000 { out.append(c) } }
            stderr.fileHandleForReading.readabilityHandler = { h in let c = h.availableData; if err.count < 64_000 { err.append(c) } }
            do {
                try process.run()
            } catch {
                self.finishAnalysis(plan, outcome: .failure(AnalysisFailure(error.localizedDescription)))
                return
            }
            let deadline = Date().addingTimeInterval(plan.timeout)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
            var timedOut = false
            if process.isRunning {
                timedOut = true
                process.terminate()
                let killDeadline = Date().addingTimeInterval(5)
                while process.isRunning && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.2) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            if timedOut {
                self.finishAnalysis(plan, outcome: .failure(AnalysisFailure(String(localized: "Analysis did not finish within \(Int(plan.timeout)) s and was stopped."))))
                return
            }
            // The verdict is the last JSON line on stdout; upstream may print progress above it.
            let lastLine = String(decoding: out, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? ""
            do {
                let analysis = try ADRSessionAnalysis.parse(Data(lastLine.utf8), conversationID: plan.conversationID,
                                                            chatName: plan.chatName, reportPath: plan.report.path)
                self.finishAnalysis(plan, outcome: .success(analysis))
            } catch ADRSessionAnalysis.ParseError.adapterError(let reason) {
                self.finishAnalysis(plan, outcome: .failure(AnalysisFailure(reason)))
            } catch {
                let tail = String(decoding: err.suffix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                self.finishAnalysis(plan, outcome: .failure(AnalysisFailure(String(localized: "adr adapter exited \(process.terminationStatus) without a verdict. \(tail)"))))
            }
        }
    }

    private nonisolated func finishAnalysis(_ plan: AnalysisPlan, outcome: Result<ADRSessionAnalysis, AnalysisFailure>) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.analyzingConversationIDs.remove(plan.conversationID)
                switch outcome {
                case .success(let analysis):
                    self.record(analysis)
                    Self.detectionLogger.notice("session analysis finished malicious=\(analysis.isMalicious, privacy: .public) confidence=\(analysis.confidence, privacy: .public)")
                case .failure(let failure):
                    self.lastAnalysisError = failure.message
                    Self.detectionLogger.error("session analysis failed: \(failure.message, privacy: .public)")
                }
            }
        }
    }

    private func record(_ analysis: ADRSessionAnalysis) {
        var list = analyses.filter { $0.conversationID != analysis.conversationID }
        list.insert(analysis, at: 0)
        if list.count > Self.analysisCap { list = Array(list.prefix(Self.analysisCap)) }
        analyses = list
        Defaults[.adrSessionAnalyses] = list
        let firstSeen = Dictionary(detectionFindings.map { ($0.id, $0.firstSeen) }, uniquingKeysWith: { a, _ in a })
        detectionFindings = list.compactMap { $0.finding(existingFirstSeen: nil) }
            .map { finding in
                guard let seen = firstSeen[finding.id] else { return finding }
                return AgentSecurityFinding(id: finding.id, source: finding.source, rule: finding.rule, severity: finding.severity,
                                            title: finding.title, summary: finding.summary, evidence: finding.evidence,
                                            assetName: finding.assetName, assetPath: finding.assetPath, sessionID: finding.sessionID,
                                            firstSeen: seen, kannuOnlyEvidence: finding.kannuOnlyEvidence)
            }
        publishFindings()
    }

    func forgetAnalysis(for conversationID: String) {
        let list = analyses.filter { $0.conversationID != conversationID }
        guard list.count != analyses.count else { return }
        analyses = list
        Defaults[.adrSessionAnalyses] = list
        detectionFindings = list.compactMap { $0.finding() }
        publishFindings()
    }

    // MARK: - Ingest

    /// Reads the newest snapshot in the watched directory, if any. A real snapshot from a
    /// developer Mac is ~7 MB (every asset carries its evidence, and the coverage block lists
    /// every swept root), so the read and both decode passes run on a utility queue and only
    /// the result crosses back to the main actor. Runs only when the directory changed.
    func reloadNewestSnapshot() {
        let directory = Self.snapshotDirectory
        guard let url = ADRSnapshot.newestSnapshotURL(in: directory) else {
            // No file is not an error — it is the state before the first scan.
            snapshotError = nil
            return
        }
        let generation = reloadGeneration &+ 1
        reloadGeneration = generation
        let origin: ADRScanRecord.Origin = {
            guard let started = kannuScanStartedAt,
                  let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  written >= started.addingTimeInterval(-1) else { return .watched }
            return .kannu
        }()
        DispatchQueue.global(qos: .utility).async {
            let outcome: Result<ADRSnapshot, Error> = Result { try ADRSnapshot.load(from: url) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // A newer reload superseded this one while it was decoding.
                    guard self.reloadGeneration == generation else { return }
                    switch outcome {
                    case .success(let snapshot):
                        self.ingest(snapshot, origin: origin, fileName: url.lastPathComponent)
                        self.snapshotError = nil
                    case .failure(let error):
                        self.snapshotError = error.localizedDescription
                        Self.logger.error("snapshot unreadable: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    func ingest(_ snapshot: ADRSnapshot, origin: ADRScanRecord.Origin, fileName: String) {
        let now = Date()
        discoveryFindings = AgentSecurityFinding.findings(from: snapshot, existing: discoveryFindings, now: now)
        publishFindings()
        if reviewQueue != snapshot.reviewQueue { reviewQueue = snapshot.reviewQueue }

        // Acknowledgements and snoozes for findings that vanished are dropped: if the same
        // finding returns later it should be seen again, not silently pre-acknowledged.
        let ids = Set(findings.map(\.id))
        let keptAcks = acknowledgedIDs.intersection(ids)
        if keptAcks != acknowledgedIDs {
            acknowledgedIDs = keptAcks
            Defaults[.adrAcknowledgedFindingIDs] = Array(keptAcks).sorted()
        }
        let keptSnoozes = SecurityFindingPriority.pruned(snoozes, keeping: ids, now: now)
        if keptSnoozes != snoozes {
            snoozes = keptSnoozes
            Defaults[.adrFindingSnoozes] = keptSnoozes
        }

        let record = ADRScanRecord(
            date: now,
            origin: origin,
            fileName: fileName,
            assetCount: snapshot.assets.count,
            findingCount: snapshot.findings.count,
            reviewCount: snapshot.reviewQueue.count,
            coverageComplete: snapshot.coverage.isComplete,
            coverageGaps: snapshot.coverage.gapCount,
            catalogVersion: snapshot.catalogVersion,
            schemaVersion: snapshot.schemaVersion
        )
        if lastScan?.fileName != record.fileName || lastScan?.findingCount != record.findingCount {
            lastScan = record
            Defaults[.adrLastScan] = record
        }
    }

    // MARK: - Watching

    /// Same idiom as the agent-status directory watcher: a dispatch source on the directory
    /// fd, debounced, with the fd captured by value for the cancel handler.
    private func installDirectoryWatcher() {
        let directory = Self.snapshotDirectory
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard watchedPath != directory.path else { return }
        directorySource?.cancel()

        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directorySource = source
        watchedPath = directory.path
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            // A scan writes the file in one `os.replace`, but give a slow disk a beat.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.reloadNewestSnapshot()
        }
    }
}
