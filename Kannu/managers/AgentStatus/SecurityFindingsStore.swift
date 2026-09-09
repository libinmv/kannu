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
    private var cancellables = Set<AnyCancellable>()
    private var cadenceTimer: Timer?
    /// When Kannu's own scan started, so the snapshot it writes is recorded as Kannu's even when
    /// the directory watcher ingests it first.
    private var kannuScanStartedAt: Date?
    /// Modification times of the MCP configs each agent reads, so a hand edit triggers a scan.
    private var configModificationDates: [String: Date] = [:]

    /// Kannu-run scans: at most daily on their own, sooner when a config changed.
    static let automaticScanInterval: TimeInterval = 24 * 3600
    static let configChangeScanDebounce: TimeInterval = 300
    static let cadenceTickInterval: TimeInterval = 60

    private init() {
        acknowledgedIDs = Set(Defaults[.adrAcknowledgedFindingIDs])
        snoozes = Defaults[.adrFindingSnoozes]
        lastScan = Defaults[.adrLastScan]
        lastKannuScanAt = Defaults[.adrLastKannuScanAt]
    }

    /// The MCP configuration files whose edits should prompt a fresh scan. Read for mtime only.
    static var watchedConfigFiles: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude.json"),
            home.appendingPathComponent(".claude/mcp.json"),
            home.appendingPathComponent(".cursor/mcp.json"),
            home.appendingPathComponent(".codex/config.toml"),
            home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        ]
    }

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
            }
            .store(in: &cancellables)
        // Know whether the tool is there before the first cadence tick; cheap and bounded.
        ADRConnection.shared.checkAgain()
        configModificationDates = Self.currentConfigModificationDates()
        cadenceTimer?.invalidate()
        cadenceTimer = Timer.scheduledTimer(withTimeInterval: Self.cadenceTickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluateAutomaticScan() }
        }
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

    // MARK: - Kannu-run scans

    /// Runs the connected `adr-discovery` into the snapshot folder. The watcher then picks up
    /// the file like any other; the explicit reload after exit only shortens the wait. The
    /// invocation is `ADRDiscoveryCommand`, pinned by tests — never assembled here.
    func runScanNow(reason: String = "manual") {
        guard !isScanning else { return }
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

    /// Once a minute: a daily scan, or a sooner one when an MCP config changed on disk.
    private func evaluateAutomaticScan() {
        guard Defaults[.adrRunScansEnabled], ADRConnection.shared.isConnected, !isScanning else { return }
        let now = Date()
        let sinceLast = lastKannuScanAt.map { now.timeIntervalSince($0) } ?? .infinity
        if sinceLast >= Self.automaticScanInterval {
            runScanNow(reason: "scheduled")
            return
        }
        let current = Self.currentConfigModificationDates()
        let changed = current != configModificationDates
        configModificationDates = current
        if changed, sinceLast >= Self.configChangeScanDebounce {
            runScanNow(reason: "config changed")
        }
    }

    private static func currentConfigModificationDates() -> [String: Date] {
        var out: [String: Date] = [:]
        for url in watchedConfigFiles {
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                out[url.path] = date
            }
        }
        return out
    }

    // MARK: - Native findings

    private func updateNativeFindings(from sessions: [AgentSessionStatus]) {
        let mapped = AgentSecurityFinding.nativeFindings(from: sessions, existing: nativeFindings)
        guard mapped != nativeFindings else { return }
        nativeFindings = mapped
        publishFindings()
    }

    private func publishFindings() {
        let combined = discoveryFindings + nativeFindings
        if combined != findings { findings = combined }
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
