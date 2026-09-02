import Foundation

/// Server-reported Claude subscription usage for one or more rate-limit windows.
///
/// Claude Code parses `anthropic-ratelimit-unified-*` response headers into per-window state and
/// hands the result to the configured statusLine command as `rate_limits`, keyed by window name
/// (`used_percentage` 0-100, `resets_at` unix epoch seconds). The window set is open-ended —
/// `five_hour` and `seven_day` are universal, and a plan may additionally report per-model or
/// per-surface weekly windows such as `seven_day_opus` — so windows are carried as a list rather
/// than as fixed fields. The Kannu statusline hook writes them to
/// `~/.kannu/agent-status/claude-usage.json`; this type parses that file and owns the staleness
/// rules for display.
///
/// The values are snapshots, not live queries: they update only while a Claude session is making
/// API calls. Display must therefore degrade by age rather than pretend liveness.
struct ClaudeUsageSnapshot: Equatable {
    /// One rate-limit window as the server reported it.
    struct Window: Equatable {
        /// The server's window name, e.g. `five_hour`, `seven_day`, `seven_day_opus`.
        let key: String
        /// Percentage of the window consumed, 0-100.
        let percent: Double
        /// When the window rolls over. Absent from sources that do not report it.
        let resetsAt: Date?
        /// The server's own name for this window, when it supplied one. Per-model weekly windows
        /// arrive labelled (e.g. "Fable") rather than under a key Kannu could name itself; the
        /// universal windows leave this nil because their names belong to us.
        var label: String? = nil
        /// The server's own severity for this window ("normal"/"warning"/"critical"), when it
        /// reports one. Today only the cached-usage source carries it; the statusline hook (v4+)
        /// forwards it whenever a bucket supplies one. Drives the bar accent.
        var severity: String? = nil
    }

    let windows: [Window]
    /// When the values were observed (the file's `ts`, milliseconds).
    let observedAt: Date

    static let fiveHourKey = "five_hour"
    static let sevenDayKey = "seven_day"

    /// Age under which the snapshot is shown plainly; older snapshots render dimmed with age.
    static let freshInterval: TimeInterval = 600

    /// How often the usage sources are re-read while an agent is on screen.
    ///
    /// Both update on their own slow cadence — the statusline hook only when a session makes an
    /// API call, the desktop history every few minutes — so reading faster than this re-parses
    /// identical bytes. The monitor's rescan runs every second, which is why the gate exists.
    static let refreshInterval: TimeInterval = 600

    /// Whether the caller should re-read its usage sources now.
    ///
    /// One read happens with no agent running, so the usage card is populated when opened cold;
    /// after that, refreshing is tied to an agent being on screen, because nothing else can move
    /// the numbers. `.stopped` still counts as on screen: the read just after a run ends is the
    /// one that matters most.
    static func shouldRefresh(
        now: Date,
        lastRead: Date?,
        state: AgentTrafficLightState,
        hasSnapshot: Bool
    ) -> Bool {
        guard let lastRead, hasSnapshot else { return true }
        guard state != .inactive else { return false }
        return now.timeIntervalSince(lastRead) >= refreshInterval
    }

    enum Freshness: Equatable {
        case fresh
        /// Stale but still meaningful — show dimmed with relative age.
        case aged
    }

    func freshness(now: Date = Date()) -> Freshness {
        now.timeIntervalSince(observedAt) <= Self.freshInterval ? .fresh : .aged
    }

    /// Windows safe to put on screen, in display order: the 5-hour window, the all-models weekly
    /// window, then any additional windows in the order the source reported them.
    ///
    /// A window whose reset time has passed has certainly rolled over; its percentage is stale
    /// fiction and must not be shown.
    func displayWindows(now: Date = Date()) -> [Window] {
        let live = windows.filter { window in
            guard let resetsAt = window.resetsAt else { return true }
            return now < resetsAt
        }
        func rank(_ key: String) -> Int {
            switch key {
            case Self.fiveHourKey: return 0
            case Self.sevenDayKey: return 1
            default: return 2
            }
        }
        // Comparing on the source index too keeps equal ranks in reported order.
        return live.enumerated()
            .sorted { (rank($0.element.key), $0.offset) < (rank($1.element.key), $1.offset) }
            .map(\.element)
    }

    func window(_ key: String) -> Window? {
        windows.first { $0.key == key }
    }

    var fiveHourPercent: Double? { window(Self.fiveHourKey)?.percent }
    var fiveHourResetsAt: Date? { window(Self.fiveHourKey)?.resetsAt }
    var sevenDayPercent: Double? { window(Self.sevenDayKey)?.percent }
    var sevenDayResetsAt: Date? { window(Self.sevenDayKey)?.resetsAt }

    func fiveHourDisplayPercent(now: Date = Date()) -> Double? {
        displayWindows(now: now).first { $0.key == Self.fiveHourKey }?.percent
    }

    func sevenDayDisplayPercent(now: Date = Date()) -> Double? {
        displayWindows(now: now).first { $0.key == Self.sevenDayKey }?.percent
    }

    /// True when nothing is left to show — no windows, or every one of them past its reset.
    func isEmpty(now: Date = Date()) -> Bool {
        displayWindows(now: now).isEmpty
    }

    /// Combines several sources, best first, one window key at a time: each key is taken from the
    /// first source in which it is live (per `displayWindows`), and sources further down fill only
    /// the keys nothing above them could. One lapsed window in a good source therefore neither
    /// hides that source's live siblings nor blocks a lesser source from covering the gap — the
    /// whole-snapshot fallthrough this replaces dropped a live per-model window the moment the
    /// same source's five-hour window rolled over.
    ///
    /// A nil-reset window counts as live, as everywhere else, so it fills a key only when no
    /// better source has that key live. Lapsed copies are dropped, not carried. Severity is never
    /// borrowed across sources for one key: `accent(severity:fraction:)` gives it precedence, so a
    /// stale "normal" would suppress the red band on a fresher value. `observedAt` is the newest
    /// among the sources that contributed a window.
    ///
    /// Returns nil when nothing is live anywhere. Pure in its inputs, so repeated merges of
    /// unchanged files compare equal and do not republish.
    static func merged(_ sources: [ClaudeUsageSnapshot?], now: Date) -> ClaudeUsageSnapshot? {
        var windows: [Window] = []
        var seen: Set<String> = []
        var observedAt: Date?
        for source in sources.compactMap({ $0 }) {
            for window in source.displayWindows(now: now) where seen.insert(window.key).inserted {
                windows.append(window)
                observedAt = max(observedAt ?? source.observedAt, source.observedAt)
            }
        }
        guard let observedAt, !windows.isEmpty else { return nil }
        return ClaudeUsageSnapshot(windows: windows, observedAt: observedAt)
    }

    /// Why the card may be showing less than it should.
    enum Hint: Equatable {
        /// Claude hooks are installed, so the CLI is in use, yet neither server-backed source
        /// (statusline file, Claude Code's usage cache) has a live window. The CLI's usage fetch
        /// returns nothing when its keychain sign-in lacks the `user:profile` scope, and the same
        /// gate leaves the statusline's `rate_limits` null — one `/login` from a Terminal `claude`
        /// fixes both. Sessions inside the desktop app run on a host token without that scope,
        /// so `/login` there does not help.
        case signInNeeded
    }

    /// Desktop-only users (no Claude hooks) are never nagged: the desktop history is the source
    /// they were always meant to have.
    static func hint(
        hooksInstalled: Bool,
        statusline: ClaudeUsageSnapshot?,
        cache: ClaudeUsageSnapshot?,
        now: Date
    ) -> Hint? {
        guard hooksInstalled else { return nil }
        let serverBacked = [statusline, cache].compactMap { $0 }.contains { !$0.isEmpty(now: now) }
        return serverBacked ? nil : .signInNeeded
    }

    /// Parses both file shapes: the `windows` array written by the current hook, and the flat
    /// `five_hour_pct` / `seven_day_pct` form written by hooks predating open-ended windows.
    /// Older files stay readable so the gauges do not blank out between the app upgrading and
    /// the next statusline write.
    static func parse(json: [String: Any]) -> ClaudeUsageSnapshot? {
        guard let tsMs = (json["ts"] as? NSNumber)?.int64Value, tsMs > 0 else { return nil }

        let windows = parseWindowList(json["windows"]) ?? parseLegacyWindows(json)
        guard !windows.isEmpty else { return nil }

        return ClaudeUsageSnapshot(
            windows: windows,
            observedAt: Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000)
        )
    }

    static func load(from url: URL) -> ClaudeUsageSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(json: json)
    }

    private static func parseWindowList(_ value: Any?) -> [Window]? {
        guard let entries = value as? [[String: Any]] else { return nil }
        return entries.compactMap { entry in
            guard let key = entry["key"] as? String, !key.isEmpty,
                  let percent = (entry["pct"] as? NSNumber)?.doubleValue else { return nil }
            let label = (entry["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let severity = (entry["severity"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Window(key: key, percent: percent,
                          resetsAt: epochDate(entry["resets_at"]), label: label, severity: severity)
        }
    }

    private static func parseLegacyWindows(_ json: [String: Any]) -> [Window] {
        [(fiveHourKey, "five_hour_pct", "five_hour_resets_at"),
         (sevenDayKey, "seven_day_pct", "seven_day_resets_at")].compactMap { key, pctKey, resetKey in
            guard let percent = (json[pctKey] as? NSNumber)?.doubleValue else { return nil }
            return Window(key: key, percent: percent, resetsAt: epochDate(json[resetKey]))
        }
    }

    private static func epochDate(_ value: Any?) -> Date? {
        guard let epoch = (value as? NSNumber)?.doubleValue, epoch > 0 else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }
}
