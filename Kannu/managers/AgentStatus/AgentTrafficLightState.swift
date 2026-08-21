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
            executionStartedAt: executionStartedAt
        )
    }

    var providerLabel: String {
        switch provider.lowercased() {
        case "cursor": return "Cursor"
        case "vscode": return "VS Code"
        case "codex": return "Codex"
        case "claude": return "Claude"
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
        activeStaleMs: Int64 = 360_000
    ) -> (state: AgentTrafficLightState, visible: Bool) {
        switch rawState.lowercased() {
        case "executing" where ageMs <= activeStaleMs:
            return (.executing, true)
        case "awaiting_input", "awaitinginput", "awaiting":
            if ageMs <= awaitingInputStaleMs { return (.awaitingInput, true) }
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
}
