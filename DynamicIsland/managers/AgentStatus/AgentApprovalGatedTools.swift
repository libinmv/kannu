import Foundation

enum AgentApprovalGatedTools {
    /// Built-in Cursor tools that commonly pause for explicit user approval (e.g. web search).
    private static let exactMatches: Set<String> = [
        "websearch",
        "webfetch",
        "web_search",
        "web_fetch",
    ]

    static func requiresUserApproval(_ toolName: String) -> Bool {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lower = trimmed.lowercased()
        if exactMatches.contains(lower) { return true }

        let compact = lower.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        if compact == "websearch" || compact == "webfetch" { return true }

        // Cursor occasionally labels search approval flows with generic Search tool names.
        if lower == "search" || compact == "search" { return true }

        return false
    }
}
