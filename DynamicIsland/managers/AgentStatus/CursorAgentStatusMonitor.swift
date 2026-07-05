import AppKit
import Combine
import CoreServices
import Defaults
import Foundation

@MainActor
final class CursorAgentStatusMonitor: ObservableObject {
    static let shared = CursorAgentStatusMonitor()

    @Published private(set) var trafficLightState: AgentTrafficLightState = .inactive

    private var eventStream: FSEventStreamRef?
    private var rescanTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var isRunning = false
    private var watchedPaths: [String] = []

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true
        installWatchers()
        scheduleRescan(delay: 0)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRescan(delay: 0)
            }
        }
    }

    func stop() {
        isRunning = false
        rescanTask?.cancel()
        rescanTask = nil
        pollTimer?.invalidate()
        pollTimer = nil
        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
            self.eventStream = nil
        }
        trafficLightState = .inactive
    }

    private func installWatchers() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        try? FileManager.default.createDirectory(
            at: AgentHookInstaller.statusDirectory,
            withIntermediateDirectories: true
        )
        watchedPaths = [
            CursorTranscriptParser.projectsDirectory.path,
            AgentHookInstaller.statusDirectory.path,
            home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage").path,
            home.appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage").path
        ]

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<CursorAgentStatusMonitor>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in
                monitor.scheduleRescan(delay: 1.0)
            }
        }

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else { return }

        eventStream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    private func scheduleRescan(delay: TimeInterval) {
        guard isRunning else { return }
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.rescan()
        }
    }

    private func rescan() async {
        guard isRunning else { return }

        let staleMinutes = Defaults[.agentStatusStaleMinutes]

        // Hook-reported status is the most accurate signal and works for any
        // supported tool (Cursor, VS Code, Codex).
        if let hookState = hookReportedState(staleMinutes: staleMinutes) {
            trafficLightState = hookState
            return
        }

        // Transcript polling is a Cursor-only fallback.
        guard isCursorRunning() else {
            trafficLightState = .inactive
            return
        }

        let paths = CursorTranscriptParser.listRecentTranscriptPaths(maxAgeMinutes: staleMinutes)
        guard !paths.isEmpty else {
            trafficLightState = .inactive
            return
        }

        var snapshots: [AgentSessionSnapshot] = []
        var ids = Set<String>()

        for path in paths {
            let sessionID = CursorTranscriptParser.sessionID(from: path)
            ids.insert(sessionID)
            let analysis = CursorTranscriptParser.analyze(path: path)
            snapshots.append(
                AgentSessionSnapshot(
                    sessionID: sessionID,
                    lastActivityMs: analysis.mtimeMs,
                    composerStatus: nil,
                    isDone: analysis.isDone,
                    hasActiveToolUse: analysis.hasActiveToolUse,
                    transcriptMtimeMs: analysis.mtimeMs
                )
            )
        }

        let composerMeta = CursorComposerStore.loadComposerMeta(forIDs: ids)
        snapshots = snapshots.map { snapshot in
            guard let meta = composerMeta[snapshot.sessionID] else { return snapshot }
            let lastActivity = max(snapshot.lastActivityMs, meta.updatedMs, meta.checkpointMs)
            return AgentSessionSnapshot(
                sessionID: snapshot.sessionID,
                lastActivityMs: lastActivity,
                composerStatus: meta.status,
                isDone: snapshot.isDone,
                hasActiveToolUse: snapshot.hasActiveToolUse,
                transcriptMtimeMs: max(snapshot.transcriptMtimeMs, meta.checkpointMs)
            )
        }

        guard let mostRecent = snapshots.max(by: { $0.lastActivityMs < $1.lastActivityMs }) else {
            trafficLightState = .inactive
            return
        }

        trafficLightState = AgentTrafficLightMapper.map(
            session: mostRecent,
            staleMinutes: staleMinutes,
            stoppedCollapseMinutes: Defaults[.agentStoppedCollapseMinutes]
        )
    }

    /// Aggregates per-conversation status files written by the agent hooks.
    /// Multiple concurrent sessions resolve as: any executing wins, then any
    /// thinking, then stopped. Active states that stopped updating are treated
    /// as stopped; entries older than the stale window are ignored entirely.
    private func hookReportedState(staleMinutes: Int, now: Date = Date()) -> AgentTrafficLightState? {
        let directory = AgentHookInstaller.statusDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let staleMs = Int64(staleMinutes) * 60_000
        let collapseMs = Int64(Defaults[.agentStoppedCollapseMinutes]) * 60_000
        let activeStaleMs: Int64 = 360_000

        var anyExecuting = false
        var anyThinking = false
        var anyStopped = false

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = json["state"] as? String else { continue }

            var tsMs = (json["ts"] as? NSNumber)?.int64Value ?? 0
            if tsMs <= 0,
               let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                tsMs = Int64(mtime.timeIntervalSince1970 * 1000)
            }

            guard nowMs - tsMs <= staleMs else {
                try? FileManager.default.removeItem(at: file)
                continue
            }

            let ageMs = nowMs - tsMs
            switch state {
            case "executing" where ageMs <= activeStaleMs:
                anyExecuting = true
            case "thinking" where ageMs <= activeStaleMs:
                anyThinking = true
            default:
                // Stopped (or abandoned active) sessions keep the red light
                // only for the collapse window, then the indicator hides.
                if ageMs <= collapseMs {
                    anyStopped = true
                }
            }
        }

        if anyExecuting { return .executing }
        if anyThinking { return .thinking }
        if anyStopped { return .stopped }
        return nil
    }

    private func isCursorRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return bundleID.hasPrefix("com.todesktop.") || bundleID == "com.cursor.Cursor"
        }
    }
}
