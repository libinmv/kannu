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
    /// Latest server-reported Claude rate-limit usage, and the only cache of it: the statusline
    /// hook's `claude-usage.json`, falling back to the desktop app's own history. Refreshed on the
    /// cadence in `refreshClaudeUsage(now:)`, never on demand. Nil until first observation.
    @Published private(set) var claudeUsage: ClaudeUsageSnapshot?

    /// Bumped whenever an agent actually does something — a traffic light transition or any
    /// change to the session list. Views use it to drive time-boxed reveals; unlike
    /// `trafficLightState` it also fires on same-state activity (executing → executing), so a
    /// window keyed off it stays open for the whole of a long run rather than expiring mid-way.
    @Published private(set) var activityPulse: Int = 0
    /// Whether the most recent `activityPulse` bump was the running-agent heartbeat rather
    /// than a real transition. Read synchronously by the pulse observer (same main-actor
    /// turn as the publish) to keep heartbeats from refreshing time-boxed reveal windows.
    private(set) var lastPulseWasHeartbeat = false

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
    private var claudeJSONLURLBySessionId: [String: URL] = [:]
    private var cachedTranscriptAnalysisBySession: [String: TranscriptAnalysis] = [:]
    private var cachedTranscriptAnalysisAt: Date?
    private var lastActivityPulseAt: Date?
    private var lastClaudeUsageReadAt: Date?
    /// True while a user-triggered CLI usage fetch is in flight; gates the button and its spinner.
    @Published private(set) var isRefreshingClaudeUsage = false
    private var lastPublishedTrafficLightState: AgentTrafficLightState?
    private var lastPublishedShouldShowTrafficLight: Bool?

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true
        installWatchers()
        scheduleRescan(delay: 0)
        // Slow safety net only: hook files and Claude transcript/session dirs are all under
        // FSEvents or the kqueue watcher, so changes rescan event-driven. This interval is the
        // ceiling for changes with no filesystem trace (chiefly: an agent process dying without
        // writing anything) — the dead-PID reconciler runs on every rescan, whatever triggers it.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
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
            // The cancel handler (fd captured by value) closes the descriptor.
            statusDirectorySource.cancel()
            self.statusDirectorySource = nil
        }
        statusDirectoryFD = -1
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
        activityPulse = 0
        lastActivityPulseAt = nil
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
        // The Claude dirs make passive session detection event-driven: transcripts and session
        // PID files change on every turn, so the FSEvents callback (which already invalidates
        // both path caches) covers what the old 1-second poll existed for.
        watchedPaths = [
            CursorTranscriptParser.projectsDirectory.path,
            AgentHookInstaller.statusDirectory.path,
            AgentSessionLogParser.claudeProjectsDirectory.path,
            AgentSessionLogParser.claudeSessionsDirectory.path
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
        // fd captured by value — see SystemTimerBridge.startFileMonitor for why closing
        // via self from an enqueued cancel handler closes the wrong descriptor.
        source.setCancelHandler {
            close(fd)
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
        let collapseSeconds = Defaults[.agentStoppedCollapseSeconds]
        let inactiveSeconds = Defaults[.agentInactiveDisplaySeconds]

        var hookSessions = parseHookSessions(
            staleMinutes: staleMinutes,
            collapseSeconds: collapseSeconds,
            inactiveSeconds: inactiveSeconds,
            now: now
        )

        let (passiveClaudeSessions, deadPIDConversationIDs) = buildClaudeSessions(
            staleMinutes: staleMinutes,
            collapseSeconds: collapseSeconds,
            inactiveSeconds: inactiveSeconds,
            now: now
        )
        // Extracted to AgentTrafficLightMapper.reconcileClaudeSessions (pure, tested):
        // this merge has regressed repeatedly while it lived inline here, unreachable by
        // the logic test target — docs/REGRESSIONS.md entries 5 and 7.
        hookSessions = AgentTrafficLightMapper.reconcileClaudeSessions(
            hookSessions: hookSessions,
            passiveSessions: passiveClaudeSessions,
            deadPIDConversationIDs: deadPIDConversationIDs,
            collapseMs: Int64(collapseSeconds) * 1_000,
            inactiveMs: Int64(inactiveSeconds) * 1_000,
            nowMs: Int64(now.timeIntervalSince1970 * 1000)
        )

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
            transcriptAnalysis = cachedTranscriptAnalysis(maxAgeMinutes: staleMinutes, now: now, forceRefresh: false)
            transcriptSessions = buildTranscriptSessions(
                analysisBySession: transcriptAnalysis,
                staleMinutes: staleMinutes,
                collapseSeconds: collapseSeconds,
                inactiveSeconds: inactiveSeconds
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
            lastPulseWasHeartbeat = false
            activityPulse &+= 1
        }
        hadHookFilesThisCycle = !hookSessions.isEmpty || hadRecentHookFiles(staleMinutes: staleMinutes)

        let visibleSessions = resolvedSessions.filter(\.isVisible)
        if visibleSessions.isEmpty {
            publishTrafficLight(state: .inactive, shouldShow: false)
        } else {
            applyDisplay(from: visibleSessions)
        }

        refreshClaudeUsage(now: now)
        emitActivityHeartbeatIfRunning(now: now)
    }

    /// Refreshes the cached Claude usage, at most once per `claudeUsageRefreshInterval`.
    ///
    /// The statusline hook is authoritative because it reports reset times. The desktop app's own
    /// history is the fallback for the case the hook cannot cover — a user who runs Claude only in
    /// the desktop app, where the statusline command never fires.
    private func refreshClaudeUsage(now: Date) {
        guard ClaudeUsageSnapshot.shouldRefresh(
            now: now,
            lastRead: lastClaudeUsageReadAt,
            state: trafficLightState,
            hasSnapshot: claudeUsage != nil
        ) else { return }
        lastClaudeUsageReadAt = now

        // Three sources, best first. The statusline hook is freshest but only writes while a
        // session drives it; Claude's own cached usage carries real reset times and the per-model
        // weekly windows nothing else has; the desktop history is percentages with inferred resets.
        let url = AgentHookInstaller.statusDirectory
            .appendingPathComponent(AgentHookInstaller.usageFileName)
        var snapshot = ClaudeUsageSnapshot.load(from: url)
        if snapshot == nil || snapshot?.isEmpty(now: now) == true {
            snapshot = ClaudeCachedUsage.load() ?? snapshot
        }
        if snapshot == nil || snapshot?.isEmpty(now: now) == true {
            snapshot = ClaudeDesktopUsageHistory.load(now: now) ?? snapshot
        }
        if snapshot != claudeUsage {
            claudeUsage = snapshot
        }
    }

    /// Re-reads the usage sources immediately, bypassing the cadence gate. For the manual button,
    /// which wants the freshest on-disk value the instant a fetch completes.
    private func reloadClaudeUsageNow() {
        let now = Date()
        lastClaudeUsageReadAt = now
        let url = AgentHookInstaller.statusDirectory
            .appendingPathComponent(AgentHookInstaller.usageFileName)
        var snapshot = ClaudeUsageSnapshot.load(from: url)
        if snapshot == nil || snapshot?.isEmpty(now: now) == true {
            snapshot = ClaudeCachedUsage.load() ?? snapshot
        }
        if snapshot == nil || snapshot?.isEmpty(now: now) == true {
            snapshot = ClaudeDesktopUsageHistory.load(now: now) ?? snapshot
        }
        if snapshot != claudeUsage { claudeUsage = snapshot }
    }

    /// Triggers Claude Code's own usage fetch, which writes `cachedUsageUtilization` to
    /// `~/.claude.json` — the only local source for the per-model (e.g. Fable) weekly window.
    ///
    /// Runs the installed CLI under a pseudo-terminal issuing `/usage`, because that slash command
    /// only runs in an interactive session (headless `-p` treats it as prompt text). The spawn uses
    /// the credential Claude already stored in the keychain: silent after a one-time "Always Allow",
    /// and it reads only limit metadata — no message, no tokens, no cost. Kannu never sees the
    /// credential; it only re-reads the file the CLI writes.
    func refreshClaudeUsageFromCLI() {
        guard !isRefreshingClaudeUsage else { return }
        guard let binary = Self.resolveClaudeBinary() else { return }
        isRefreshingClaudeUsage = true

        Task.detached(priority: .userInitiated) {
            Self.runUsageFetch(binary: binary)
            await MainActor.run {
                self.reloadClaudeUsageNow()
                self.isRefreshingClaudeUsage = false
            }
        }
    }

    /// Newest installed Claude Code binary, or `claude` on PATH, so this survives version bumps.
    private nonisolated static func resolveClaudeBinary() -> URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code")
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil) {
            let candidates = versions
                .map { $0.appendingPathComponent("claude.app/Contents/MacOS/claude") }
                .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
                .sorted { $0.path.compare($1.path, options: .numeric) == .orderedAscending }
            if let newest = candidates.last { return newest }
        }
        let onPath = URL(fileURLWithPath: "/usr/bin/env")
        return FileManager.default.isExecutableFile(atPath: onPath.path) ? onPath : nil
    }

    /// Runs `/usage` under a pty and waits briefly for the fetch to land, then exits. Best-effort:
    /// any failure just means the file is unchanged and the card keeps its current value.
    private nonisolated static func runUsageFetch(binary: URL) {
        // Claude Code writes the refreshed usage into ~/.claude.json, so that file's fetch stamp is
        // the completion signal: poll it and stop the moment it advances, rather than always burning
        // the timeout. A press then costs a few seconds instead of a fixed ceiling.
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        func fetchedAtMs() -> Double? {
            guard let data = try? Data(contentsOf: configURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cache = json["cachedUsageUtilization"] as? [String: Any] else { return nil }
            return (cache["fetchedAtMs"] as? NSNumber)?.doubleValue
        }
        let before = fetchedAtMs()

        let process = Process()
        process.executableURL = binary
        process.arguments = binary.lastPathComponent == "env" ? ["claude"] : []

        // `/usage` is a slash command, so it needs an interactive session: headless `-p` treats it
        // as prompt text. A pty gives the CLI the terminal it expects.
        var master: Int32 = 0, slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { return }
        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle
        // Drain the pty so the CLI never blocks on a full buffer; the output itself is not needed.
        masterHandle.readabilityHandler = { _ = $0.availableData }

        do { try process.run() } catch { return }

        // Let the session come up before issuing the command.
        Thread.sleep(forTimeInterval: 2.5)
        masterHandle.write(Data("/usage\r".utf8))

        // Stop as soon as the fetch lands; the ceiling is only a backstop for a wedged CLI.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            if let now = fetchedAtMs(), now != before { break }
            if !process.isRunning { break }
        }

        if process.isRunning {
            process.terminate()
            // terminate() only signals. Reaping here is also what makes any later status read safe:
            // `terminationStatus` raises an uncatchable ObjC exception on a live process.
            process.waitUntilExit()
        }
        masterHandle.readabilityHandler = nil
        try? masterHandle.close()
    }

    /// Keeps a still-running agent visible to time-boxed consumers.
    ///
    /// A long tool changes neither the traffic light state nor the session list, so the
    /// change-driven pulses above fall silent and any window keyed off them expires mid-run.
    /// Re-announcing on a slow cadence while the aggregate state is an active run keeps that
    /// window refreshed, without extending it once work actually stops.
    private func emitActivityHeartbeatIfRunning(now: Date) {
        guard trafficLightState.isActiveRun, shouldShowTrafficLight else {
            lastActivityPulseAt = nil
            return
        }
        if let last = lastActivityPulseAt, now.timeIntervalSince(last) < agentActivityHeartbeatSeconds {
            return
        }
        lastActivityPulseAt = now
        lastPulseWasHeartbeat = true
        activityPulse &+= 1
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
        var changed = false
        if lastPublishedTrafficLightState != state {
            trafficLightState = state
            lastPublishedTrafficLightState = state
            changed = true
        }
        if lastPublishedShouldShowTrafficLight != shouldShow {
            shouldShowTrafficLight = shouldShow
            lastPublishedShouldShowTrafficLight = shouldShow
            changed = true
        }
        if changed {
            lastPulseWasHeartbeat = false
            activityPulse &+= 1
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
            executionStartedAt: winner.executionStartedAt ?? loser.executionStartedAt,
            cwd: winner.cwd ?? loser.cwd,
            hostPID: winner.hostPID ?? loser.hostPID
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
                    executionStartedAt: session.executionStartedAt,
                    cwd: session.cwd,
                    hostPID: session.hostPID
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
                    executionStartedAt: merged.executionStartedAt ?? existing.executionStartedAt ?? candidate.executionStartedAt,
                    cwd: existing.cwd ?? candidate.cwd,
                    hostPID: existing.hostPID ?? candidate.hostPID
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
                    executionStartedAt: session.executionStartedAt,
                    cwd: session.cwd,
                    hostPID: session.hostPID
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
                    executionStartedAt: session.executionStartedAt,
                    cwd: session.cwd,
                    hostPID: session.hostPID
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
                    executionStartedAt: session.executionStartedAt,
                    cwd: session.cwd,
                    hostPID: session.hostPID
                )
            }

            return session
        }
    }

    private func parseHookSessions(
        staleMinutes: Int,
        collapseSeconds: Int,
        inactiveSeconds: Int,
        now: Date = Date()
    ) -> [AgentSessionStatus] {
        let directory = AgentHookInstaller.statusDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let staleMs = Int64(staleMinutes) * 60_000
        let collapseMs = Int64(collapseSeconds) * 1_000
        let inactiveMs = Int64(inactiveSeconds) * 1_000

        var results: [AgentSessionStatus] = []

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = json["state"] as? String else { continue }

            // The agent hook replaces this file atomically (mkstemp + os.replace) and can
            // do so between our read and a delete decision below. Deleting is only safe if
            // the file is still the one we judged — otherwise we destroy a status the
            // agent wrote milliseconds ago and its session vanishes until the next hook
            // event, potentially minutes away.
            let mtimeAtRead = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            func removeIfUnchanged() {
                let mtimeNow = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard mtimeNow == mtimeAtRead else { return }
                try? FileManager.default.removeItem(at: file)
            }

            var tsMs = (json["ts"] as? NSNumber)?.int64Value ?? 0
            if tsMs <= 0,
               let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                tsMs = Int64(mtime.timeIntervalSince1970 * 1000)
            }

            guard nowMs - tsMs <= staleMs else {
                removeIfUnchanged()
                continue
            }

            let provider = (json["provider"] as? String) ?? "unknown"
            let conversationID = file.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "\(provider)-", with: "")

            if AgentTrafficLightMapper.isSimulationConversationID(conversationID) {
                removeIfUnchanged()
                continue
            }

            // Cursor's backing check consults live app state and is cheap to trust. For
            // claude/codex the "backing" is the same transcript listing that feeds chat-name
            // lookup — deleting on a miss welded "no name yet" to "delete the session": a
            // brand-new session (no JSONL yet), a >30-min approval wait (quiet transcript),
            // or the per-scan session cap all destroyed hook files written seconds earlier.
            // Their freshness is already enforced by the staleMs check above.
            let providerKey = provider.lowercased()
            if providerKey == "cursor",
               !hasHookSessionBacking(
                conversationID: conversationID,
                provider: provider,
                staleMinutes: staleMinutes
               ) {
                removeIfUnchanged()
                continue
            }
            let chatName = preferredHookChatName(from: json)
            let projectName = normalizedProjectName(
                json["project"] as? String ?? json["project_name"] as? String ?? json["workspace_name"] as? String
            )
            let hookCwd = (json["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
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
                    executionStartedAt: nil,
                    cwd: hookCwd
                )
            )
        }

        let enriched = enrichChatNames(fromComposerStore: results)
        return enrichProjectNamesFromTranscripts(enriched, maxAgeMinutes: staleMinutes)
    }

    private func buildTranscriptSessions(
        analysisBySession: [String: TranscriptAnalysis],
        staleMinutes: Int,
        collapseSeconds: Int,
        inactiveSeconds: Int
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
                stoppedCollapseSeconds: collapseSeconds,
                inactiveDisplaySeconds: inactiveSeconds
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
        // Hook and composer/glass titles go through full reliability vetting.
        let candidates = [
            hookName,
            sources.composerMeta[sessionID]?.name,
            sources.glassTitles[sessionID]
        ]
        for candidate in candidates {
            guard let normalized = normalizedChatName(candidate),
                  !isUnreliableChatTitle(normalized, sessionID: sessionID, sources: sources) else {
                continue
            }
            return normalized
        }

        // Transcript title is trusted directly (only tool-name heuristic), not compared against itself.
        if let transcriptTitle = normalizedChatName(sources.transcriptTitles[sessionID]), !Self.looksLikeToolName(transcriptTitle) {
            return transcriptTitle
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
        // The log-derived title (e.g. Claude's ai-title) is the trusted source here, not a
        // hook-echoed candidate to sanity-check against itself — isUnreliableHookProviderChatTitle's
        // isPromptFallback compares a candidate against sources.logTitles[sessionID], which is
        // always true when the candidate *is* that value, so it must be excluded from that check.
        if let normalizedHook = normalizedChatName(hookName),
           !isUnreliableHookProviderChatTitle(normalizedHook, sessionID: sessionID, sources: sources) {
            return normalizedHook
        }
        if let logTitle = normalizedChatName(sources.logTitles[sessionID]), !Self.looksLikeToolName(logTitle) {
            return logTitle
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
        AgentApprovalGatedTools.looksLikeToolName(value)
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
                executionStartedAt: session.executionStartedAt,
                cwd: session.cwd,
                hostPID: session.hostPID
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
                executionStartedAt: executionStartForSession,
                cwd: session.cwd,
                hostPID: session.hostPID
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
        collapseSeconds: Int,
        inactiveSeconds: Int,
        now: Date = Date()
    ) -> (sessions: [AgentSessionStatus], deadPIDConversationIDs: Set<String>) {
        let sessionsDir = AgentSessionLogParser.claudeSessionsDirectory
        guard FileManager.default.fileExists(atPath: sessionsDir.path),
              let files = try? FileManager.default.contentsOfDirectory(
                at: sessionsDir,
                includingPropertiesForKeys: [.contentModificationDateKey]
              ) else { return ([], []) }

        let staleMs = Int64(staleMinutes) * 60_000
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let collapseMs = Int64(collapseSeconds) * 1_000
        let inactiveMs = Int64(inactiveSeconds) * 1_000
        let recentJsonlThreshold: TimeInterval = 10  // seconds of silence before we stop assuming "thinking"

        var results: [AgentSessionStatus] = []
        var deadPIDConversationIDs: Set<String> = []
        // Session files are keyed by PID, but the dead set is keyed by conversation id —
        // and `claude --resume` reuses a conversation id under a new PID. Track which ids
        // have a live process so an orphaned file from a crashed earlier run cannot mark
        // the live one dead. See the subtraction before `return`.
        var liveConversationIDs: Set<String> = []

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
            if processAlive {
                liveConversationIDs.insert(sessionId)
            } else {
                // Recorded before the stale skip: a long-lived session that was SIGKILLed
                // has an old startedAt, and the reconciler still needs to know it is dead.
                deadPIDConversationIDs.insert(sessionId)
                guard nowMs - startedAtMs <= staleMs else { continue }
            }

            let jsonlURL = claudeJSONLURL(forSessionId: sessionId)
            var jsonlMtime: Date? = nil
            if let url = jsonlURL {
                jsonlMtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }

            let tsMs: Int64
            if let mtime = jsonlMtime {
                tsMs = Int64(mtime.timeIntervalSince1970 * 1000)
            } else {
                tsMs = startedAtMs
            }

            // Passive detection can see writes and process liveness — it cannot see whether Claude
            // is actually asking the user anything. It must therefore never claim yellow: a quiet
            // live session is shown as a dim idle card, and yellow is left to real hook signals.
            //
            // Live sessions bypass `resolveHookState` deliberately. Its staleness ladder maps a
            // long-running "thinking" to `.stopped`, which the old unconditional `visible: true`
            // override then force-showed — a live session pinned as red.
            let rawState: String
            let resolved: (state: AgentTrafficLightState, visible: Bool)
            var updatedAtMs = tsMs
            if processAlive {
                // The transcript tail, not mtime, decides — a multi-minute tool writes its
                // `tool_use` record up front and then stays silent, while post-turn bookkeeping
                // keeps bumping mtime after the run ended.
                let tail = jsonlURL.map { AgentSessionLogParser.claudeTailState(at: $0) }
                    ?? .unknown
                let passive = AgentTrafficLightMapper.passiveClaudeState(
                    tail: tail,
                    jsonlMtime: jsonlMtime,
                    fallbackTsMs: tsMs,
                    now: now,
                    collapseMs: collapseMs,
                    inactiveMs: inactiveMs,
                    recentJsonlThreshold: recentJsonlThreshold
                )
                rawState = passive.rawState
                resolved = (passive.state, passive.visible)
                updatedAtMs = passive.updatedAtMs
            } else {
                rawState = "stopped"
                resolved = AgentTrafficLightMapper.resolveHookState(
                    rawState: rawState,
                    ageMs: nowMs - tsMs,
                    collapseMs: collapseMs,
                    inactiveMs: inactiveMs
                )
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
                updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAtMs) / 1000),
                isVisible: resolved.visible,
                executionStartedAt: nil,
                // Click-through locators: the parent chain of this pid leads to the hosting
                // terminal/IDE, and cwd identifies the project. Only attach the pid while the
                // process is provably alive — a dead pid must not make the row clickable.
                cwd: json["cwd"] as? String,
                hostPID: processAlive ? pid : nil
            ))
        }

        // A live process for a conversation id always beats a stale orphan file for the same
        // id. Without this, resuming a crashed session left it permanently "dead", and the
        // reconciler's `processDead ||` short-circuit bypasses the timestamp guard — flashing
        // red at the moment the user submits a prompt.
        return (results, deadPIDConversationIDs.subtracting(liveConversationIDs))
    }

    private func claudeJSONLURL(forSessionId sessionId: String) -> URL? {
        // The projects-tree walk is expensive and session→JSONL mapping never changes,
        // so cache hits (validated by fileExists) skip the enumeration entirely.
        if let cached = claudeJSONLURLBySessionId[sessionId],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
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
            claudeJSONLURLBySessionId[sessionId] = url
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

