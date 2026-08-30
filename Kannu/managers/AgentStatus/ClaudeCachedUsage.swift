import Foundation

/// Reads the usage payload Claude Code caches for itself in `~/.claude.json`.
///
/// After a successful `GET /api/oauth/usage` — which `/usage` triggers — Claude Code stores the
/// response under `cachedUsageUtilization`, and clears it on logout:
///
/// ```json
/// {"cachedUsageUtilization": {"fetchedAtMs": …, "accountUuid": "…", "utilization": {
///     "five_hour": {"utilization": 32, "resets_at": "…"},
///     "seven_day": {"utilization": 41, "resets_at": "…"},
///     "limits": [{"kind": "weekly_scoped", "percent": 68, "resets_at": "…",
///                 "scope": {"model": {"display_name": "Fable"}}}]}}}
/// ```
///
/// This is the only local source carrying **per-model weekly windows**. The statusline hook can
/// deliver them too, as `rate_limits.model_scoped`, but only while a session drives it; the desktop
/// app's history file drops them entirely. It also reports real reset timestamps, which the history
/// file forces Kannu to infer.
///
/// Reading it needs no credentials and makes no network call. Only the usage keys are touched.
enum ClaudeCachedUsage {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    /// The fixed windows, in display order. `cinder_cove` is undocumented but present in the
    /// schema, so it is carried through generically rather than dropped.
    private static let fixedWindows = [
        "five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet",
        "seven_day_oauth_apps", "cinder_cove"
    ]

    static func load(from url: URL = defaultURL) -> ClaudeUsageSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(json: json)
    }

    static func parse(json: [String: Any]) -> ClaudeUsageSnapshot? {
        guard let cache = json["cachedUsageUtilization"] as? [String: Any],
              let fetchedAtMs = (cache["fetchedAtMs"] as? NSNumber)?.doubleValue, fetchedAtMs > 0,
              let utilization = cache["utilization"] as? [String: Any] else { return nil }

        // Claude Code guards the cache by account; a mismatch means it belongs to a different login
        // and its numbers are not this user's.
        if let cached = cache["accountUuid"] as? String,
           let current = (json["oauthAccount"] as? [String: Any])?["accountUuid"] as? String,
           cached != current {
            return nil
        }

        var windows: [ClaudeUsageSnapshot.Window] = []

        for key in fixedWindows {
            guard let bucket = utilization[key] as? [String: Any],
                  let percent = (bucket["utilization"] as? NSNumber)?.doubleValue else { continue }
            windows.append(.init(key: key, percent: percent,
                                 resetsAt: isoDate(bucket["resets_at"])))
        }

        // Per-model weekly windows, selected the way Claude Code selects them for its own display.
        for entry in utilization["limits"] as? [[String: Any]] ?? [] {
            guard entry["kind"] as? String == "weekly_scoped",
                  let scope = entry["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String, !name.isEmpty,
                  let percent = (entry["percent"] as? NSNumber)?.doubleValue else { continue }
            windows.append(.init(key: "model_scoped:\(name)", percent: percent,
                                 resetsAt: isoDate(entry["resets_at"]), label: name))
        }

        guard !windows.isEmpty else { return nil }

        return ClaudeUsageSnapshot(
            windows: windows,
            observedAt: Date(timeIntervalSince1970: fetchedAtMs / 1000)
        )
    }

    /// The timestamps here are ISO 8601 strings carrying microseconds, unlike the epoch seconds the
    /// statusline hook reports. A value that will not parse yields nil rather than a wrong date.
    private static func isoDate(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
