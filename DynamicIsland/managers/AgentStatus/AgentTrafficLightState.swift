import Foundation

enum AgentTrafficLightState: Equatable {
    case thinking
    case executing
    case stopped
    case inactive
}

struct AgentSessionSnapshot: Equatable {
    let sessionID: String
    let lastActivityMs: Int64
    let composerStatus: String?
    let isDone: Bool
    let hasActiveToolUse: Bool
    let transcriptMtimeMs: Int64
}

enum AgentTrafficLightMapper {
    private static let runningStaleSeconds: TimeInterval = 360
    private static let abortedIdleSeconds: TimeInterval = 90

    static func map(
        session: AgentSessionSnapshot?,
        now: Date = Date(),
        staleMinutes: Int,
        stoppedCollapseMinutes: Int
    ) -> AgentTrafficLightState {
        guard let session else { return .inactive }

        let nowSec = now.timeIntervalSince1970
        let maxAgeSec = TimeInterval(staleMinutes * 60)
        let lastActivitySec = TimeInterval(session.lastActivityMs) / 1000

        guard nowSec - lastActivitySec <= maxAgeSec else {
            return .inactive
        }

        // Stopped sessions collapse the indicator after a grace window.
        let collapseSec = TimeInterval(stoppedCollapseMinutes * 60)
        func stoppedOrInactive() -> AgentTrafficLightState {
            nowSec - lastActivitySec <= collapseSec ? .stopped : .inactive
        }

        let liveStatus = (session.composerStatus ?? "").lowercased()
        let isGenerating = ["generating", "running", "streaming", "thinking"].contains(liveStatus)
        let checkpointMs = session.transcriptMtimeMs
        let abortedIdle = liveStatus == "aborted"
            && checkpointMs > 0
            && nowSec - TimeInterval(checkpointMs) / 1000 > abortedIdleSeconds

        if session.isDone && !isGenerating {
            return stoppedOrInactive()
        }

        if abortedIdle {
            return stoppedOrInactive()
        }

        if liveStatus == "thinking" {
            return .thinking
        }

        if isGenerating || session.hasActiveToolUse {
            if session.hasActiveToolUse || ["generating", "running", "streaming"].contains(liveStatus) {
                return .executing
            }
            return .thinking
        }

        if nowSec - lastActivitySec <= runningStaleSeconds {
            if session.hasActiveToolUse {
                return .executing
            }
            return .thinking
        }

        return stoppedOrInactive()
    }
}

extension AgentTrafficLightState {
    var notificationKey: String {
        switch self {
        case .thinking: return "thinking"
        case .executing: return "executing"
        case .stopped: return "stopped"
        case .inactive: return "inactive"
        }
    }
}
