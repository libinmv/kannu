/*
 * Kannu (കണ്ണ്)
 * Copyright (C) 2024-2026 Kannu Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation

/// One usage window as Kannu reasons about it, whichever provider reported it. Plain numbers, so
/// the forecast and the alert rules stay testable without the app target's usage models.
struct UsageWindowReading: Equatable {
    /// "<provider>:<key>", e.g. "claude:five_hour", "codex:week" — the same id the Usage tab uses
    /// to find a bar's forecast.
    let id: String
    /// The usage provider: "claude", "codex" or "cursor".
    let provider: String
    let key: String
    /// Short name for a push or caption: "5-hour", "weekly", "Fable weekly", "billing-cycle".
    let label: String
    /// 0–100.
    let percent: Double
    let resetsAt: Date?
    let severity: String?
    let observedAt: Date

    init(provider: String, key: String, label: String, percent: Double, resetsAt: Date?, severity: String?, observedAt: Date) {
        self.id = Self.id(provider: provider, key: key)
        self.provider = provider
        self.key = key
        self.label = label
        self.percent = min(max(percent, 0), 100)
        self.resetsAt = resetsAt
        self.severity = severity
        self.observedAt = observedAt
    }

    static func id(provider: String, key: String) -> String { provider + ":" + key }

    func isLive(now: Date) -> Bool { resetsAt.map { $0 > now } ?? true }

    /// Claude's live windows as readings, keyed as the Usage tab keys its bars.
    static func readings(fromClaude snapshot: ClaudeUsageSnapshot?, now: Date) -> [UsageWindowReading] {
        guard let snapshot else { return [] }
        return snapshot.displayWindows(now: now).map { window in
            UsageWindowReading(provider: "claude", key: window.key, label: claudeLabel(window),
                               percent: window.percent, resetsAt: window.resetsAt, severity: window.severity,
                               observedAt: snapshot.observedAt)
        }
    }

    static func claudeLabel(_ window: ClaudeUsageSnapshot.Window) -> String {
        switch window.key {
        case ClaudeUsageSnapshot.fiveHourKey: return String(localized: "5-hour")
        case ClaudeUsageSnapshot.sevenDayKey: return String(localized: "weekly")
        default:
            if let label = window.label, !label.isEmpty { return String(localized: "\(label) weekly") }
            return window.key.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Codex and Cursor report a session and a week slot; Cursor's "week" is really its billing cycle.
    static func label(provider: String, key: String) -> String {
        switch key {
        case "session": return String(localized: "5-hour")
        case "week": return provider == "cursor" ? String(localized: "billing-cycle") : String(localized: "weekly")
        default: return key.replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// Where a usage window is heading, from Kannu's own readings of it over time. The providers
/// report only "percent now"; the pace comes from successive readings, so a forecast needs a few
/// of them spread over a meaningful stretch before it says anything.
enum UsageForecast {
    struct Sample: Codable, Equatable {
        let at: Date
        let percent: Double
        let resetsAt: Date?
    }

    enum Outlook: Equatable {
        case insufficientData
        case steady
        /// Lasts until the reset at this pace; `projected` is the percent it reaches by then.
        case lastsUntilReset(projected: Double)
        case hitsLimit(at: Date)
        case atLimit
    }

    static let minSampleInterval: TimeInterval = 120
    static let maxSamples = 240
    /// A drop this large means the window rolled over (or decayed): a new series starts.
    static let restartDrop: Double = 5
    static let resetShiftTolerance: TimeInterval = 600
    static let steadySlopePerHour: Double = 0.1
    static let atLimitPercent: Double = 99.5
    static let minimumSamples = 3
    /// Without a reported reset, a limit further out than this is not a forecast worth showing.
    static let horizonWithoutReset: TimeInterval = 7 * 24 * 3600

    static func isShortWindow(_ key: String) -> Bool {
        key == ClaudeUsageSnapshot.fiveHourKey || key == "session"
    }

    static func lookback(forKey key: String) -> TimeInterval { isShortWindow(key) ? 90 * 60 : 24 * 3600 }
    static func minimumSpan(forKey key: String) -> TimeInterval { isShortWindow(key) ? 15 * 60 : 3 * 3600 }

    /// Adds one reading. The same observation read twice is not a new sample; readings closer
    /// than `minInterval` are skipped; a rollover (a big drop, or the reset moving) starts over.
    static func admitting(_ sample: Sample, to samples: [Sample],
                          minInterval: TimeInterval = minSampleInterval, cap: Int = maxSamples) -> [Sample] {
        guard let last = samples.last else { return [sample] }
        guard sample.at > last.at else { return samples }
        if sample.percent < last.percent - restartDrop { return [sample] }
        if let new = sample.resetsAt, let old = last.resetsAt, abs(new.timeIntervalSince(old)) > resetShiftTolerance {
            return [sample]
        }
        guard sample.at.timeIntervalSince(last.at) >= minInterval else { return samples }
        var out = samples + [sample]
        if out.count > cap { out.removeFirst(out.count - cap) }
        return out
    }

    /// Least-squares pace over the look-back window, projected to 100 % and compared with the reset.
    static func outlook(_ samples: [Sample], current: UsageWindowReading, now: Date) -> Outlook {
        if current.percent >= atLimitPercent { return .atLimit }
        let recent = samples.filter { $0.at <= now && now.timeIntervalSince($0.at) <= lookback(forKey: current.key) }
        guard recent.count >= minimumSamples, let first = recent.first, let last = recent.last,
              last.at.timeIntervalSince(first.at) >= minimumSpan(forKey: current.key) else { return .insufficientData }
        let xs = recent.map { $0.at.timeIntervalSince(first.at) / 3600 }
        let ys = recent.map(\.percent)
        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var numerator = 0.0
        var denominator = 0.0
        for (x, y) in zip(xs, ys) {
            numerator += (x - meanX) * (y - meanY)
            denominator += (x - meanX) * (x - meanX)
        }
        guard denominator > 0 else { return .insufficientData }
        let perHour = numerator / denominator
        guard perHour > steadySlopePerHour else { return .steady }
        let eta = now.addingTimeInterval((100 - current.percent) / perHour * 3600)
        if let reset = current.resetsAt {
            if eta >= reset {
                return .lastsUntilReset(projected: min(100, current.percent + perHour * reset.timeIntervalSince(now) / 3600))
            }
            return .hitsLimit(at: eta)
        }
        return eta.timeIntervalSince(now) > horizonWithoutReset ? .steady : .hitsLimit(at: eta)
    }

    /// The line under a bar — only when it tells the user something.
    static func caption(_ outlook: Outlook, resetsAt: Date?, now: Date) -> (text: String, isWarning: Bool)? {
        switch outlook {
        case .hitsLimit(let at):
            return (String(localized: "At this pace: full by \(clock(at, now: now))"), true)
        case .atLimit:
            if let resetsAt { return (String(localized: "Limit reached — resets \(clock(resetsAt, now: now))"), true) }
            return (String(localized: "Limit reached"), true)
        case .lastsUntilReset(let projected) where projected >= 75:
            return (String(localized: "At this pace: about \(Int(projected.rounded()))% at reset"), false)
        default:
            return nil
        }
    }

    /// "3:40 PM" today, "Tue 3:40 PM" on another day.
    static func clock(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time
    }
}

/// When usage deserves attention, and what may be said about it.
enum UsageAlertPolicy {
    static let nearLimitPercent: Double = 95
    static let fullPercent: Double = 99

    /// Live windows at or past 95 %, or marked critical by the server.
    static func nearLimit(_ readings: [UsageWindowReading], now: Date) -> [UsageWindowReading] {
        readings.filter { $0.isLive(now: now) && ($0.percent >= nearLimitPercent || $0.severity?.lowercased() == "critical") }
    }

    /// One push per window instance: the same window after its reset is a new one.
    static func pushKey(_ reading: UsageWindowReading) -> String {
        reading.id + "|" + String(Int(reading.resetsAt?.timeIntervalSince1970 ?? 0))
    }

    /// Provider, window and reset — never a chat name.
    static func pushText(_ reading: UsageWindowReading, now: Date) -> (title: String, body: String) {
        let title = String(localized: "\(providerName(reading.provider)) \(reading.label) limit at \(Int(reading.percent.rounded()))%")
        let body = reading.resetsAt.map { String(localized: "Resets \(UsageForecast.clock($0, now: now)).") }
            ?? String(localized: "No reset time reported.")
        return (title, body)
    }

    static func providerName(_ provider: String) -> String {
        switch provider {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "cursor": return "Cursor"
        default: return provider.capitalized
        }
    }

    static func usageProvider(forSessionProvider provider: String) -> String? {
        switch provider.lowercased() {
        case "claude", "claudedesktop": return "claude"
        case "codex": return "codex"
        case "cursor": return "cursor"
        default: return nil
        }
    }

    /// For a chat that stopped on a rate limit: when the full window(s) reset. Nil unless a
    /// window really is full — a 429 can be short-term throttling, and "resumes at" would lie.
    static func resumeDate(provider: String, runError: RunError?, rawState: String,
                           readings: [UsageWindowReading], now: Date) -> Date? {
        guard runError == .apiError(status: 429) || rawState.lowercased() == "quota_exceeded" else { return nil }
        guard let usage = usageProvider(forSessionProvider: provider) else { return nil }
        let full = readings.filter {
            $0.provider == usage && $0.isLive(now: now) && ($0.percent >= fullPercent || $0.severity?.lowercased() == "critical")
        }
        return full.compactMap(\.resetsAt).max()
    }

    /// The earliest future reset among these readings: the moment something must be re-evaluated.
    static func nextReset(_ readings: [UsageWindowReading], now: Date) -> Date? {
        readings.compactMap(\.resetsAt).filter { $0 > now }.min()
    }
}
