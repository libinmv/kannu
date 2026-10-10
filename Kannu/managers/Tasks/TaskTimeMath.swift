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

/// Actual time on a task: totals, the estimate, the rounding a log entry uses, and opening and
/// closing segments.
///
/// Tracked time comes from wall-clock dates on the segments, never from timer ticks, so time past
/// the estimate (the timer's overtime) counts like any other. The segments are the record; the
/// timer's ring is only a display and can differ from them by a tick.
enum TaskTimeMath {
    /// A log entry is rounded to the nearest quarter hour.
    static let logIncrementSeconds = 15 * 60

    /// One segment's time: closed, its length; live, up to `now`; interrupted, nothing until the
    /// user sets its end.
    static func seconds(of segment: WorkSegment, now: Date) -> Int {
        let end: Date
        if let closed = segment.end {
            end = closed
        } else if segment.isLive {
            end = now
        } else {
            return 0
        }
        return max(0, Int(end.timeIntervalSince(segment.start)))
    }

    /// Everything recorded on a task, in whole seconds. Shown exact (in minutes), never rounded.
    static func trackedSeconds(_ segments: [WorkSegment], now: Date) -> Int {
        segments.reduce(0) { $0 + seconds(of: $1, now: now) }
    }

    /// The estimate minus the tracked time: negative past the estimate, nil without one.
    static func remainingSeconds(estimate: Int?, tracked: Int) -> Int? {
        estimate.map { $0 - tracked }
    }

    /// How far past the estimate a task is; zero within it or without one.
    static func overtimeSeconds(estimate: Int?, tracked: Int) -> Int {
        guard let estimate else { return 0 }
        return max(0, tracked - estimate)
    }

    /// How long a task's timer runs: what is left of its estimate, or the default session length
    /// when there is no estimate or nothing is left of it.
    static func sessionLengthSeconds(estimate: Int?, tracked: Int, defaultMinutes: Int) -> Int {
        if let remaining = remainingSeconds(estimate: estimate, tracked: tracked), remaining > 0 {
            return remaining
        }
        return max(1, defaultMinutes) * 60
    }

    /// `seconds` rounded to the nearest 15 minutes, halves up: 7m29s is 0, 7m30s is 15m, 22m30s is
    /// 30m. A total that rounds to 0 makes no log entry and carries over to the next one.
    static func roundedForLog(_ seconds: Int) -> Int {
        let increment = logIncrementSeconds
        return ((max(0, seconds) + increment / 2) / increment) * increment
    }

    // MARK: - Opening and closing segments

    /// Opens a live segment at `date`. Nothing changes when one is already open, so a repeated
    /// start (a wake after a resume) cannot record the same time twice.
    static func opening(_ segments: [WorkSegment], at date: Date, origin: WorkSegment.Origin = .timer) -> [WorkSegment] {
        guard !segments.contains(where: \.isLive) else { return segments }
        return segments + [WorkSegment(start: date, origin: origin)]
    }

    /// Closes the live segment at `date` (never before its start). A segment that would be empty
    /// is dropped. Nothing changes when none is open: a pause followed by a stop closes once.
    static func closing(_ segments: [WorkSegment], at date: Date) -> [WorkSegment] {
        guard let index = segments.firstIndex(where: \.isLive) else { return segments }
        var result = segments
        let end = max(result[index].start, date)
        if end.timeIntervalSince(result[index].start) < 1 {
            result.remove(at: index)
        } else {
            result[index].end = end
        }
        return result
    }
}

/// A length of time as people type it and read it: "1h 12m", "72m", "1.5h", "90".
enum WorkDuration {
    /// The longest length accepted, so a typo cannot record a year.
    static let maxSeconds = 1_000 * 3600

    /// Seconds, or nil when the text is not a length. A bare number is minutes. Units: h, hr, hrs,
    /// hour, hours, m, min, mins, minute, minutes; a decimal comma reads as a point.
    static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty else { return nil }
        if let minutes = Double(trimmed) {
            return clamp(minutes * 60)
        }

        var total = 0.0
        var index = trimmed.startIndex
        func skipSpaces() {
            while index < trimmed.endIndex, trimmed[index] == " " { index = trimmed.index(after: index) }
        }
        while true {
            skipSpaces()
            guard index < trimmed.endIndex else { break }
            let numberStart = index
            while index < trimmed.endIndex, trimmed[index].isASCII, trimmed[index].isNumber || trimmed[index] == "." {
                index = trimmed.index(after: index)
            }
            guard let value = Double(trimmed[numberStart..<index]) else { return nil }
            skipSpaces()
            let unitStart = index
            while index < trimmed.endIndex, trimmed[index].isLetter { index = trimmed.index(after: index) }
            switch trimmed[unitStart..<index] {
            case "h", "hr", "hrs", "hour", "hours": total += value * 3600
            case "m", "min", "mins", "minute", "minutes": total += value * 60
            default: return nil
            }
        }
        return clamp(total)
    }

    /// "1h 12m", "42m", "2h", "0m". Whole minutes, rounded down.
    static func format(_ seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        if rest == 0 { return "\(hours)h" }
        return "\(hours)h \(rest)m"
    }

    private static func clamp(_ seconds: Double) -> Int? {
        guard seconds.isFinite, seconds >= 0, seconds <= Double(maxSeconds) else { return nil }
        return Int(seconds.rounded())
    }
}
