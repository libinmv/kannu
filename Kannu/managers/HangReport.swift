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

/// How long the watchdog waits before it calls the main thread hung.
///
/// The ping is cheap on purpose: one timer wake every two seconds and a block posted to the main
/// queue, which is roughly 40× less work than the 20 Hz hover poll the app already runs whenever a
/// hidden island is on screen.
enum HangWatchdogSpec {
    /// How often the watchdog posts a token to the main queue.
    static let pingInterval: TimeInterval = 2

    /// How long an unanswered token means "hung". Five seconds is past every legitimate main-actor
    /// stall this app has (`system_profiler` on a Bluetooth connect is the longest at 2-8 s, which
    /// is why that one is noted rather than reported), and well short of the user's patience.
    static let hangThreshold: TimeInterval = 5

    /// True once the main queue has been silent long enough to report.
    static func isHung(unansweredFor age: TimeInterval) -> Bool { age >= hangThreshold }
}

/// One recorded freeze: how long the main thread was unreachable, what it was doing, and on which
/// build. Written to `~/Library/Logs/Kannu/` during the hang and offered to the user on the next
/// launch.
///
/// Pure by design — the file format, the scrubbing and the issue URL are all testable without a
/// running app, because the part that cannot be tested (walking a wedged thread's stack) should be
/// as small as possible.
struct HangReport: Equatable {
    /// Seconds the main queue went unanswered.
    var duration: TimeInterval
    var recordedAt: Date
    var appVersion: String
    var buildNumber: String
    var systemVersion: String
    var architecture: String
    /// The main thread's frames, outermost last, already symbolised. May be empty: a stack is the
    /// best case, and a report that only says "it froze for 12 seconds" is still worth having.
    var frames: [String]

    // MARK: - Scrubbing

    /// Removes anything that identifies the machine or the person. See `DiagnosticScrub`.
    static func scrub(_ text: String, home: String) -> String {
        DiagnosticScrub.paths(in: text, home: home)
    }

    // MARK: - The log file

    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    private static let stampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// `hang-2026-09-12-151031.txt`, sortable by name because that is how the newest one is found.
    static func fileName(for date: Date) -> String {
        "hang-\(fileStampFormatter.string(from: date)).txt"
    }

    static func isHangLogName(_ name: String) -> Bool {
        name.hasPrefix("hang-") && name.hasSuffix(".txt")
    }

    /// The file written during the hang. Plain text, one `key: value` header per line, then the
    /// stack — readable by the user before they decide to send anything.
    var fileContents: String {
        var lines = [
            "Kannu hang report",
            "recorded: \(Self.stampFormatter.string(from: recordedAt))",
            "duration: \(String(format: "%.1f", duration))s",
            "app: \(appVersion) (\(buildNumber))",
            "macos: \(systemVersion)",
            "arch: \(architecture)",
            "",
            frames.isEmpty ? "main thread stack: unavailable" : "main thread stack:"
        ]
        lines.append(contentsOf: frames)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads back a file this type wrote. Returns nil for anything else, including a truncated
    /// write — a report written while the app was wedged can be cut short if it is force-quit.
    static func parse(fileContents text: String) -> HangReport? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "Kannu hang report" else { return nil }

        func value(_ key: String) -> String? {
            guard let line = lines.first(where: { $0.hasPrefix("\(key): ") }) else { return nil }
            return String(line.dropFirst(key.count + 2))
        }

        guard let recordedText = value("recorded"), let recordedAt = stampFormatter.date(from: recordedText),
              let durationText = value("duration"), durationText.hasSuffix("s"),
              let duration = Double(durationText.dropLast()),
              let appLine = value("app"),
              let systemVersion = value("macos"),
              let architecture = value("arch")
        else { return nil }

        // "1.3.0 (3)"
        let appParts = appLine.split(separator: " ", maxSplits: 1)
        let appVersion = String(appParts.first ?? "")
        let buildNumber = appParts.count > 1
            ? String(appParts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            : ""

        var frames: [String] = []
        if let stackIndex = lines.firstIndex(of: "main thread stack:") {
            frames = lines[(stackIndex + 1)...].filter { !$0.isEmpty }
        }

        return HangReport(
            duration: duration,
            recordedAt: recordedAt,
            appVersion: appVersion,
            buildNumber: buildNumber,
            systemVersion: systemVersion,
            architecture: architecture,
            frames: frames
        )
    }

    // MARK: - What the user is shown next launch

    /// "Kannu froze for 12 seconds last time it ran."
    var alertMessage: String {
        "Kannu froze for \(Self.spokenDuration(duration)) last time it ran."
    }

    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let whole = max(1, Int(seconds.rounded()))
        if whole < 60 { return whole == 1 ? "1 second" : "\(whole) seconds" }
        let minutes = whole / 60
        let rest = whole % 60
        let minutePart = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        if rest == 0 { return minutePart }
        return "\(minutePart) \(rest == 1 ? "1 second" : "\(rest) seconds")"
    }

    // MARK: - The report the user can send

    var issueTitle: String {
        "Kannu froze for \(Self.spokenDuration(duration)) (\(appVersion))"
    }

    /// GitHub rejects a URL much over 8 KB, so the stack is trimmed from the bottom — the frames
    /// nearest the wedge are at the top and are the ones worth keeping.
    ///
    /// Budgeted against the *raw* body, while what has to fit is the percent-encoded one: every
    /// space becomes `%20` and every newline `%0A`, so a stack inflates by roughly a third. The
    /// figure allows for that; `issueURL` checks the finished URL as well rather than trusting it.
    static let issueBodyLimit = 4200

    /// Comfortably inside what GitHub accepts, and inside what Safari and Chrome will open.
    static var issueURLLimit: Int { GitHubIssue.urlLengthLimit }

    var issueBody: String {
        var body = """
        **What happened:** Kannu's interface stopped responding for \(Self.spokenDuration(duration)).

        <!-- Please add what you were doing at the time; the stack below is all Kannu could see. -->

        | | |
        | --- | --- |
        | Kannu | \(appVersion) (\(buildNumber)) |
        | macOS | \(systemVersion) |
        | Architecture | \(architecture) |
        | Frozen for | \(String(format: "%.1f", duration))s |

        """
        if frames.isEmpty {
            body += "\nKannu could not read the main thread's stack for this freeze.\n"
            return body
        }
        body += "\n<details><summary>Main thread</summary>\n\n```\n"
        var stack = ""
        for frame in frames {
            if body.count + stack.count + frame.count + 32 > Self.issueBodyLimit {
                stack += "… trimmed\n"
                break
            }
            stack += frame + "\n"
        }
        body += stack + "```\n\n</details>\n"
        return body
    }

    /// `https://github.com/<repository>/issues/new?title=…&body=…`, percent-encoded.
    ///
    /// Kannu never posts this itself: the link opens the browser with the fields filled in, the
    /// user reads it, and the user presses Submit.
    func issueURL(repository: String) -> URL? {
        Self.issueURL(repository: repository, title: issueTitle, body: issueBody, label: "hang")
            ?? Self.issueURL(repository: repository, title: issueTitle, body: stacklessIssueBody, label: "hang")
    }

    /// The body when even a trimmed stack will not fit in a URL. The log file is named, so the user
    /// can still attach it.
    private var stacklessIssueBody: String {
        """
        **What happened:** Kannu's interface stopped responding for \(Self.spokenDuration(duration)).

        | | |
        | --- | --- |
        | Kannu | \(appVersion) (\(buildNumber)) |
        | macOS | \(systemVersion) |
        | Architecture | \(architecture) |
        | Frozen for | \(String(format: "%.1f", duration))s |

        The stack was too long to carry in a link. It is in `~/Library/Logs/Kannu/` — please attach
        the newest `hang-*.txt`.
        """
    }

    static func issueURL(repository: String, title: String, body: String, label: String) -> URL? {
        GitHubIssue.url(repository: repository, title: title, body: body, label: label)
    }
}
