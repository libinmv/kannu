import AppKit
import Combine
import CoreServices
import Darwin
import Defaults
import Foundation

@MainActor
final class CursorAgentStatusMonitor: ObservableObject {
    static let shared = CursorAgentStatusMonitor()

    @Published private(set) var trafficLightState: AgentTrafficLightState = .inactive
    @Published private(set) var shouldShowTrafficLight = false
    @Published private(set) var sessions: [AgentSessionStatus] = []

    private var eventStream: FSEventStreamRef?
    private var statusDirectorySource: DispatchSourceFileSystemObject?
    private var statusDirectoryFD: Int32 = -1
    private var rescanTask: Task<Void, Never>?
    private var quickRescanTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var isRunning = false
    private var watchedPaths: [String] = []
    private var hadHookFilesThisCycle = false
    private var executionStartByConversationID: [String: Date] = [:]
    private var cachedTranscriptAnalysisBySession: [String: TranscriptAnalysis] = [:]
    private var cachedTranscriptAnalysisAt: Date?
    private var lastPublishedTrafficLightState: AgentTrafficLightState?
    private var lastPublishedShouldShowTrafficLight: Bool?

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true
        installWatchers()
        scheduleRescan(delay: 0)
        // Slow background poll; hook directory watcher handles near-real-time updates.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
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
        if let statusDirectorySource {
            statusDirectorySource.cancel()
            self.statusDirectorySource = nil
        }
        if statusDirectoryFD >= 0 {
            close(statusDirectoryFD)
            statusDirectoryFD = -1
        }
        quickRescanTask?.cancel()
        quickRescanTask = nil
        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
            self.eventStream = nil
        }
        trafficLightState = .inactive
        shouldShowTrafficLight = false
        sessions = []
        executionStartByConversationID.removeAll()
        cachedTranscriptAnalysisBySession.removeAll()
        cachedTranscriptAnalysisAt = nil
        lastPublishedTrafficLightState = nil
        lastPublishedShouldShowTrafficLight = nil
        CursorTranscriptParser.invalidatePathCache()
        AgentSessionLogParser.invalidatePathCache()
    }

    private func installWatchers() {
        try? FileManager.default.createDirectory(
            at: AgentHookInstaller.statusDirectory,
            withIntermediateDirectories: true
        )
        // Only watch hook status + transcript roots. Avoid Cursor's huge Application Support trees.
        watchedPaths = [
            CursorTranscriptParser.projectsDirectory.path,
            AgentHookInstaller.statusDirectory.path
        ]

        installStatusDirectoryWatcher()

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
                CursorTranscriptParser.invalidatePathCache()
                AgentSessionLogParser.invalidatePathCache()
                monitor.scheduleRescan(delay: 0.35)
            }
        }

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else { return }

        eventStream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    /// Immediate refresh when hook status JSON files change (sub-100ms).
    private func installStatusDirectoryWatcher() {
        let directory = AgentHookInstaller.statusDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        statusDirectoryFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .attrib, .link],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.scheduleQuickRescan()
            }
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.statusDirectoryFD, fd >= 0 {
                close(fd)
                self?.statusDirectoryFD = -1
            }
        }
        source.resume()
        statusDirectorySource = source
    }

    private func scheduleQuickRescan() {
        guard isRunning else { return }
        quickRescanTask?.cancel()
        quickRescanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            await self?.rescan(hooksOnly: true)
        }
    }

    private func scheduleRescan(delay: TimeInterval) {
        guard isRunning else { return }
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.rescan(hooksOnly: false)
        }
    }

    private func rescan(hooksOnly: Bool = false) async {
        guard isRunning else { return }
        let now = Date()
        let previousStateByConversationID = latestDisplayStateByConversationID(from: sessions)

        let staleMinutes = Defaults[.agentStatusStaleMinutes]
        let collapseMinutes = Defaults[.agentStoppedCollapseMinutes]
        let inactiveMinutes = Defaults[.agentInactiveDisplayMinutes]

        var hookSessions = parseHookSessions(
            staleMinutes: staleMinutes,
            collapseMinutes: collapseMinutes,
            inactiveMinutes: inactiveMinutes,
            now: now
        )

        let passiveClaudeSessions = buildClaudeSessions(
            staleMinutes: staleMinutes,
            collapseMinutes: collapseMinutes,
            inactiveMinutes: inactiveMinutes,
            now: now
        )
        if !passiveClaudeSessions.isEmpty {
            let hookConversationIDs = Set(hookSessions.map(\.conversationID))
            for session in passiveClaudeSessions where !hookConversationIDs.contains(session.conversationID) {
                hookSessions.append(session)
            }
        }

        let transcriptAnalysis: [String: TranscriptAnalysis]
        let transcriptSessions: [AgentSessionStatus]
        if hooksOnly, !sessions.isEmpty {
            // Hook events carry the awaiting_input signal directly (preToolUse fires when
            // the approval card is shown), so hook-triggered rescans reuse cached transcript
            // context instead of re-reading transcripts.
            transcriptAnalysis = cachedTranscriptAnalysis(maxAgeMinutes: staleMinutes, now: now, forceRefresh: false)
            let hookConversationIDs = Set(hookSessions.map(\.conversationID))
            let retainedTranscriptSessions = sessions.filter { !hookConversationIDs.contains($0.conversationID) }
            transcriptSessions = retainedTranscriptSessions
        } else if isCursorRunning() {
            transcriptAnalysis = cachedTranscriptAnalysis(maxAgeMinutes: staleMinutes, now: now, forceRefresh: true)
            transcriptSessions = buildTranscriptSessions(
                analysisBySession: transcriptAnalysis,
                staleMinutes: staleMinutes,
                collapseMinutes: collapseMinutes,
                inactiveMinutes: inactiveMinutes
            )
        } else {
            transcriptAnalysis = [:]
            cachedTranscriptAnalysisBySession = [:]
            cachedTranscriptAnalysisAt = now
            transcriptSessions = []
        }

        let mergedSessions = collapseSubagentSessions(
            applyExecutionRunState(
                to: enrichHookSessionsWithTranscripts(
                    mergeSessions(hookSessions: hookSessions, transcriptSessions: transcriptSessions),
                    analysisBySession: transcriptAnalysis
                ),
                previousStateByConversationID: previousStateByConversationID,
                now: now
            ),
            staleMinutes: staleMinutes
        )
        let resolvedSessions = enrichChatNames(fromComposerStore: mergedSessions)

        let sortedSessions = resolvedSessions.sorted { $0.updatedAt > $1.updatedAt }
        if sessions != sortedSessions {
            sessions = sortedSessions
        }
        hadHookFilesThisCycle = !hookSessions.isEmpty || hadRecentHookFiles(staleMinutes: staleMinutes)

        let visibleSessions = resolvedSessions.filter(\.isVisible)
        if visibleSessions.isEmpty {
            publishTrafficLight(state: .inactive, shouldShow: false)
        } else {
            applyDisplay(from: visibleSessions)
        }
    }

    private func cachedTranscriptAnalysis(
        maxAgeMinutes: Int,
        now: Date,
        forceRefresh: Bool
    ) -> [String: TranscriptAnalysis] {
        if !forceRefresh,
           let cachedTranscriptAnalysisAt,
           now.timeIntervalSince(cachedTranscriptAnalysisAt) < 1.5 {
            return cachedTranscriptAnalysisBySession
        }
        let fresh = CursorTranscriptParser.analyzeRecentSessions(maxAgeMinutes: maxAgeMinutes, now: now)
        cachedTranscriptAnalysisBySession = fresh
        cachedTranscriptAnalysisAt = now
        return fresh
    }

    private func publishTrafficLight(state: AgentTrafficLightState, shouldShow: Bool) {
        if lastPublishedTrafficLightState != state {
            trafficLightState = state
            lastPublishedTrafficLightState = state
        }
        if lastPublishedShouldShowTrafficLight != shouldShow {
            shouldShowTrafficLight = shouldShow
            lastPublishedShouldShowTrafficLight = shouldShow
        }
    }

    private func mergeSessions(
        hookSessions: [AgentSessionStatus],
        transcriptSessions: [AgentSessionStatus]
    ) -> [AgentSessionStatus] {
        var mergedByConversationID: [String: AgentSessionStatus] = [:]

        for session in hookSessions + transcriptSessions {
            guard let existing = mergedByConversationID[session.conversationID] else {
                mergedByConversationID[session.conversationID] = session
                continue
            }
            mergedByConversationID[session.conversationID] = preferredMergedSession(existing, session)
        }

        return Array(mergedByConversationID.values)
    }

    /// Prefer the more urgent traffic-light state; break ties with the newer timestamp.
    private func preferredMergedSession(_ existing: AgentSessionStatus, _ incoming: AgentSessionStatus) -> AgentSessionStatus {
        let winner: AgentSessionStatus
        let loser: AgentSessionStatus
        if shouldPreferFreshHookActiveState(primary: existing, secondary: incoming) {
            winner = existing
            loser = incoming
        } else if shouldPreferFreshHookActiveState(primary: incoming, secondary: existing) {
            winner = incoming
            loser = existing
        } else if existing.displayState != incoming.displayState {
            if existing.displayState > incoming.displayState {
                winner = existing
                loser = incoming
            } else {
                winner = incoming
                loser = existing
            }
        } else if incoming.updatedAt >= existing.updatedAt {
            winner = incoming
            loser = existing
        } else {
            winner = existing
            loser = incoming
        }
        return AgentSessionStatus(
            id: winner.id,
            provider: winner.provider,
            conversationID: winner.conversationID,
            chatName: preferredChatName(primary: winner.chatName, fallback: loser.chatName),
            projectName: normalizedProjectName(winner.projectName) ?? normalizedProjectName(loser.projectName),
            rawState: winner.rawState,
            displayState: winner.displayState,
            updatedAt: winner.updatedAt,
            isVisible: winner.isVisible || loser.isVisible,
            executionStartedAt: winner.executionStartedAt ?? loser.executionStartedAt
        )
    }

    /// Hook state is authoritative while it is fresh: transcript `hasPendingToolApproval`
    /// can linger and incorrectly paint yellow during active thinking/executing.
    private func shouldPreferFreshHookActiveState(
        primary: AgentSessionStatus,
        secondary: AgentSessionStatus
    ) -> Bool {
        guard isHookStateSession(primary) else { return false }
        guard secondary.displayState == .awaitingInput else { return false }
        guard !isHookStateSession(secondary) else { return false }
        guard Date().timeIntervalSince(primary.updatedAt) < 90 else { return false }
        // Prefer hook executing over stale transcript yellow (WebSearch already approved).
        if primary.displayState == .executing { return true }
        // Let transcript yellow beat hook thinking (Shell Run card).
        return false
    }

    private func isHookStateSession(_ session: AgentSessionStatus) -> Bool {
        switch session.rawState.lowercased() {
        case "thinking", "executing", "awaiting_input", "awaitinginput", "awaiting",
             "stopped", "stop", "completed", "aborted", "error":
            return true
        default:
            return false
        }
    }

    /// Roll Task/subagent activity into the parent chat so they don't appear as extra sessions.
    private func collapseSubagentSessions(_ sessions: [AgentSessionStatus], staleMinutes: Int) -> [AgentSessionStatus] {
        let subagentParents = CursorTranscriptParser.subagentToParentSessionMap(maxAgeMinutes: staleMinutes)
        guard !subagentParents.isEmpty else { return sessions }

        var rolledUp: [String: AgentSessionStatus] = [:]

        for session in sessions {
            let parentID = subagentParents[session.conversationID]
            let targetID = parentID ?? session.conversationID

            let candidate: AgentSessionStatus
            if let parentID {
                candidate = AgentSessionStatus(
                    id: "cursor-\(parentID)",
                    provider: session.provider,
                    conversationID: parentID,
                    chatName: session.chatName,
                    projectName: session.projectName,
                    rawState: session.rawState,
                    displayState: session.displayState,
                    updatedAt: session.updatedAt,
                    isVisible: session.isVisible,
                    executionStartedAt: session.executionStartedAt
                )
            } else {
                candidate = session
            }

            if let existing = rolledUp[targetID] {
                let merged = preferredMergedSession(existing, candidate)
                rolledUp[targetID] = AgentSessionStatus(
                    id: existing.id.hasPrefix("cursor-") ? existing.id : candidate.id,
                    provider: merged.provider,
                    conversationID: targetID,
                    chatName: normalizedChatName(existing.chatName) ?? normalizedChatName(candidate.chatName),
                    projectName: normalizedProjectName(existing.projectName) ?? normalizedProjectName(candidate.projectName),
                    rawState: merged.rawState,
                    displayState: merged.displayState,
                    updatedAt: max(existing.updatedAt, candidate.updatedAt),
                    isVisible: existing.isVisible || candidate.isVisible,
                    executionStartedAt: merged.executionStartedAt ?? existing.executionStartedAt ?? candidate.executionStartedAt
                )
            } else {
                rolledUp[targetID] = candidate
            }
        }

        return Array(rolledUp.values)
    }

    private func applyDisplay(from visible: [AgentSessionStatus]) {
        var state = AgentTrafficLightMapper.aggregate(visible)

        if state == .inactive {
            if Defaults[.showAgentStoppedIndicator] {
                state = .stopped
            } else {
                publishTrafficLight(state: .inactive, shouldShow: false)
                return
            }
        }

        publishTrafficLight(state: state, shouldShow: true)
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

    /// Layer transcript-derived context on top of hook states. The hook file is the source
    /// of truth for awaiting_input: measured Cursor timing shows `preToolUse` fires when the
    /// approval card is shown and `postToolUse` after the decision, so the hook alone brackets
    /// the yellow window correctly. Transcript signals must never override hook yellow.
    private func enrichHookSessionsWithTranscripts(
        _ sessions: [AgentSessionStatus],
        analysisBySession: [String: TranscriptAnalysis]
    ) -> [AgentSessionStatus] {
        let now = Date()

        return sessions.map { session in
            guard session.provider.lowercased() == "cursor" else { return session }

            let rawState = session.rawState.lowercased()
            if rawState == "stopped" || rawState == "stop" || session.displayState == .stopped {
                return session
            }

            // Hook yellow wins outright; transcripts lag the live card.
            if rawState == "awaiting_input" || session.displayState == .awaitingInput {
                return session
            }

            let analysis = analysisBySession[session.conversationID]

            if analysis?.isUserPromptAwaitingResponse == true {
                return AgentSessionStatus(
                    id: session.id,
                    provider: session.provider,
                    conversationID: session.conversationID,
                    chatName: session.chatName,
                    projectName: session.projectName,
                    rawState: "thinking",
                    displayState: .thinking,
                    updatedAt: session.updatedAt,
                    isVisible: true,
                    executionStartedAt: session.executionStartedAt
                )
            }

            if analysis?.hasPendingToolApproval == true,
               session.displayState == .thinking || session.displayState == .executing {
                return AgentSessionStatus(
                    id: session.id,
                    provider: session.provider,
                    conversationID: session.conversationID,
                    chatName: session.chatName,
                    projectName: session.projectName,
                    rawState: "awaiting_input",
                    displayState: .awaitingInput,
                    updatedAt: session.updatedAt,
                    isVisible: true,
                    executionStartedAt: session.executionStartedAt
                )
            }

            // Transcript `turn_ended` lags behind live hooks. Never demote a fresh
            // thinking/executing hook file to stopped or green never appears.
            let hookIsLiveActive = ["thinking", "executing", "awaiting_input"].contains(rawState)
                && now.timeIntervalSince(session.updatedAt) < 90
            if analysis?.isTurnEndedAtTail == true,
               (session.displayState == .executing || session.displayState == .thinking),
               !hookIsLiveActive {
                return AgentSessionStatus(
                    id: session.id,
                    provider: session.provider,
                    conversationID: session.conversationID,
                    chatName: session.chatName,
                    projectName: session.projectName,
                    rawState: "stopped",
                    displayState: .stopped,
                    updatedAt: session.updatedAt,
                    isVisible: true,
                    executionStartedAt: session.executionStartedAt
                )
            }

            return session
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

            if AgentTrafficLightMapper.isSimulationConversationID(conversationID) {
                try? FileManager.default.removeItem(at: file)
                continue
            }

            if !hasHookSessionBacking(
                conversationID: conversationID,
                provider: provider,
                staleMinutes: staleMinutes
            ) {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let chatName = preferredHookChatName(from: json)
            let projectName = normalizedProjectName(
                json["project"] as? String ?? json["project_name"] as? String ?? json["workspace_name"] as? String
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
                    projectName: projectName,
                    rawState: state,
                    displayState: resolved.state,
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000),
                    isVisible: resolved.visible,
                    executionStartedAt: nil
                )
            )
        }

        let enriched = enrichChatNames(fromComposerStore: results)
        return enrichProjectNamesFromTranscripts(enriched, maxAgeMinutes: staleMinutes)
    }

    private func buildTranscriptSessions(
        analysisBySession: [String: TranscriptAnalysis],
        staleMinutes: Int,
        collapseMinutes: Int,
        inactiveMinutes: Int
    ) -> [AgentSessionStatus] {
        let paths = CursorTranscriptParser.listRecentTranscriptPaths(maxAgeMinutes: staleMinutes)
        guard !paths.isEmpty else { return [] }

        var ids = Set<String>()
        var projectNamesBySessionID: [String: String] = [:]
        var snapshots: [AgentSessionSnapshot] = []

        for path in paths {
            let sessionID = CursorTranscriptParser.sessionID(from: path)
            ids.insert(sessionID)
            let projectName = CursorTranscriptParser.displayProjectName(
                fromSlug: CursorTranscriptParser.projectSlug(from: path)
            )
            if let projectName {
                projectNamesBySessionID[sessionID] = projectName
            }
            let analysis = analysisBySession[sessionID] ?? CursorTranscriptParser.analyze(path: path)
            snapshots.append(
                AgentSessionSnapshot(
                    sessionID: sessionID,
                    lastActivityMs: analysis.mtimeMs,
                    composerStatus: nil,
                    isDone: analysis.isDone,
                    hasActiveToolUse: analysis.hasActiveToolUse,
                    hasPendingToolApproval: analysis.hasPendingToolApproval,
                    isUserPromptAwaitingResponse: analysis.isUserPromptAwaitingResponse,
                    transcriptMtimeMs: analysis.mtimeMs
                )
            )
        }

        // Prefer lightweight composer headers first, then only scan workspace DBs for unresolved IDs.
        let composerMeta = loadComposerMetaWithWorkspaceFallback(forIDs: ids)
        snapshots = snapshots.map { snapshot in
            guard let meta = composerMeta[snapshot.sessionID] else { return snapshot }
            let lastActivity = max(snapshot.lastActivityMs, meta.updatedMs, meta.checkpointMs)
            return AgentSessionSnapshot(
                sessionID: snapshot.sessionID,
                lastActivityMs: lastActivity,
                composerStatus: meta.status,
                isDone: snapshot.isDone,
                hasActiveToolUse: snapshot.hasActiveToolUse,
                hasPendingToolApproval: snapshot.hasPendingToolApproval,
                isUserPromptAwaitingResponse: snapshot.isUserPromptAwaitingResponse,
                transcriptMtimeMs: max(snapshot.transcriptMtimeMs, meta.checkpointMs)
            )
        }

        let transcriptChatNames = CursorTranscriptParser.displayChatNamesBySessionID(
            maxAgeMinutes: staleMinutes
        )
        let transcriptAssistantSnippets = CursorTranscriptParser.assistantSnippetsBySessionID(
            maxAgeMinutes: staleMinutes
        )
        let glassTitles = CursorGlassAgentStore.loadAgentTitles(forIDs: ids)
        let titleSources = ChatTitleSources(
            composerMeta: composerMeta,
            glassTitles: glassTitles,
            transcriptTitles: transcriptChatNames,
            transcriptAssistantSnippets: transcriptAssistantSnippets,
            planRegistryTitles: CursorComposerStore.loadPlanRegistryNames()
        )

        return snapshots.map { snapshot in
            let mapped = AgentTrafficLightMapper.map(
                session: snapshot,
                staleMinutes: staleMinutes,
                stoppedCollapseMinutes: collapseMinutes,
                inactiveDisplayMinutes: inactiveMinutes
            )
            let chatName = resolveCursorChatName(
                sessionID: snapshot.sessionID,
                hookName: nil,
                sources: titleSources
            )
            return AgentSessionStatus(
                id: "cursor-\(snapshot.sessionID)",
                provider: "cursor",
                conversationID: snapshot.sessionID,
                chatName: chatName,
                projectName: normalizedProjectName(projectNamesBySessionID[snapshot.sessionID]),
                rawState: snapshot.composerStatus ?? "transcript",
                displayState: mapped.state,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(snapshot.lastActivityMs) / 1000),
                isVisible: mapped.visible,
                executionStartedAt: nil
            )
        }
    }

    private struct ChatTitleSources {
        let composerMeta: [String: ComposerMeta]
        let glassTitles: [String: String]
        let transcriptTitles: [String: String]
        let transcriptAssistantSnippets: [String: [String]]
        let planRegistryTitles: Set<String>
    }

    private struct HookProviderTitleSources {
        let logTitles: [String: String]
        let logAssistantSnippets: [String: [String]]
    }

    private func isUnreliableChatTitle(
        _ candidate: String?,
        sessionID: String,
        sources: ChatTitleSources
    ) -> Bool {
        guard let candidate = normalizedChatName(candidate) else { return true }
        if Self.looksLikeToolName(candidate) { return true }
        if sources.planRegistryTitles.contains(candidate) { return true }
        if CursorTranscriptParser.isTranscriptPromptFallback(
            candidate,
            sessionID: sessionID,
            transcriptTitles: sources.transcriptTitles
        ) {
            return true
        }
        if CursorTranscriptParser.isAssistantProseFallback(
            candidate,
            sessionID: sessionID,
            transcriptAssistantSnippets: sources.transcriptAssistantSnippets
        ) {
            return true
        }
        return false
    }

    private func normalizedChatName(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func preferredHookChatName(from json: [String: Any]) -> String? {
        let titleCandidates = [
            json["conversation_title"] as? String,
            json["title"] as? String,
            json["chat_name"] as? String,
            json["conversation_name"] as? String,
            json["chatTitle"] as? String,
            json["bubbleTitle"] as? String
        ]
        for candidate in titleCandidates {
            guard let normalized = normalizedChatName(candidate), !Self.looksLikeToolName(normalized) else { continue }
            return normalized
        }
        guard let storedName = normalizedChatName(json["name"] as? String), !Self.looksLikeToolName(storedName) else {
            return nil
        }
        return storedName
    }

    private func resolveCursorChatName(
        sessionID: String,
        hookName: String?,
        sources: ChatTitleSources
    ) -> String? {
        let candidates = [
            hookName,
            sources.composerMeta[sessionID]?.name,
            sources.glassTitles[sessionID],
            sources.transcriptTitles[sessionID]
        ]

        for candidate in candidates {
            guard let normalized = normalizedChatName(candidate),
                  !isUnreliableChatTitle(normalized, sessionID: sessionID, sources: sources) else {
                continue
            }
            return normalized
        }

        return nil
    }

    private func loadChatTitleSources(forIDs ids: Set<String>, maxAgeMinutes: Int) -> ChatTitleSources {
        ChatTitleSources(
            composerMeta: loadComposerMetaWithWorkspaceFallback(forIDs: ids),
            glassTitles: CursorGlassAgentStore.loadAgentTitles(forIDs: ids),
            transcriptTitles: CursorTranscriptParser.displayChatNamesBySessionID(maxAgeMinutes: maxAgeMinutes),
            transcriptAssistantSnippets: CursorTranscriptParser.assistantSnippetsBySessionID(maxAgeMinutes: maxAgeMinutes),
            planRegistryTitles: CursorComposerStore.loadPlanRegistryNames()
        )
    }

    private func authoritativeHookChatName(
        from storedName: String?,
        sessionID: String,
        sources: ChatTitleSources
    ) -> String? {
        guard let storedName = normalizedChatName(storedName),
              !isUnreliableChatTitle(storedName, sessionID: sessionID, sources: sources) else {
            return nil
        }
        return storedName
    }

    private func shouldReplaceChatName(
        current: String?,
        resolved: String?,
        sessionID: String,
        sources: ChatTitleSources
    ) -> Bool {
        guard let resolved else { return false }
        guard let current = normalizedChatName(current) else { return true }
        if isUnreliableChatTitle(current, sessionID: sessionID, sources: sources) {
            return resolved != current
        }
        return false
    }

    private func preferredChatName(primary: String?, fallback: String?) -> String? {
        if let primary = normalizedChatName(primary), !Self.looksLikeToolName(primary) {
            return primary
        }
        if let fallback = normalizedChatName(fallback), !Self.looksLikeToolName(fallback) {
            return fallback
        }
        return normalizedChatName(primary) ?? normalizedChatName(fallback)
    }

    private func normalizedProjectName(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func enrichChatNames(fromComposerStore sessions: [AgentSessionStatus]) -> [AgentSessionStatus] {
        let staleMinutes = Defaults[.agentStatusStaleMinutes]
        let cursorIDs = Set(
            sessions
                .filter { $0.provider.lowercased() == "cursor" }
                .map(\.conversationID)
        )
        let cursorSources = cursorIDs.isEmpty
            ? nil
            : loadChatTitleSources(forIDs: cursorIDs, maxAgeMinutes: staleMinutes)

        var hookProviderSources: [AgentSessionLogProvider: HookProviderTitleSources] = [:]
        for logProvider in AgentSessionLogProvider.allCases {
            let ids = Set(
                sessions
                    .filter { AgentSessionLogProvider.from(hookProvider: $0.provider) == logProvider }
                    .map(\.conversationID)
            )
            guard !ids.isEmpty else { continue }
            hookProviderSources[logProvider] = HookProviderTitleSources(
                logTitles: AgentSessionLogParser.displayChatNamesBySessionID(
                    provider: logProvider,
                    maxAgeMinutes: staleMinutes
                ),
                logAssistantSnippets: AgentSessionLogParser.assistantSnippetsBySessionID(
                    provider: logProvider,
                    maxAgeMinutes: staleMinutes
                )
            )
        }

        return sessions.map { session in
            let providerKey = session.provider.lowercased()

            if providerKey == "cursor", let cursorSources {
                let hookName = authoritativeHookChatName(
                    from: session.chatName,
                    sessionID: session.conversationID,
                    sources: cursorSources
                )
                let resolved = resolveCursorChatName(
                    sessionID: session.conversationID,
                    hookName: hookName,
                    sources: cursorSources
                )
                guard shouldReplaceChatName(
                    current: session.chatName,
                    resolved: resolved,
                    sessionID: session.conversationID,
                    sources: cursorSources
                ), let resolved else {
                    return session
                }
                return session.replacingChatName(resolved)
            }

            if let logProvider = AgentSessionLogProvider.from(hookProvider: providerKey),
               let sources = hookProviderSources[logProvider] {
                let hookName = authoritativeHookProviderChatName(
                    from: session.chatName,
                    sessionID: session.conversationID,
                    sources: sources
                )
                let resolved = resolveHookProviderChatName(
                    sessionID: session.conversationID,
                    hookName: hookName,
                    sources: sources
                )
                guard shouldReplaceHookProviderChatName(
                    current: session.chatName,
                    resolved: resolved,
                    sessionID: session.conversationID,
                    sources: sources
                ), let resolved else {
                    return session
                }
                return session.replacingChatName(resolved)
            }

            if providerKey == "vscode" {
                let hookName = normalizedChatName(session.chatName)
                guard let hookName,
                      !Self.looksLikeToolName(hookName),
                      hookName != session.chatName else {
                    return session
                }
                return session.replacingChatName(hookName)
            }

            return session
        }
    }

    private func resolveHookProviderChatName(
        sessionID: String,
        hookName: String?,
        sources: HookProviderTitleSources
    ) -> String? {
        let candidates = [hookName, sources.logTitles[sessionID]]
        for candidate in candidates {
            guard let normalized = normalizedChatName(candidate),
                  !isUnreliableHookProviderChatTitle(normalized, sessionID: sessionID, sources: sources) else {
                continue
            }
            return normalized
        }
        return nil
    }

    private func authoritativeHookProviderChatName(
        from storedName: String?,
        sessionID: String,
        sources: HookProviderTitleSources
    ) -> String? {
        guard let storedName = normalizedChatName(storedName),
              !isUnreliableHookProviderChatTitle(storedName, sessionID: sessionID, sources: sources) else {
            return nil
        }
        return storedName
    }

    private func shouldReplaceHookProviderChatName(
        current: String?,
        resolved: String?,
        sessionID: String,
        sources: HookProviderTitleSources
    ) -> Bool {
        guard let resolved else { return false }
        guard let current = normalizedChatName(current) else { return true }
        if isUnreliableHookProviderChatTitle(current, sessionID: sessionID, sources: sources) {
            return resolved != current
        }
        return false
    }

    private func isUnreliableHookProviderChatTitle(
        _ candidate: String?,
        sessionID: String,
        sources: HookProviderTitleSources
    ) -> Bool {
        guard let candidate = normalizedChatName(candidate) else { return true }
        if Self.looksLikeToolName(candidate) { return true }
        if AgentSessionLogParser.isPromptFallback(
            candidate,
            sessionID: sessionID,
            logTitles: sources.logTitles
        ) {
            return true
        }
        if AgentSessionLogParser.isAssistantProseFallback(
            candidate,
            sessionID: sessionID,
            assistantSnippets: sources.logAssistantSnippets
        ) {
            return true
        }
        return false
    }

    private func hasHookSessionBacking(
        conversationID: String,
        provider: String,
        staleMinutes: Int
    ) -> Bool {
        switch provider.lowercased() {
        case "cursor":
            let transcriptPaths = CursorTranscriptParser.listRecentTranscriptPaths(maxAgeMinutes: staleMinutes)
            if transcriptPaths.contains(where: { CursorTranscriptParser.sessionID(from: $0) == conversationID }) {
                return true
            }
            let meta = CursorComposerStore.loadComposerMeta(forIDs: [conversationID])
            return meta[conversationID] != nil
        case "codex":
            return AgentSessionLogParser.hasSessionBacking(
                provider: .codex,
                conversationID: conversationID,
                maxAgeMinutes: staleMinutes
            )
        case "claude":
            return AgentSessionLogParser.hasSessionBacking(
                provider: .claude,
                conversationID: conversationID,
                maxAgeMinutes: staleMinutes
            )
        case "vscode":
            return true
        default:
            return true
        }
    }

    private func loadComposerMetaWithWorkspaceFallback(forIDs ids: Set<String>) -> [String: ComposerMeta] {
        guard !ids.isEmpty else { return [:] }

        var composerMeta = CursorComposerStore.loadComposerMeta(
            forIDs: ids,
            includeWorkspaceDatabases: false
        )
        let unresolved = ids.filter { composerMeta[$0] == nil }
        guard !unresolved.isEmpty else { return composerMeta }

        let workspaceMeta = CursorComposerStore.loadComposerMeta(
            forIDs: Set(unresolved),
            includeWorkspaceDatabases: true
        )
        for (id, meta) in workspaceMeta {
            composerMeta[id] = meta
        }
        return composerMeta
    }

    nonisolated static func looksLikeToolName(_ value: String?) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return false }

        if AgentApprovalGatedTools.requiresUserApproval(trimmed) {
            return true
        }

        let lower = trimmed.lowercased()
        let compact = lower
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        let commonTools: Set<String> = [
            "shell", "read", "grep", "rg", "edit", "write", "task",
            "applypatch", "strreplace", "glob", "openresource",
            "todowrite", "createsubagent", "subagent"
        ]
        return commonTools.contains(compact)
    }

    private func enrichProjectNamesFromTranscripts(
        _ sessions: [AgentSessionStatus],
        maxAgeMinutes: Int
    ) -> [AgentSessionStatus] {
        let cursorProjectBySessionID = projectNamesFromTranscriptPaths(maxAgeMinutes: maxAgeMinutes)
        var logProjectBySessionID: [String: [String: String]] = [:]
        for logProvider in AgentSessionLogProvider.allCases {
            logProjectBySessionID[logProvider.rawValue] = AgentSessionLogParser.projectNamesBySessionID(
                provider: logProvider,
                maxAgeMinutes: maxAgeMinutes
            )
        }

        return sessions.map { session in
            guard normalizedProjectName(session.projectName) == nil else { return session }

            let providerKey = session.provider.lowercased()
            let projectName: String?
            if providerKey == "cursor" {
                projectName = cursorProjectBySessionID[session.conversationID]
            } else if let logProvider = AgentSessionLogProvider.from(hookProvider: providerKey) {
                projectName = logProjectBySessionID[logProvider.rawValue]?[session.conversationID]
            } else {
                projectName = nil
            }

            guard let projectName else { return session }
            return AgentSessionStatus(
                id: session.id,
                provider: session.provider,
                conversationID: session.conversationID,
                chatName: session.chatName,
                projectName: projectName,
                rawState: session.rawState,
                displayState: session.displayState,
                updatedAt: session.updatedAt,
                isVisible: session.isVisible,
                executionStartedAt: session.executionStartedAt
            )
        }
    }

    private func latestDisplayStateByConversationID(
        from sessions: [AgentSessionStatus]
    ) -> [String: AgentTrafficLightState] {
        var result: [String: AgentTrafficLightState] = [:]
        let sorted = sessions.sorted { $0.updatedAt > $1.updatedAt }
        for session in sorted {
            if result[session.conversationID] == nil {
                result[session.conversationID] = session.displayState
            }
        }
        return result
    }

    private func applyExecutionRunState(
        to sessions: [AgentSessionStatus],
        previousStateByConversationID: [String: AgentTrafficLightState],
        now: Date
    ) -> [AgentSessionStatus] {
        let activeConversationIDs = Set(sessions.map(\.conversationID))
        executionStartByConversationID = executionStartByConversationID.filter {
            activeConversationIDs.contains($0.key)
        }

        return sessions.map { session in
            let start: Date?
            if session.displayState.isActiveRun {
                let previousState = previousStateByConversationID[session.conversationID]
                if previousState?.isActiveRun == true {
                    let existing = executionStartByConversationID[session.conversationID]
                    let fallback = session.updatedAt
                    let resolvedStart = existing ?? fallback
                    executionStartByConversationID[session.conversationID] = resolvedStart
                    start = resolvedStart
                } else {
                    executionStartByConversationID[session.conversationID] = now
                    start = now
                }
            } else {
                executionStartByConversationID.removeValue(forKey: session.conversationID)
                start = nil
            }

            let executionStartForSession = session.displayState.isActiveRun ? start : nil

            return AgentSessionStatus(
                id: session.id,
                provider: session.provider,
                conversationID: session.conversationID,
                chatName: session.chatName,
                projectName: session.projectName,
                rawState: session.rawState,
                displayState: session.displayState,
                updatedAt: session.updatedAt,
                isVisible: session.isVisible,
                executionStartedAt: executionStartForSession
            )
        }
    }

    private func projectNamesFromTranscriptPaths(maxAgeMinutes: Int) -> [String: String] {
        var projectBySessionID: [String: String] = [:]
        let paths = CursorTranscriptParser.listRecentTranscriptPaths(maxAgeMinutes: maxAgeMinutes)
        for path in paths {
            let sessionID = CursorTranscriptParser.sessionID(from: path)
            guard let projectName = CursorTranscriptParser.displayProjectName(
                fromSlug: CursorTranscriptParser.projectSlug(from: path)
            ) else { continue }
            projectBySessionID[sessionID] = projectName
        }
        return projectBySessionID
    }

    // MARK: - Passive Claude session detection

    private func buildClaudeSessions(
        staleMinutes: Int,
        collapseMinutes: Int,
        inactiveMinutes: Int,
        now: Date = Date()
    ) -> [AgentSessionStatus] {
        let sessionsDir = AgentSessionLogParser.claudeSessionsDirectory
        guard FileManager.default.fileExists(atPath: sessionsDir.path),
              let files = try? FileManager.default.contentsOfDirectory(
                at: sessionsDir,
                includingPropertiesForKeys: [.contentModificationDateKey]
              ) else { return [] }

        let staleMs = Int64(staleMinutes) * 60_000
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let collapseMs = Int64(collapseMinutes) * 60_000
        let inactiveMs = Int64(inactiveMinutes) * 60_000
        let recentJsonlThreshold: TimeInterval = 5 * 60  // 5 min → "thinking"

        var results: [AgentSessionStatus] = []

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int,
                  let sessionId = json["sessionId"] as? String,
                  let startedAtNum = json["startedAt"] as? NSNumber else { continue }
            let startedAtMs = startedAtNum.int64Value

            guard json["kind"] as? String == "interactive" else { continue }

            let processAlive = isClaudeProcessAlive(pid: pid, startedAtMs: startedAtMs)
            // Skip stale check for live processes — a session may run for many hours.
            if !processAlive {
                guard nowMs - startedAtMs <= staleMs else { continue }
            }

            let jsonlURL = claudeJSONLURL(forSessionId: sessionId)
            var jsonlMtime: Date? = nil
            if let url = jsonlURL {
                jsonlMtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }

            let rawState: String
            if processAlive {
                if let mtime = jsonlMtime, now.timeIntervalSince(mtime) < recentJsonlThreshold {
                    rawState = "thinking"
                } else {
                    rawState = "stopped"
                }
            } else {
                rawState = "stopped"
            }

            let tsMs: Int64
            if let mtime = jsonlMtime {
                tsMs = Int64(mtime.timeIntervalSince1970 * 1000)
            } else {
                tsMs = startedAtMs
            }

            let ageMs = nowMs - tsMs
            var resolved = AgentTrafficLightMapper.resolveHookState(
                rawState: rawState,
                ageMs: ageMs,
                collapseMs: collapseMs,
                inactiveMs: inactiveMs
            )
            // Live processes are always visible — JSONL mtime only reflects last write, not whether
            // the session is open. A Claude Code session waiting for the user shows no recent writes.
            if processAlive {
                resolved = (state: resolved.state, visible: true)
            }

            let chatName: String? = jsonlURL.flatMap {
                AgentSessionLogParser.displayChatName(from: $0, provider: .claude)
            }

            let projectName: String?
            if let cwd = json["cwd"] as? String {
                let base = URL(fileURLWithPath: cwd).lastPathComponent
                projectName = base.isEmpty ? nil : base
            } else {
                projectName = nil
            }

            results.append(AgentSessionStatus(
                id: "claude-\(sessionId)",
                provider: "claude",
                conversationID: sessionId,
                chatName: chatName,
                projectName: projectName,
                rawState: rawState,
                displayState: resolved.state,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000),
                isVisible: resolved.visible,
                executionStartedAt: nil
            ))
        }

        return results
    }

    private func claudeJSONLURL(forSessionId sessionId: String) -> URL? {
        let projectsDir = AgentSessionLogParser.claudeProjectsDirectory
        guard let enumerator = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let target = "\(sessionId).jsonl"
        for case let url as URL in enumerator {
            guard url.lastPathComponent == target,
                  !url.path.contains("/subagents/") else { continue }
            return url
        }
        return nil
    }

    private func isCursorRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return bundleID.hasPrefix("com.todesktop.") || bundleID == "com.cursor.Cursor"
        }
    }

    // Returns true only if the process is alive AND its start time matches startedAtMs
    // within 5 seconds, preventing PID-reuse false positives.
    private func isClaudeProcessAlive(pid: Int, startedAtMs: Int64) -> Bool {
        guard kill(pid_t(pid), 0) == 0 else { return false }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return true }
        let procStartMs = Int64(info.kp_proc.p_starttime.tv_sec) * 1000
            + Int64(info.kp_proc.p_starttime.tv_usec) / 1000
        return abs(procStartMs - startedAtMs) < 5_000
    }
}

private extension AgentSessionStatus {
    func replacingChatName(_ chatName: String) -> AgentSessionStatus {
        AgentSessionStatus(
            id: id,
            provider: provider,
            conversationID: conversationID,
            chatName: chatName,
            projectName: projectName,
            rawState: rawState,
            displayState: displayState,
            updatedAt: updatedAt,
            isVisible: isVisible,
            executionStartedAt: executionStartedAt
        )
    }
}
