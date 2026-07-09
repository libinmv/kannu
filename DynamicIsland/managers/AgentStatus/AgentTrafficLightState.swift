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
        case .executing: return 5
        case .thinking: return 4
        case .awaitingInput: return 3
        case .stopped: return 2
        case .inactive: return 1
        }
    }

    static func < (lhs: AgentTrafficLightState, rhs: AgentTrafficLightState) -> Bool {
        lhs.sortPriority < rhs.sortPriority
    }

    /// Green light: any active agent work (thinking, executing, planning, etc.).
    var showsGreenTrafficLight: Bool {
        switch self {
        case .executing, .thinking: return true
        default: return false
        }
    }

    /// Yellow light: waiting on the user.
    var showsYellowTrafficLight: Bool {
        self == .awaitingInput
    }

    /// Red light: stopped / finished.
    var showsRedTrafficLight: Bool {
        self == .stopped
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

    var providerLabel: String {
        switch provider.lowercased() {
        case "cursor": return "Cursor"
        case "vscode": return "VS Code"
        case "codex": return "Codex"
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
    let transcriptMtimeMs: Int64
}

enum AgentTrafficLightMapper {
    private static let runningStaleSeconds: TimeInterval = 360
    private static let abortedIdleSeconds: TimeInterval = 90
    private static let awaitingInputStaleMs: Int64 = 90_000

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
        stoppedCollapseMinutes: Int,
        inactiveDisplayMinutes: Int
    ) -> (state: AgentTrafficLightState, visible: Bool) {
        guard let session else { return (.inactive, false) }

        let nowSec = now.timeIntervalSince1970
        let maxAgeSec = TimeInterval(staleMinutes * 60)
        let lastActivitySec = TimeInterval(session.lastActivityMs) / 1000

        guard nowSec - lastActivitySec <= maxAgeSec else {
            return (.inactive, false)
        }

        let collapseSec = TimeInterval(stoppedCollapseMinutes * 60)
        let inactiveSec = TimeInterval(inactiveDisplayMinutes * 60)

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

        if session.hasPendingToolApproval {
            return (.awaitingInput, true)
        }

        let isGenerating = ["generating", "running", "streaming", "thinking"].contains(liveStatus)
        let checkpointMs = session.transcriptMtimeMs
        let abortedIdle = liveStatus == "aborted"
            && checkpointMs > 0
            && nowSec - TimeInterval(checkpointMs) / 1000 > abortedIdleSeconds

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

    /// The traffic light reflects the most recently updated session, not a mix of stale sessions.
    static func resolveDisplayState(from sessions: [AgentSessionStatus]) -> AgentTrafficLightState {
        let visible = sessions.filter(\.isVisible)
        guard let primary = visible.max(by: { $0.updatedAt < $1.updatedAt }) else {
            return .inactive
        }
        return primary.displayState
    }

    static func aggregate(_ sessions: [AgentSessionStatus]) -> AgentTrafficLightState {
        resolveDisplayState(from: sessions)
    }
}
