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

    @Published private(set) var findings: [AgentSecurityFinding] = []
    @Published private(set) var reviewQueue: [ADRSnapshot.ReviewItem] = []
    @Published private(set) var lastScan: ADRScanRecord?
    /// Why the newest snapshot could not be read, if it could not.
    @Published private(set) var snapshotError: String?
    @Published private(set) var acknowledgedIDs: Set<String>
    @Published private(set) var snoozes: [SecurityFindingSnooze]

    private static let logger = os.Logger(subsystem: "com.kannu.app", category: "SecurityFindings")

    private var directorySource: DispatchSourceFileSystemObject?
    private var reloadTask: Task<Void, Never>?
    private var watchedPath: String?

    private init() {
        acknowledgedIDs = Set(Defaults[.adrAcknowledgedFindingIDs])
        snoozes = Defaults[.adrFindingSnoozes]
        lastScan = Defaults[.adrLastScan]
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
    }

    func stop() {
        directorySource?.cancel()
        directorySource = nil
        watchedPath = nil
        reloadTask?.cancel()
        reloadTask = nil
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

    // MARK: - Ingest

    /// Reads the newest snapshot in the watched directory, if any. Safe to call often: the
    /// decode is a few hundred KB at most and only runs when the directory changed.
    func reloadNewestSnapshot() {
        let directory = Self.snapshotDirectory
        guard let url = ADRSnapshot.newestSnapshotURL(in: directory) else {
            // No file is not an error — it is the state before the first scan.
            snapshotError = nil
            return
        }
        do {
            let snapshot = try ADRSnapshot.load(from: url)
            ingest(snapshot, origin: .watched, fileName: url.lastPathComponent)
            snapshotError = nil
        } catch {
            snapshotError = error.localizedDescription
            Self.logger.error("snapshot unreadable: \(error.localizedDescription, privacy: .public)")
        }
    }

    func ingest(_ snapshot: ADRSnapshot, origin: ADRScanRecord.Origin, fileName: String) {
        let now = Date()
        let mapped = AgentSecurityFinding.findings(from: snapshot, existing: findings, now: now)
        if mapped != findings { findings = mapped }
        if reviewQueue != snapshot.reviewQueue { reviewQueue = snapshot.reviewQueue }

        // Acknowledgements and snoozes for findings that vanished are dropped: if the same
        // finding returns later it should be seen again, not silently pre-acknowledged.
        let ids = Set(mapped.map(\.id))
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
