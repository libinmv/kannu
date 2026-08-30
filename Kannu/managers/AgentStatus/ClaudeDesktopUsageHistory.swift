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
/// percentages the statusline hook receives. This is a fallback: it fills the gauges when no
/// statusline snapshot exists — a user who only ever runs Claude in the desktop app never triggers
/// the hook — while the hook stays primary because it reports reset times outright, where this file
/// forces them to be recovered from the shape of the history (see `resetDate(for:in:now:)`).
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

    /// How long each window runs, taken from its name rather than fitted to the data.
    private static let windowDurations: [String: TimeInterval] = [
        "fh": 5 * 3600,
        "sd": 7 * 24 * 3600
    ]

    static func load(from url: URL = defaultURL, now: Date = Date()) -> ClaudeUsageSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(json: json, now: now)
    }

    static func parse(json: [String: Any], now: Date = Date()) -> ClaudeUsageSnapshot? {
        guard let rawSamples = json["samples"] as? [[String: Any]] else { return nil }

        // Trust the timestamps rather than the append order.
        let samples = rawSamples.compactMap { sample -> (tMs: Double, usage: [String: Any])? in
            guard let tMs = (sample["t"] as? NSNumber)?.doubleValue, tMs > 0,
                  let usage = sample["u"] as? [String: Any] else { return nil }
            return (tMs, usage)
        }.sorted { $0.tMs < $1.tMs }

        guard let newest = samples.last else { return nil }

        let windows = codeOrder.compactMap { code -> ClaudeUsageSnapshot.Window? in
            guard let key = windowKeysByCode[code],
                  let percent = (newest.usage[code] as? NSNumber)?.doubleValue else { return nil }
            return ClaudeUsageSnapshot.Window(
                key: key,
                percent: percent,
                resetsAt: resetDate(for: code, in: samples, now: now)
            )
        }
        guard !windows.isEmpty else { return nil }

        return ClaudeUsageSnapshot(
            windows: windows,
            observedAt: Date(timeIntervalSince1970: newest.tMs / 1000)
        )
    }

    /// Recovers when a window next rolls over, since this file records no reset times.
    ///
    /// A rollover is visible as a drop in utilization, so the window that is running now began at the
    /// most recent one and ends a window-length later. Two things make that approximate, and the
    /// result is only ever used when it survives both:
    ///
    /// The app samples only while it is running, so a rollover is noticed some minutes after it
    /// happened and the derived reset lands slightly late. Late is the safe direction — an early
    /// guess would push the window past its reset, and `displayWindows` hides those.
    ///
    /// The 5-hour window is rolling, so its utilization also decays a point or two as old usage ages
    /// out. Those small decays are not rollovers, hence the threshold; but a decrease landing on zero
    /// is a rollover no matter how small, which is how `1 -> 0` and `4 -> 0` are caught.
    ///
    /// Returning nil simply means no countdown, which is the behaviour before any of this existed.
    private static func resetDate(
        for code: String,
        in samples: [(tMs: Double, usage: [String: Any])],
        now: Date
    ) -> Date? {
        guard let duration = windowDurations[code] else { return nil }

        var rolloverMs: Double?
        var previous: Double?
        for sample in samples {
            guard let value = (sample.usage[code] as? NSNumber)?.doubleValue else { continue }
            if let previous, value < previous, previous - value > 5 || value == 0 {
                rolloverMs = sample.tMs
            }
            previous = value
        }

        guard let rolloverMs else { return nil }
        let reset = Date(timeIntervalSince1970: rolloverMs / 1000 + duration)
        return reset > now ? reset : nil
    }
}
