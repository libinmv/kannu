import Foundation

enum AgentTrafficLightState: Equatable, Comparable {
    case executing
    case awaitingInput
    case thinking
    case stopped
    case inactive

    var notificationKey: String {
        switch self {
        case .thinking: return "thinking"
        case .executing: return "executing"
        case .awaitingInput: return "awaiting_input"
        case .stopped: return "stopped"
        case .inactive: return "inactive"
        }
    }

    var displayName: String {
        switch self {
        case .executing: return "Executing"
        case .awaitingInput: return "Awaiting Input"
        case .thinking: return "Thinking"
        case .stopped: return "Stopped"
        case .inactive: return "Inactive"
        }
    }

    private var sortPriority: Int {
        switch self {
        case .stopped: return 6         // Red: task completed (highest priority to show)
        case .awaitingInput: return 5   // Yellow: waiting for user input
        case .executing: return 4       // Green: executing
        case .thinking: return 3        // Green: thinking
        case .inactive: return 1
        }
    }

    static func < (lhs: AgentTrafficLightState, rhs: AgentTrafficLightState) -> Bool {
        lhs.sortPriority < rhs.sortPriority
    }

    /// Green light: agent is actively working. Mutually exclusive with yellow/red.
    var showsGreenTrafficLight: Bool {
        switch self {
        case .executing, .thinking: return true
        case .awaitingInput, .stopped, .inactive: return false
        }
    }

    /// Yellow light: waiting on the user (approval / question). Exclusive — never with green.
    var showsYellowTrafficLight: Bool {
        self == .awaitingInput
    }

    /// Red light: stopped / finished.
    var showsRedTrafficLight: Bool {
        self == .stopped
    }

    /// Active run states between idle boundaries.
    var isActiveRun: Bool {
        switch self {
        case .thinking, .executing, .awaitingInput: return true
        case .stopped, .inactive: return false
        }
    }
}

struct AgentSessionStatus: Identifiable, Equatable {
    let id: String
    let provider: String
    let conversationID: String
    let chatName: String?
    let projectName: String?
    let rawState: String
    let displayState: AgentTrafficLightState
    let updatedAt: Date
    let isVisible: Bool
    let executionStartedAt: Date?
    /// Full working directory / workspace root, when the session source knows it. Used by
    /// click-through to open the right project window; nil is fine — the row just won't
    /// offer window-level targeting.
    var cwd: String? = nil
    /// PID of the agent process itself (Claude passive sessions). The parent chain of this
    /// PID leads to the hosting terminal or IDE, which is what click-through activates.
    var hostPID: Int? = nil
    /// Claude Desktop's own id for a Code-tab chat (`local_…`), resolved from Desktop's on-disk
    /// index by CLI session id (`ClaudeDesktopSessionIndex`). A locator like `hostPID`:
    /// click-through opens Desktop's session route (`ClaudeDesktopSessionIndex.focusDeepLink`),
    /// which focuses the chat and creates nothing, so it is safe for live and stopped sessions.
    var desktopSessionID: String? = nil
    /// Tool failures the hook has counted since the last user prompt. Diagnostic only since
    /// hook v33: a failure the agent recovered from is not the turn's outcome, so nothing
    /// displays it — `runError` is what the card reports. Additive: see `carryingExtras(from:)`.
    var toolErrorCount: Int = 0
    /// The session runs with permission checks bypassed (`--dangerously-skip-permissions`,
    /// Codex `approval_policy = never`), as reported by the hook. Sticky for the session's life;
    /// additive like the error count. ADR Discovery cannot see this on macOS (its process
    /// listing carries no argv), so it is Kannu's own finding.
    var isUnattended: Bool = false
    /// Why the run ended, when it ended on an error; nil is a clean finish. A per-turn verdict —
    /// replaced by every stopped write, never accumulated — unlike the two additive fields above.
    /// Sources: the hook's `ended_on_error` (StopFailure, an Antigravity Stop with an error), the
    /// Claude transcript's API-error record, Warp `Failed`, Claude Desktop's `result.is_error`.
    var runError: RunError? = nil
    /// What the hook's local checks found in what this session read or wrote (hook v34+: hidden
    /// Unicode). Hook-only and additive: carried by `carryingExtras` as a union (`HookSightings`).
    var sightings = HookSightings()
    /// The terminal the agent runs in, as its hook reported it (v35+): a locator like `hostPID`,
    /// used by click-through when no process id is known. Carried by `carryingExtras` as
    /// `self ?? source`.
    var terminal: TerminalLocator? = nil

    /// True when the hook that produced this session reported work in progress, regardless of
    /// what the staleness ladder later concluded about its age.
    var hasActiveRawState: Bool {
        switch rawState.lowercased() {
        case "executing", "thinking": return true
        default: return false
        }
    }

    func withDisplayState(_ state: AgentTrafficLightState, visible: Bool, updatedAt: Date? = nil) -> AgentSessionStatus {
        AgentSessionStatus(
            id: id,
            provider: provider,
            conversationID: conversationID,
            chatName: chatName,
            projectName: projectName,
            rawState: rawState,
            displayState: state,
            updatedAt: updatedAt ?? self.updatedAt,
            isVisible: visible,
            executionStartedAt: executionStartedAt,
            cwd: cwd,
            hostPID: hostPID
        ).carryingExtras(from: self)
    }

    var providerLabel: String { Self.providerLabel(for: provider) }

    static func providerLabel(for provider: String) -> String {
        switch provider.lowercased() {
        case "cursor": return "Cursor"
        case "vscode": return "VS Code"
        case "codex": return "Codex"
        case "claude": return "Claude"
        case "antigravity": return "Antigravity"
        case "warp": return "Warp"
        case "claudedesktop": return "Claude Desktop"
        default: return provider.capitalized
        }
    }

    var displayChatName: String {
        let trimmed = chatName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return String(localized: "Untitled chat")
    }

    var displayProjectName: String? {
        let trimmed = projectName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct AgentSessionSnapshot: Equatable {
    let sessionID: String
    let lastActivityMs: Int64
    let composerStatus: String?
    let isDone: Bool
    let hasActiveToolUse: Bool
    let hasPendingToolApproval: Bool
    let isUserPromptAwaitingResponse: Bool
    let transcriptMtimeMs: Int64
}

enum AgentTrafficLightMapper {
    /// The caffeinate arbitration, pure so it is testable: smart wins outright when the agent
    /// feature is on; manual is honored only with smart off; and with the agent feature off —
    /// which hides every caffeinate control — nothing may hold the Mac awake, or the user is
    /// stranded with an assertion they cannot see or clear.
    static func shouldKeepAwake(
        smartEnabled: Bool,
        manualEnabled: Bool,
        featureEnabled: Bool,
        hasActiveVisibleSession: Bool
    ) -> Bool {
        guard featureEnabled else { return false }
        if smartEnabled { return hasActiveVisibleSession }
        return manualEnabled
    }

    /// The single IOPM action a caffeinate reconcile pass must perform, as an explicit table.
    /// Pinned row-for-row by CaffeinateDecisionTests and documented in docs/CAFFEINATE.md —
    /// keep all three in sync.
    enum CaffeinateTransition: Equatable {
        /// Assertion state already matches intent — do nothing.
        case none
        /// Not held but should be — one IOPMAssertionCreate.
        case create
        /// Held but should not be — one IOPMAssertionRelease.
        case release
        /// Held, but under the other mode's reason string — release then create, so
        /// `pmset -g assertions` reports the mode actually in force.
        case refresh
    }

    static func caffeinateTransition(
        isHeld: Bool,
        heldModeIsSmart: Bool?,
        shouldHold: Bool,
        smartNow: Bool
    ) -> CaffeinateTransition {
        switch (isHeld, shouldHold) {
        case (false, true): return .create
        case (true, false): return .release
        case (false, false): return .none
        case (true, true):
            return heldModeIsSmart == smartNow ? .none : .refresh
        }
    }

    /// A prompt nobody answers must not hold the Mac awake all night: yellow is caffeinate-worthy
    /// only inside its first 5 minutes — the window the light itself used before the evidence
    /// hold (REGRESSIONS entry 12). Derived from the same constant so the two cannot drift.
    static let awaitingInputCaffeinateSeconds: TimeInterval = TimeInterval(awaitingInputStaleMs) / 1000

    /// Whether any session justifies smart caffeinate holding the Mac awake: visible, not a
    /// simulation, and in an active run — the same definition the traffic light uses, except
    /// that a wait on the user only counts for its first five minutes.
    static func hasCaffeinateWorthySession(_ sessions: [AgentSessionStatus], now: Date = Date()) -> Bool {
        sessions.contains { session in
            guard session.isVisible, !isSimulationSession(session), session.displayState.isActiveRun else { return false }
            if session.displayState == .awaitingInput {
                return now.timeIntervalSince(session.updatedAt) <= awaitingInputCaffeinateSeconds
            }
            return true
        }
    }

    /// When the earliest currently qualifying yellow stops qualifying; nil when none does. The
    /// session list does not republish at that moment, so the caffeinate manager arms a recheck.
    static func caffeinateRecheckDate(_ sessions: [AgentSessionStatus], now: Date = Date()) -> Date? {
        sessions
            .filter { $0.isVisible && !isSimulationSession($0) && $0.displayState == .awaitingInput }
            .map { $0.updatedAt.addingTimeInterval(awaitingInputCaffeinateSeconds) }
            .filter { $0 > now }
            .min()
    }

    /// Merges Claude hook sessions with passive transcript/PID evidence. Pure — lives here
    /// (Foundation-only, compiled into the logic test target) because this exact logic has
    /// regressed repeatedly while it was unreachable by tests: docs/REGRESSIONS.md entries
    /// 5 and 7 both point at this function's former home inside the monitor.
    static func reconcileClaudeSessions(
        hookSessions: [AgentSessionStatus],
        passiveSessions: [AgentSessionStatus],
        deadPIDConversationIDs: Set<String>,
        collapseMs: Int64,
        inactiveMs: Int64,
        nowMs: Int64
    ) -> [AgentSessionStatus] {
        guard !passiveSessions.isEmpty || !deadPIDConversationIDs.isEmpty else { return hookSessions }

        let passiveByConversationID = Dictionary(
            passiveSessions.map { ($0.conversationID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var merged = hookSessions.map { session -> AgentSessionStatus in
            guard session.provider.lowercased() == "claude" else { return session }
            let passive = passiveByConversationID[session.conversationID]
            let processDead = deadPIDConversationIDs.contains(session.conversationID)

            // A hook file shadows the passive session for the same conversation, and the
            // hook payload is thinner: no title, no pid. Everything the passive side knows
            // and the hook side doesn't has to be carried across here, or it is lost for
            // every hook-tracked Claude session — which is the normal case.
            //
            // This has now bitten three times: missing names rendered every session as
            // "Untitled chat" (twice), and missing locators made click-through silently
            // inert because `AgentSessionOpener` needs a live pid to find the hosting
            // terminal. When you add a field to AgentSessionStatus that a passive session
            // can populate, add it here too. See docs/REGRESSIONS.md entry 7.
            //
            // Applied to EVERY exit below, not just the promote path: the state arms
            // return early, and a demoted or unchanged session still needs this data.
            func inheritingPassiveData(_ candidate: AgentSessionStatus) -> AgentSessionStatus {
                guard let passive else { return candidate }
                var repaired = candidate
                if repaired.chatName?.isEmpty != false, let name = passive.chatName {
                    repaired = repaired.replacingChatName(name)
                }
                if repaired.projectName?.isEmpty != false, let project = passive.projectName {
                    repaired = repaired.replacingProjectName(project)
                }
                if repaired.cwd?.isEmpty != false, let cwd = passive.cwd {
                    repaired.cwd = cwd
                }
                // Safe by construction: the passive path only sets hostPID while the
                // process is provably alive, so a dead session inherits nil and stays
                // correctly non-clickable.
                if repaired.hostPID == nil, let hostPID = passive.hostPID {
                    repaired.hostPID = hostPID
                }
                // The additive fields, the run verdict and the Desktop chat locator ride the
                // seam here: the count keeps the larger side, the flag ORs, the verdict is the
                // hook's unless it has none (`RunError.preferred`), and `desktopSessionID` —
                // passive-only, like hostPID — fills in when the hook side has none.
                repaired = repaired.carryingExtras(from: passive)
                return repaired
            }

            // Demote: the hook file still claims active work — Stop never fires on a
            // user interrupt, and SIGKILL/crash skips it entirely — but fresher passive
            // evidence (a newer transcript record, or a dead process) says otherwise.
            if session.displayState.isActiveRun {
                if let passive, !passive.displayState.isActiveRun,
                   processDead || passive.updatedAt >= session.updatedAt {
                    return inheritingPassiveData(
                        session.withDisplayState(passive.displayState, visible: passive.isVisible)
                    )
                }
                if passive == nil, processDead {
                    // Process gone and its session record too old for a passive card:
                    // age the stop from the hook's own timestamp.
                    let ageMs = nowMs - Int64(session.updatedAt.timeIntervalSince1970 * 1000)
                    let lifecycle = AgentTrafficLightMapper.resolveHookState(
                        rawState: "stopped",
                        ageMs: ageMs,
                        collapseMs: collapseMs,
                        inactiveMs: inactiveMs
                    )
                    return inheritingPassiveData(
                        session.withDisplayState(lifecycle.state, visible: lifecycle.visible)
                    )
                }
                return inheritingPassiveData(session)
            }

            // Promote: hooks only fire at tool boundaries. A single long-running tool — a
            // build, a test suite, an extended turn with no tool calls — leaves the status
            // file untouched for minutes, and `resolveHookState` then ages it out of its
            // active state and dims the session while it is hardest at work. Passive
            // detection can still see the truth (process alive, tool in flight), and a live
            // process beats a stale timestamp. Safe against stale tails: passive "thinking"
            // is bounded by the working-staleness ladder and passive "executing" means a
            // verified in-flight tool.
            guard session.hasActiveRawState,
                  let passive,
                  passive.displayState.isActiveRun
            else { return inheritingPassiveData(session) }

            // `!session.displayState.isActiveRun` is structurally implied here by the
            // early return above, so the promotion is unconditional.
            return inheritingPassiveData(
                session.withDisplayState(
                    passive.displayState,
                    visible: true,
                    updatedAt: max(session.updatedAt, passive.updatedAt)
                )
            )
        }

        let hookConversationIDs = Set(merged.map(\.conversationID))
        for session in passiveSessions where !hookConversationIDs.contains(session.conversationID) {
            merged.append(session)
        }
        return merged
    }

    /// Generous on purpose. Hook-only providers (Codex, VS Code) write a status file at tool
    /// boundaries and then nothing for the duration of the call, so a short window marks a
    /// session that is hardest at work as stopped. Cursor has a live composer status and
    /// Claude has passive transcript detection to cut short a genuinely dead session; the
    /// others have only this timer, so it must outlast a long build or test run.
    private static let runningStaleSeconds: TimeInterval = 360
    private static let abortedIdleSeconds: TimeInterval = 90
    /// Keep yellow visible for the full approval-card window (users often pause).
    private static let awaitingInputStaleMs: Int64 = 300_000

    private static func isAwaitingUserInputStatus(_ status: String) -> Bool {
        switch status.lowercased() {
        case "awaiting_input", "awaitinginput", "awaiting-user", "needs_user", "needs-user",
             "requires_approval", "permission_required", "permission_request":
            return true
        default:
            return false
        }
    }

    static func map(
        session: AgentSessionSnapshot?,
        now: Date = Date(),
        staleMinutes: Int,
        stoppedCollapseSeconds: Int,
        inactiveDisplaySeconds: Int
    ) -> (state: AgentTrafficLightState, visible: Bool) {
        guard let session else { return (.inactive, false) }

        let nowSec = now.timeIntervalSince1970
        let maxAgeSec = TimeInterval(staleMinutes * 60)
        let lastActivitySec = TimeInterval(session.lastActivityMs) / 1000

        guard nowSec - lastActivitySec <= maxAgeSec else {
            return (.inactive, false)
        }

        let collapseSec = TimeInterval(stoppedCollapseSeconds)
        let inactiveSec = TimeInterval(inactiveDisplaySeconds)

        func lifecycleAfterStop() -> (AgentTrafficLightState, Bool) {
            let age = nowSec - lastActivitySec
            if age <= collapseSec { return (.stopped, true) }
            if age <= collapseSec + inactiveSec { return (.inactive, true) }
            return (.inactive, false)
        }

        let liveStatus = (session.composerStatus ?? "").lowercased()
        if isAwaitingUserInputStatus(liveStatus) {
            return (.awaitingInput, true)
        }

        let isGenerating = ["generating", "running", "streaming", "thinking"].contains(liveStatus)

        // `hasPendingToolApproval` comes from the transcript, which lags the live card — it stays
        // true for an already-approved tool until a later message lands. A live generating status
        // or an in-flight tool is fresher evidence, so it wins.
        if session.hasPendingToolApproval && !isGenerating && !session.hasActiveToolUse {
            return (.awaitingInput, true)
        }

        let checkpointMs = session.transcriptMtimeMs
        let abortedIdle = liveStatus == "aborted"
            && checkpointMs > 0
            && nowSec - TimeInterval(checkpointMs) / 1000 > abortedIdleSeconds

        if session.isUserPromptAwaitingResponse {
            return (.thinking, true)
        }

        if session.isDone && !isGenerating {
            return lifecycleAfterStop()
        }

        if abortedIdle {
            return lifecycleAfterStop()
        }

        if liveStatus == "thinking" {
            return (.thinking, true)
        }

        if isGenerating || session.hasActiveToolUse {
            if session.hasActiveToolUse || ["generating", "running", "streaming"].contains(liveStatus) {
                return (.executing, true)
            }
            return (.thinking, true)
        }

        if nowSec - lastActivitySec <= runningStaleSeconds {
            if session.hasActiveToolUse {
                return (.executing, true)
            }
            return (.thinking, true)
        }

        return lifecycleAfterStop()
    }

    static func resolveHookState(
        rawState: String,
        ageMs: Int64,
        collapseMs: Int64,
        inactiveMs: Int64,
        activeStaleMs: Int64 = 360_000,
        holdAwaitingInput: Bool = false
    ) -> (state: AgentTrafficLightState, visible: Bool) {
        switch rawState.lowercased() {
        case "executing" where ageMs <= activeStaleMs:
            return (.executing, true)
        case "awaiting_input", "awaitinginput", "awaiting":
            // Held: live evidence says the prompt is still open (`holdsAwaitingInput`), so the
            // clock does not apply. Unheld: the 5-minute window is the fallback for waits nothing
            // can corroborate — REGRESSIONS entry 12.
            if holdAwaitingInput || ageMs <= awaitingInputStaleMs { return (.awaitingInput, true) }
            return (.inactive, false)
        case "thinking" where ageMs <= activeStaleMs:
            return (.thinking, true)
        case "idle":
            // Session opened but nothing running yet — show a dim card, no lit traffic light.
            return (.inactive, true)
        case "session_end", "ended":
            // The session is gone. Current scripts delete the status file outright; this
            // covers files left behind by an older one.
            return (.inactive, false)
        case "stopped", "stop", "completed", "aborted", "error":
            if ageMs <= collapseMs + inactiveMs { return (.stopped, true) }
            return (.inactive, false)
        default:
            break
        }

        if ageMs <= collapseMs {
            return (.stopped, true)
        }
        if ageMs <= collapseMs + inactiveMs {
            return (.inactive, true)
        }
        return (.inactive, false)
    }

    // MARK: - Yellow follows evidence, not the clock (REGRESSIONS entry 12)

    /// The raw states `resolveHookState` reads as "waiting on the user". Keep in step with its
    /// case list.
    static func isAwaitingInputRawState(_ rawState: String) -> Bool {
        switch rawState.lowercased() {
        case "awaiting_input", "awaitinginput", "awaiting": return true
        default: return false
        }
    }

    /// Disk rule: may this awaiting_input hook file outlive the stale cap? Claude only — the one
    /// provider whose liveness Kannu can see. A live process whose transcript tail still shows the
    /// tool_use with no result is a prompt nobody has answered.
    static func awaitingInputOutlivesStaleCap(
        provider: String,
        processAlive: Bool,
        tail: AgentSessionLogParser.ClaudeTailState?
    ) -> Bool {
        provider.lowercased() == "claude" && processAlive && tail == .toolInFlight
    }

    /// Display rule: does this hook's awaiting_input keep its yellow past the 5-minute window?
    /// Yellow still originates from hooks only — evidence here can corroborate one, never claim
    /// one. Hook-only providers hold because nothing can corroborate or refute; a newer event or
    /// the stale cap ends theirs. Claude's `idle_prompt` (tail `.turnFinished`), a dead process
    /// and Cursor's sticky yellow without a pending approval all stay on the clock.
    static func holdsAwaitingInput(
        provider: String,
        processAlive: Bool,
        tail: AgentSessionLogParser.ClaudeTailState?,
        cursorPendingApproval: Bool
    ) -> Bool {
        switch provider.lowercased() {
        case "claude":
            return awaitingInputOutlivesStaleCap(provider: provider, processAlive: processAlive, tail: tail)
        case "cursor":
            return cursorPendingApproval
        case "vscode", "codex", "antigravity":
            return true
        default:
            return false
        }
    }

    /// A passive `.working` verdict stays green only this long past its last evidence.
    /// During real work, interim records (tool results, `stop_reason:"tool_use"` text,
    /// bookkeeping) land far more often than this; long tool runs are exempt entirely
    /// via `.toolInFlight`. Without the ladder, an interrupted session idling at its
    /// prompt is green for as long as the process lives.
    static let passiveWorkingStaleSeconds: TimeInterval = 600

    /// Maps a live Claude process's transcript-tail verdict to a display state.
    ///
    /// The tail is consulted before any mtime shortcut: post-turn bookkeeping writes
    /// (ai-title, custom-title, …) bump mtime after the run ended and must not repaint
    /// green, and a finished turn is aged from the deciding record's own timestamp so
    /// those writes cannot re-flash red either.
    static func passiveClaudeState(
        tail: AgentSessionLogParser.ClaudeTailResult,
        jsonlMtime: Date?,
        fallbackTsMs: Int64,
        now: Date,
        collapseMs: Int64,
        inactiveMs: Int64,
        recentJsonlThreshold: TimeInterval = 10,
        workingStaleSeconds: TimeInterval = passiveWorkingStaleSeconds
    ) -> (rawState: String, state: AgentTrafficLightState, visible: Bool, updatedAtMs: Int64) {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        switch tail.state {
        case .toolInFlight:
            // A tool may legitimately run for many minutes with zero writes — never age out.
            return ("executing", .executing, true, fallbackTsMs)
        case .working:
            // A response has been owed since the deciding record; newer file writes count
            // as life signs too. No evidence at all stays green — conservative.
            let evidence = [tail.recordTimestamp, jsonlMtime].compactMap { $0 }.max()
            if let evidence, now.timeIntervalSince(evidence) > workingStaleSeconds {
                return ("idle", .inactive, true, fallbackTsMs)
            }
            return ("thinking", .thinking, true, fallbackTsMs)
        case .turnFinished:
            let stopMs = tail.recordTimestamp.map { Int64($0.timeIntervalSince1970 * 1000) } ?? fallbackTsMs
            let lifecycle = resolveHookState(
                rawState: "stopped",
                ageMs: nowMs - stopMs,
                collapseMs: collapseMs,
                inactiveMs: inactiveMs
            )
            // Red flashes and collapses as usual, but the process is still running,
            // so the session stays in the list as a dim card rather than vanishing.
            let resolved = lifecycle.visible ? lifecycle : (.inactive, true)
            return ("stopped", resolved.state, resolved.visible, stopMs)
        case .unknown:
            // The caller only reaches here for a *live* process whose tail could not be
            // parsed even after the read window escalated — a torn read, or a record wider
            // than the largest window. A running process is far likelier working than idle,
            // and calling it idle is actively destructive now that the reconciler's demote
            // arm acts on passive verdicts: one unreadable tail would dim a correctly-green
            // session. Fail toward "working" and let the hook state or the next tick correct.
            return ("thinking", .thinking, true, fallbackTsMs)
        }
    }

    /// Highest-priority active session drives the traffic light across all projects.
    static func resolveDisplayState(from sessions: [AgentSessionStatus]) -> AgentTrafficLightState {
        let visible = sessions.filter { $0.isVisible && !isSimulationSession($0) }
        return visible.map(\.displayState).max() ?? .inactive
    }

    static func primarySession(from sessions: [AgentSessionStatus]) -> AgentSessionStatus? {
        let visible = sessions.filter { $0.isVisible && !isSimulationSession($0) }
        guard !visible.isEmpty else { return nil }
        let topState = visible.map(\.displayState).max() ?? .inactive
        let candidates = visible.filter { $0.displayState == topState }
        return candidates.max(by: { lhs, rhs in
            let lhsReliable = hasReliableChatName(lhs.chatName)
            let rhsReliable = hasReliableChatName(rhs.chatName)
            if lhsReliable != rhsReliable {
                return !lhsReliable
            }
            return lhs.updatedAt < rhs.updatedAt
        })
    }

    static func isSimulationSession(_ session: AgentSessionStatus) -> Bool {
        isSimulationConversationID(session.conversationID)
            || isSimulationConversationID(session.id)
    }

    static func isSimulationConversationID(_ value: String) -> Bool {
        let id = value.lowercased()
        if id.contains("kannu-test") { return true }
        if id == "default" { return true }
        if id.hasPrefix("test-") { return true }
        return false
    }

    private static func hasReliableChatName(_ value: String?) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return false }
        return !AgentApprovalGatedTools.looksLikeToolName(trimmed)
    }

    static func aggregate(_ sessions: [AgentSessionStatus]) -> AgentTrafficLightState {
        resolveDisplayState(from: sessions)
    }

    // MARK: - Kannu's own /usage probe

    /// The manual usage refresh spawns an interactive `claude` and types `/usage`. That session
    /// registers like any other (session file, hook file, transcript), so it would show up as a
    /// phantom chat. The monitor recognises it by process ancestry while it runs and remembers
    /// its conversation id, capped, so the dead session file is ignored afterwards too.
    static let usageProbeIDCap = 32

    static func isUsageProbeSession(conversationID: String, probeIDs: [String]) -> Bool {
        probeIDs.contains(conversationID)
    }

    /// Appends `id` (moving it to the newest slot if already present) and trims the oldest.
    static func rememberingProbeConversationID(_ id: String, in ids: [String], cap: Int = usageProbeIDCap) -> [String] {
        var out = ids.filter { $0 != id }
        out.append(id)
        if out.count > cap { out.removeFirst(out.count - cap) }
        return out
    }

    // MARK: - Ended chats stay listed

    /// How long a chat that went red and then ended stays in Recent chats as a dim card.
    static let endedChatRetentionSeconds: TimeInterval = 69

    struct RetainedEndedSession: Equatable {
        let session: AgentSessionStatus
        let endedAt: Date
    }

    /// Keeps a conversation that was visibly red (`.stopped`) in `previous` and has since gone —
    /// its status file deleted by SessionEnd, or its collapse+dim window elapsed — on the list as
    /// an inactive, visible card for `retention`. Purely a list concern: the copy is `.inactive`,
    /// so the traffic light, caffeinate and the primary-session pick ignore it. A retained
    /// conversation is dropped the moment it shows up live (or red) again, and after `retention`.
    static func retainEndedSessions(
        previous: [AgentSessionStatus],
        current: [AgentSessionStatus],
        retained: [String: RetainedEndedSession],
        now: Date,
        retention: TimeInterval = endedChatRetentionSeconds
    ) -> (sessions: [AgentSessionStatus], retained: [String: RetainedEndedSession]) {
        var map = retained.filter { now.timeIntervalSince($0.value.endedAt) < retention }
        let currentByID = Dictionary(current.map { ($0.conversationID, $0) }, uniquingKeysWith: { first, _ in first })

        // Live or red again: the real session owns the row.
        for (id, session) in currentByID where session.isVisible && session.displayState != .inactive {
            map.removeValue(forKey: id)
        }

        for prior in previous
        where prior.isVisible && prior.displayState == .stopped && !isSimulationSession(prior) && map[prior.conversationID] == nil {
            let nowEntry = currentByID[prior.conversationID]
            guard nowEntry == nil || nowEntry?.isVisible == false else { continue }
            map[prior.conversationID] = RetainedEndedSession(
                session: prior.withDisplayState(.inactive, visible: true, updatedAt: now),
                endedAt: now
            )
        }

        var out = current.map { session -> AgentSessionStatus in
            guard !session.isVisible, let kept = map[session.conversationID] else { return session }
            return kept.session
        }
        let listed = Set(out.map(\.conversationID))
        for (id, kept) in map where !listed.contains(id) {
            out.append(kept.session)
        }
        return (out, map)
    }
}

extension AgentSessionStatus {
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
            executionStartedAt: executionStartedAt,
            cwd: cwd,
            hostPID: hostPID
        ).carryingExtras(from: self)
    }

    func replacingProjectName(_ projectName: String) -> AgentSessionStatus {
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
            executionStartedAt: executionStartedAt,
            cwd: cwd,
            hostPID: hostPID
        ).carryingExtras(from: self)
    }

    /// "Stopped · rate limited (429)": the verdict, rendered only once the run has stopped —
    /// including the dim, retained card an ended chat leaves behind. Empty for a clean finish.
    var runOutcomeSuffix: String {
        guard displayState == .stopped || displayState == .inactive, let runError else { return "" }
        return " · " + runError.label
    }

    /// Copies the fields a memberwise reconstruction silently drops — the tool-error count, the
    /// unattended flag, the run verdict, the Desktop chat locator. Every site that rebuilds a
    /// session from another one must call this: docs/REGRESSIONS.md entry 7 is exactly this
    /// failure, for cwd and hostPID. Across a merge seam the larger count wins and the flag is an
    /// OR (both are monotone within a session); the verdict is `self` unless it has none — see
    /// `RunError.preferred`; the locator is `self` unless nil.
    func carryingExtras(from source: AgentSessionStatus) -> AgentSessionStatus {
        var copy = self
        copy.toolErrorCount = max(copy.toolErrorCount, source.toolErrorCount)
        copy.isUnattended = copy.isUnattended || source.isUnattended
        copy.runError = RunError.preferred(copy.runError, source.runError)
        copy.desktopSessionID = copy.desktopSessionID ?? source.desktopSessionID
        copy.sightings = HookSightings.union(copy.sightings, source.sightings)
        copy.terminal = copy.terminal ?? source.terminal
        return copy
    }
}

/// Answers "did anything other than the running-agent heartbeat happen since the reveal
/// observer last looked?" for `CursorAgentStatusMonitor.activityPulse`.
///
/// One `rescan()` can publish several bumps in a single main-actor turn — a session-list
/// change, a traffic-light transition, and the heartbeat last — and SwiftUI collapses them
/// into one `onChange`. A flag describing only the *last* bump therefore reported "heartbeat"
/// for a turn that also carried the transition, and strict collapse dropped the reveal. The
/// latch is monotonic within a window: a transition can never be masked by a later heartbeat.
/// Lives here rather than on the monitor so the logic-only test target can pin it.
struct AgentActivityPulseLatch {
    private(set) var heartbeatOnly = true

    /// A traffic-light transition or session-list change was published.
    mutating func noteTransition() { heartbeatOnly = false }

    /// A heartbeat was published. Never upgrades a window back to heartbeat-only.
    mutating func noteHeartbeat() {}

    /// The observer's verdict for the window that just closed; opens the next one.
    mutating func consume() -> Bool {
        defer { heartbeatOnly = true }
        return heartbeatOnly
    }
}

// MARK: - Run outcome

/// Why a run ended, when it ended on an error. Only a run-terminating signal becomes one: a tool
/// failure the agent recovered from is a count (`toolErrorCount`), never a verdict.
enum RunError: Equatable, Hashable {
    /// The model's turn died on the API — `isApiErrorMessage` in a Claude transcript, or a
    /// Claude Desktop `result` carrying `api_error_status`. `status` is the HTTP status when known.
    case apiError(status: Int?)
    /// A run that ended failing without saying why: the hook's `StopFailure`, an Antigravity
    /// `Stop` carrying an error, a Warp `Failed` exchange, a Claude Desktop `result` with `is_error`.
    case failed

    /// Short and user-facing, appended to "Stopped".
    var label: String {
        switch self {
        case .failed:
            return String(localized: "failed")
        case .apiError(let status):
            switch status {
            case 429: return String(localized: "rate limited (429)")
            case 529: return String(localized: "API overloaded (529)")
            case 401: return String(localized: "signed out (401)")
            case .some(let code): return String(localized: "API error \(code)")
            case .none: return String(localized: "API error")
            }
        }
    }

    /// The more specific reason wins when two sources describe the same stop.
    var specificity: Int {
        switch self {
        case .apiError: return 2
        case .failed: return 1
        }
    }

    /// `own ?? other`, refined: nil yields to the other side, and when both carry a verdict the
    /// more specific one wins (a tie keeps `own`). Never an OR or a max: the verdict must reset
    /// to nil every turn, and under OR/max nil is the identity, so one stale verdict would pin
    /// "failed" onto every later clean turn. The passive side is fresh by construction — its
    /// verdict exists only while the newest conversational record is the error.
    static func preferred(_ own: RunError?, _ other: RunError?) -> RunError? {
        guard let own else { return other }
        guard let other else { return own }
        return other.specificity > own.specificity ? other : own
    }
}
