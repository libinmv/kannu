import Foundation

enum AgentApprovalGatedTools {
    /// Built-in Cursor tools that commonly pause for explicit user approval (e.g. web search).
    private static let exactMatches: Set<String> = [
        "websearch",
        "webfetch",
        "web_search",
        "web_fetch",
        "askquestion",
        "ask_question",
        "userquestion",
        "permissionrequest",
        "shell",
        "run_terminal_cmd",
    ]

    static func requiresUserApproval(_ toolName: String) -> Bool {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lower = trimmed.lowercased()
        if exactMatches.contains(lower) { return true }

        let compact = lower.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        if compact == "websearch" || compact == "webfetch" || compact == "search" || compact == "askquestion" {
            return true
        }
        if compact == "shell" || compact == "runterminalcmd" {
            return true
        }

        // Cursor occasionally labels search approval flows with generic Search tool names.
        if lower == "search" { return true }

        return false
    }

    /// Chat-title heuristic: true when a candidate title is actually a tool name that leaked
    /// into the name field. Lives here (pure, Foundation-only) so the traffic-light mapper
    /// and unit tests can use it without dragging in the monitor.
    static func looksLikeToolName(_ value: String?) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return false }

        if requiresUserApproval(trimmed) {
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
}
