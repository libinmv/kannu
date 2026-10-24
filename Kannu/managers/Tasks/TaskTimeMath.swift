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

    /// The length a running session follows its task's estimate to: what the estimate left when the
    /// session began. Nil leaves the countdown alone — a session that does not follow (a preset or a
    /// typed length: no `trackedAtStart`), no estimate, or one at or below what was tracked before the
    /// session. Start would give that last one the default length; a running countdown never jumps
    /// to it.
    static func followedLength(estimate: Int?, trackedAtStart: Int?) -> Int? {
        guard let estimate, let trackedAtStart, estimate > trackedAtStart else { return nil }
        return estimate - trackedAtStart
    }

    /// A running countdown given a new length, keeping what has run (`total - remaining`; the
    /// timer's elapsed time stops at the length in overtime, so it cannot say). Whole seconds: the
    /// timer's tick finishes on exactly 0. At or under 0 the session is over: finished, in overtime.
    static func retargeted(total: Int, remaining: Int, to length: Int)
        -> (total: Int, remaining: Int, elapsed: Int, isOver: Bool) {
        let ran = max(0, total - remaining)
        let left = length - ran
        return (length, left, min(ran, length), left <= 0)
    }

    /// `seconds` rounded to the nearest 15 minutes, halves up: 7m29s is 0, 7m30s is 15m, 22m30s is
    /// 30m. A total that rounds to 0 makes no log entry and carries over to the next one.
    static func roundedForLog(_ seconds: Int) -> Int {
        let increment = logIncrementSeconds
        return ((max(0, seconds) + increment / 2) / increment) * increment
    }

    // MARK: - How the task lists show it

    /// A task's time against its estimate, as Brain › Tasks and the notch's Tasks popover show it:
    /// "42m of 2h"; "42m tracked" without an estimate; "No estimate" before any time. `over` is the
    /// time past the estimate once it is a minute or more, which the lists show apart, in orange,
    /// as "10m over".
    static func progress(tracked: Int, estimate: Int?) -> (text: String, over: Int?) {
        let trackedText = WorkDuration.format(tracked)
        let text: String
        if let estimate {
            text = String(localized: "\(trackedText) of \(WorkDuration.format(estimate))")
        } else if tracked > 0 {
            text = String(localized: "\(trackedText) tracked")
        } else {
            text = String(localized: "No estimate")
        }
        let over = overtimeSeconds(estimate: estimate, tracked: tracked)
        return (text, over >= 60 ? over : nil)
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

    // MARK: - Ending an interrupted segment

    /// The latest end `segment` may be given: the earliest start of any segment on the task that
    /// began after it, capped at `now`, and never before its own start.
    ///
    /// After a crash at 10:00 the user re-times 10:05–11:00, then ends the interrupted session. An
    /// end past 10:05 would count 10:05–11:00 twice, in the tracked total and in the log drafts
    /// folded from it. A segment that began before the interrupted one is an earlier session and
    /// does not bound it.
    static func endBound(for segment: WorkSegment, in segments: [WorkSegment], now: Date) -> Date {
        max(segment.start, min(nextStart(after: segment, in: segments) ?? now, now))
    }

    /// The earliest start of any segment on the task that began after `segment`, or nil when none
    /// has. Clock-free, so a view can hold it and cap it at its own `Date()` when it renders.
    static func nextStart(after segment: WorkSegment, in segments: [WorkSegment]) -> Date? {
        segments.lazy
            .filter { $0.id != segment.id && $0.start > segment.start }
            .map(\.start)
            .min()
    }
}

/// A length of time as people type it and read it: "1h 12m", "72m", "1.5h", "90", "2d 3h".
enum WorkDuration {
    /// The longest length accepted, so a typo cannot record a year.
    static let maxSeconds = 1_000 * 3600
    /// A typed day is a workday, as GitLab and Jira count one by default: "2d" is 16 hours of work.
    /// Lengths are still shown in hours (`format`), so "2d" reads back as "16h".
    static let hoursPerDay = 8

    /// Seconds, or nil when the text is not a length. A bare number is minutes. Units: d, day, days
    /// (`hoursPerDay` each), h, hr, hrs, hour, hours, m, min, mins, minute, minutes; a decimal comma
    /// reads as a point.
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
            case "d", "day", "days": total += value * Double(hoursPerDay) * 3600
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

    /// A running clock, for the task being timed: "0:05", "42:05", "1:02:03". Whole seconds.
    static func clock(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        let paddedSeconds = rest < 10 ? "0\(rest)" : "\(rest)"
        if hours == 0 { return "\(minutes):\(paddedSeconds)" }
        let paddedMinutes = minutes < 10 ? "0\(minutes)" : "\(minutes)"
        return "\(hours):\(paddedMinutes):\(paddedSeconds)"
    }

    private static func clamp(_ seconds: Double) -> Int? {
        guard seconds.isFinite, seconds >= 0, seconds <= Double(maxSeconds) else { return nil }
        return Int(seconds.rounded())
    }
}
