import AppKit
import Combine
import CoreServices
import Defaults
import Foundation

@MainActor
final class CursorAgentStatusMonitor: ObservableObject {
    static let shared = CursorAgentStatusMonitor()

    @Published private(set) var trafficLightState: AgentTrafficLightState = .inactive
    @Published private(set) var shouldShowTrafficLight = false
    @Published private(set) var sessions: [AgentSessionStatus] = []

    private var eventStream: FSEventStreamRef?
    private var rescanTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var isRunning = false
    private var watchedPaths: [String] = []
    private var hadHookFilesThisCycle = false

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
        shouldShowTrafficLight = false
        sessions = []
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
        let collapseMinutes = Defaults[.agentStoppedCollapseMinutes]
        let inactiveMinutes = Defaults[.agentInactiveDisplayMinutes]

        let hookSessions = parseHookSessions(
            staleMinutes: staleMinutes,
            collapseMinutes: collapseMinutes,
            inactiveMinutes: inactiveMinutes
        )
        sessions = hookSessions.sorted { $0.updatedAt > $1.updatedAt }
        hadHookFilesThisCycle = hookSessions.contains { _ in true } || hadRecentHookFiles(staleMinutes: staleMinutes)

        let visibleSessions = hookSessions.filter(\.isVisible)
        if !visibleSessions.isEmpty {
            applyDisplay(from: visibleSessions)
            return
        }

        if hookSessions.isEmpty == false {
            shouldShowTrafficLight = false
            trafficLightState = .inactive
            return
        }

        guard !hadHookFilesThisCycle, isCursorRunning() else {
            shouldShowTrafficLight = false
            trafficLightState = .inactive
            sessions = []
            return
        }

        let transcriptSessions = buildTranscriptSessions(
            staleMinutes: staleMinutes,
            collapseMinutes: collapseMinutes,
            inactiveMinutes: inactiveMinutes
        )
        sessions = transcriptSessions.sorted { $0.updatedAt > $1.updatedAt }
        let visibleTranscript = transcriptSessions.filter(\.isVisible)
        if visibleTranscript.isEmpty {
            shouldShowTrafficLight = false
            trafficLightState = .inactive
        } else {
            applyDisplay(from: visibleTranscript)
        }
    }

    private func applyDisplay(from visible: [AgentSessionStatus]) {
        var state = AgentTrafficLightMapper.aggregate(visible)
        if state == .inactive && Defaults[.showAgentStoppedIndicator] == false {
            // inactive dim state is visible
        } else if state == .inactive && Defaults[.showAgentStoppedIndicator] {
            state = .stopped
        }
        trafficLightState = state
        shouldShowTrafficLight = true
    }

    private func hadRecentHookFiles(staleMinutes: Int) -> Bool {
        let directory = AgentHookInstaller.statusDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return false }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let staleMs = Int64(staleMinutes) * 60_000
        return files.contains { file in
            guard file.pathExtension == "json" else { return false }
            if let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                let tsMs = Int64(mtime.timeIntervalSince1970 * 1000)
                return nowMs - tsMs <= staleMs
            }
            return true
        }
    }

    private func parseHookSessions(
        staleMinutes: Int,
        collapseMinutes: Int,
        inactiveMinutes: Int,
        now: Date = Date()
    ) -> [AgentSessionStatus] {
        let directory = AgentHookInstaller.statusDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let staleMs = Int64(staleMinutes) * 60_000
        let collapseMs = Int64(collapseMinutes) * 60_000
        let inactiveMs = Int64(inactiveMinutes) * 60_000

        var results: [AgentSessionStatus] = []

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

            let provider = (json["provider"] as? String) ?? "unknown"
            let conversationID = file.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "\(provider)-", with: "")
            let chatName = normalizedChatName(
                json["name"] as? String ?? json["title"] as? String ?? json["conversation_title"] as? String
            )
            let ageMs = nowMs - tsMs
            let resolved = AgentTrafficLightMapper.resolveHookState(
                rawState: state,
                ageMs: ageMs,
                collapseMs: collapseMs,
                inactiveMs: inactiveMs
            )

            results.append(
                AgentSessionStatus(
                    id: file.deletingPathExtension().lastPathComponent,
                    provider: provider,
                    conversationID: conversationID,
                    chatName: chatName,
                    rawState: state,
                    displayState: resolved.state,
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000),
                    isVisible: resolved.visible
                )
            )
        }

        return enrichChatNames(fromComposerStore: results)
    }

    private func buildTranscriptSessions(
        staleMinutes: Int,
        collapseMinutes: Int,
        inactiveMinutes: Int
    ) -> [AgentSessionStatus] {
        let paths = CursorTranscriptParser.listRecentTranscriptPaths(maxAgeMinutes: staleMinutes)
        guard !paths.isEmpty else { return [] }

        var ids = Set<String>()
        var snapshots: [AgentSessionSnapshot] = []

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

        return snapshots.map { snapshot in
            let mapped = AgentTrafficLightMapper.map(
                session: snapshot,
                staleMinutes: staleMinutes,
                stoppedCollapseMinutes: collapseMinutes,
                inactiveDisplayMinutes: inactiveMinutes
            )
            return AgentSessionStatus(
                id: "cursor-\(snapshot.sessionID)",
                provider: "cursor",
                conversationID: snapshot.sessionID,
                chatName: normalizedChatName(composerMeta[snapshot.sessionID]?.name),
                rawState: snapshot.composerStatus ?? "transcript",
                displayState: mapped.state,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(snapshot.lastActivityMs) / 1000),
                isVisible: mapped.visible
            )
        }
    }

    private func normalizedChatName(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func enrichChatNames(fromComposerStore sessions: [AgentSessionStatus]) -> [AgentSessionStatus] {
        let unresolvedCursorIDs = Set(
            sessions
                .filter { $0.provider.lowercased() == "cursor" && normalizedChatName($0.chatName) == nil }
                .map(\.conversationID)
        )
        guard !unresolvedCursorIDs.isEmpty else { return sessions }

        let composerMeta = CursorComposerStore.loadComposerMeta(forIDs: unresolvedCursorIDs)
        return sessions.map { session in
            guard session.provider.lowercased() == "cursor",
                  normalizedChatName(session.chatName) == nil,
                  let name = normalizedChatName(composerMeta[session.conversationID]?.name) else {
                return session
            }
            return AgentSessionStatus(
                id: session.id,
                provider: session.provider,
                conversationID: session.conversationID,
                chatName: name,
                rawState: session.rawState,
                displayState: session.displayState,
                updatedAt: session.updatedAt,
                isVisible: session.isVisible
            )
        }
    }

    private func isCursorRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return bundleID.hasPrefix("com.todesktop.") || bundleID == "com.cursor.Cursor"
        }
    }
}
