import Foundation

/// Reads the usage history the Claude desktop app keeps for itself.
///
/// The app records a rate-limit sample every few minutes into
/// `~/Library/Application Support/Claude/plan-usage-history.json`, retaining roughly 30 days:
///
/// ```json
/// {"version": 2, "samples": [{"t": 1788027991573, "org": "…", "u": {"fh": 38, "sd": 61}}]}
/// ```
///
/// `u` is keyed by the app's short codes for each rate-limit window, and the values are the same
/// percentages the statusline hook receives. Reset times are not recorded, so this is a fallback:
/// it fills the gauges when no statusline snapshot exists — a user who only ever runs Claude in
/// the desktop app never triggers the hook — while the hook stays primary because it alone carries
/// the reset countdown.
///
/// Nothing about this file is documented, so parsing is defensive throughout: any surprise yields
/// nil and the caller shows no usage, exactly as if the file were absent.
enum ClaudeDesktopUsageHistory {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    /// The app's short code for each rate-limit window. `xu` is deliberately absent: it tracks
    /// extra-usage credits, which is spend, not a rate-limit window, and must not become a gauge.
    static let windowKeysByCode: [String: String] = [
        "fh": "five_hour",
        "sd": "seven_day",
        "so": "seven_day_opus",
        "sn": "seven_day_sonnet",
        "cw": "seven_day_cowork",
        "oa": "seven_day_oauth_apps",
        "om": "seven_day_omelette",
        "op": "omelette_promotional"
    ]

    /// Display order for the windows above, so the gauges do not reshuffle between reads.
    private static let codeOrder = ["fh", "sd", "so", "sn", "cw", "oa", "om", "op"]

    static func load(from url: URL = defaultURL) -> ClaudeUsageSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(json: json)
    }

    static func parse(json: [String: Any]) -> ClaudeUsageSnapshot? {
        guard let samples = json["samples"] as? [[String: Any]] else { return nil }

        // Samples are appended in order, but trust the timestamps rather than the position.
        let newest = samples.compactMap { sample -> (tMs: Double, usage: [String: Any])? in
            guard let tMs = (sample["t"] as? NSNumber)?.doubleValue, tMs > 0,
                  let usage = sample["u"] as? [String: Any] else { return nil }
            return (tMs, usage)
        }.max { $0.tMs < $1.tMs }

        guard let newest else { return nil }

        let windows = codeOrder.compactMap { code -> ClaudeUsageSnapshot.Window? in
            guard let key = windowKeysByCode[code],
                  let percent = (newest.usage[code] as? NSNumber)?.doubleValue else { return nil }
            return ClaudeUsageSnapshot.Window(key: key, percent: percent, resetsAt: nil)
        }
        guard !windows.isEmpty else { return nil }

        return ClaudeUsageSnapshot(
            windows: windows,
            observedAt: Date(timeIntervalSince1970: newest.tMs / 1000)
        )
    }
}
