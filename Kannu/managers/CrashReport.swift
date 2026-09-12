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

/// One of macOS's own diagnostics about Kannu, trimmed down to what a maintainer needs and nothing
/// that says whose Mac it came from.
///
/// Kannu never knew it had crashed: it installs no handler, and the one "Copy Latest Crash Report"
/// button filtered for `.crash`, an extension macOS stopped writing in 12. So a user could only say
/// "it crashed sometimes", which is unanswerable.
///
/// **Built from an allowlist, on purpose.** A crash report is full of things that identify a machine
/// — `crashReporterKey`, `Beta Identifier`, the resource coalition, the user id, the host name in its
/// own file name — and a blocklist publishes whatever nobody thought of. So this type reads only the
/// fields it names and the rest never reaches the output. `DiagnosticScrub` is the second layer, for
/// the text that does get through.
struct CrashReport: Equatable {

    enum Kind: String, Equatable {
        /// A `.ips` crash: the app was killed by a signal or an uncaught exception.
        case crash
        /// A `.cpu_resource.diag`: macOS noticed sustained CPU use. Not a crash; still a bug.
        case cpuLimit
        /// A `.hang` / `.spin` report written by the system's own hang detector.
        case hang
        case other

        var label: String {
            switch self {
            case .crash: return "crashed"
            case .cpuLimit: return "used too much CPU"
            case .hang: return "stopped responding"
            case .other: return "reported a problem"
            }
        }
    }

    var kind: Kind
    /// The diagnostic's own file name, host name removed.
    var sourceName: String
    var recordedAt: String
    var appVersion: String
    var buildNumber: String
    var systemVersion: String
    var architecture: String
    var modelCode: String
    /// "EXC_CRASH (SIGABRT) · Abort trap: 6", or the CPU line for a resource report.
    var summary: String
    /// Anything the crashing library said on its way out (`abort() called`, an assertion message).
    var messages: [String]
    /// The crashing thread, innermost first.
    var frames: [String]

    // MARK: - Reading what macOS wrote

    /// True for a diagnostic about this app, and not about something whose name merely starts the
    /// same way — `KannuHelper_…` is not Kannu.
    ///
    /// macOS uses **two** shapes for the same app, both observed on one machine: a crash is
    /// `Kannu-2026-09-12-213652.ips` and a resource report is
    /// `Kannu_2026-09-12-033808_<host>.cpu_resource.diag`. So the delimiter is `-` or `_`; requiring
    /// only `Kannu_` would reject every crash report, which is the thing this reads.
    static func isDiagnostic(fileName: String, appName: String = "Kannu") -> Bool {
        guard fileName.hasPrefix(appName) else { return false }
        guard let delimiter = fileName.dropFirst(appName.count).first,
              delimiter == "-" || delimiter == "_"
        else { return false }
        let interesting = [".ips", ".cpu_resource.diag", ".hang", ".spin", ".wakeups_resource.diag"]
        return interesting.contains { fileName.hasSuffix($0) }
    }

    /// Parses either shape macOS writes, and returns nil for anything it does not recognise — a
    /// truncated file, a format change, a report about another app.
    static func parse(fileName: String, contents: String, home: String, hostName: String) -> CrashReport? {
        let name = DiagnosticScrub.hostName(hostName, in: fileName)
        if fileName.hasSuffix(".ips") {
            return parseIPS(sourceName: name, contents: contents, home: home, hostName: hostName)
        }
        return parseTextual(sourceName: name, fileName: fileName, contents: contents, home: home, hostName: hostName)
    }

    // MARK: - `.ips`

    /// A `.ips` is two JSON documents: a one-line header, then the body.
    private static func parseIPS(sourceName: String, contents: String, home: String, hostName: String) -> CrashReport? {
        let parts = contents.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let header = json(parts[0]),
              let body = json(parts[1])
        else { return nil }

        let bundle = body["bundleInfo"] as? [String: Any] ?? [:]
        let os = body["osVersion"] as? [String: Any] ?? [:]
        let exception = body["exception"] as? [String: Any] ?? [:]
        let termination = body["termination"] as? [String: Any] ?? [:]

        var summaryParts: [String] = []
        if let type = exception["type"] as? String { summaryParts.append(type) }
        if let signal = exception["signal"] as? String { summaryParts.append("(\(signal))") }
        if let indicator = termination["indicator"] as? String { summaryParts.append("· \(indicator)") }
        else if let namespace = termination["namespace"] as? String { summaryParts.append("· \(namespace)") }

        // `asi` holds what a library said on its way out, keyed by library. Values can be long.
        var messages: [String] = []
        if let asi = body["asi"] as? [String: [String]] {
            for (library, lines) in asi.sorted(by: { $0.key < $1.key }) {
                for line in lines.prefix(4) {
                    messages.append("\(library): \(line)")
                }
            }
        }

        let scrub: (String) -> String = { DiagnosticScrub.everything(in: $0, home: home, hostName: hostName) }
        // `.map(scrub)` at the end, exactly as the textual path does: scrubbing only `messages` and
        // `frames` left the other eight fields depending on nobody ever putting a path in them,
        // which is the "a field nobody thought about" asymmetry this type promises not to have.
        return CrashReport(
            kind: .crash,
            sourceName: sourceName,
            recordedAt: (header["timestamp"] as? String) ?? (body["captureTime"] as? String) ?? "unknown",
            appVersion: (bundle["CFBundleShortVersionString"] as? String) ?? "unknown",
            buildNumber: (bundle["CFBundleVersion"] as? String) ?? "unknown",
            systemVersion: ipsSystemVersion(header: header, os: os),
            architecture: (body["cpuType"] as? String) ?? "unknown",
            modelCode: (body["modelCode"] as? String) ?? "unknown",
            summary: summaryParts.isEmpty ? "unknown failure" : summaryParts.joined(separator: " "),
            messages: messages,
            frames: ipsFrames(body: body)
        ).map(scrub)
    }

    private static func ipsSystemVersion(header: [String: Any], os: [String: Any]) -> String {
        if let train = os["train"] as? String {
            if let build = os["build"] as? String { return "\(train) (\(build))" }
            return train
        }
        return (header["os_version"] as? String) ?? "unknown"
    }

    /// The crashing thread only. Other threads are usually idle and they triple the size.
    private static func ipsFrames(body: [String: Any]) -> [String] {
        guard let threads = body["threads"] as? [[String: Any]] else { return [] }
        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        let faulting = (body["faultingThread"] as? Int)
            ?? threads.firstIndex { ($0["triggered"] as? Bool) == true }
            ?? 0
        guard threads.indices.contains(faulting),
              let frames = threads[faulting]["frames"] as? [[String: Any]]
        else { return [] }

        return frames.enumerated().prefix(maxFrames).map { index, frame in
            let imageIndex = frame["imageIndex"] as? Int
            let image = imageIndex.flatMap { images.indices.contains($0) ? images[$0] : nil }
            let imageName = (image?["name"] as? String) ?? "???"
            if let symbol = frame["symbol"] as? String {
                let location = frame["symbolLocation"] as? Int ?? 0
                return "\(index)  \(imageName)  \(symbol) + \(location)"
            }
            let offset = frame["imageOffset"] as? Int ?? 0
            return "\(index)  \(imageName)  + \(offset)"
        }
    }

    static let maxFrames = 48

    // MARK: - `.cpu_resource.diag` and friends

    /// The textual reports are `Key: value` headers, a blank line, then microstackshot data. Only
    /// the named keys are read; the stackshot body is never published — it is enormous and it names
    /// every library on the machine.
    private static func parseTextual(
        sourceName: String,
        fileName: String,
        contents: String,
        home: String,
        hostName: String
    ) -> CrashReport? {
        var header: [String: String] = [:]
        for line in contents.components(separatedBy: "\n").prefix(40) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if header[key] == nil, !key.isEmpty, !value.isEmpty { header[key] = value }
        }
        guard header["OS Version"] != nil || header["Date/Time"] != nil else { return nil }

        let version = header["Version"] ?? "unknown"
        let versionParts = version.split(separator: " ", maxSplits: 1)

        var summaryParts: [String] = []
        if let event = header["Event"] { summaryParts.append(event) }
        if let cpu = header["CPU"] { summaryParts.append("· \(cpu)") }
        if let wakeups = header["Wakeups"] { summaryParts.append("· \(wakeups)") }
        if let duration = header["Duration"] { summaryParts.append("· over \(duration)") }

        let kind: Kind
        if fileName.contains("cpu_resource") { kind = .cpuLimit }
        else if fileName.hasSuffix(".hang") || fileName.hasSuffix(".spin") { kind = .hang }
        else { kind = .other }

        let scrub: (String) -> String = { DiagnosticScrub.everything(in: $0, home: home, hostName: hostName) }
        return CrashReport(
            kind: kind,
            sourceName: sourceName,
            recordedAt: header["Date/Time"] ?? "unknown",
            appVersion: String(versionParts.first ?? "unknown"),
            buildNumber: versionParts.count > 1
                ? String(versionParts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                : "unknown",
            systemVersion: header["OS Version"] ?? "unknown",
            architecture: header["Architecture"] ?? "unknown",
            modelCode: header["Hardware Model"] ?? "unknown",
            summary: summaryParts.isEmpty ? (header["Event"] ?? "unknown event") : summaryParts.joined(separator: " "),
            messages: header["Action taken"].map { ["Action taken: \($0)"] } ?? [],
            frames: []
        ).map(scrub)
    }

    /// Applies a text transform to every field that came out of the file, so a scrub can never be
    /// forgotten on one of them.
    private func map(_ transform: (String) -> String) -> CrashReport {
        var copy = self
        copy.sourceName = transform(sourceName)
        copy.recordedAt = transform(recordedAt)
        copy.appVersion = transform(appVersion)
        copy.buildNumber = transform(buildNumber)
        copy.systemVersion = transform(systemVersion)
        copy.architecture = transform(architecture)
        copy.modelCode = transform(modelCode)
        copy.summary = transform(summary)
        copy.messages = messages.map(transform)
        copy.frames = frames.map(transform)
        return copy
    }

    private static func json(_ text: Substring) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    // MARK: - What the user is shown, and can send

    var alertMessage: String {
        switch kind {
        case .crash: return "Kannu quit unexpectedly last time it ran."
        case .cpuLimit: return "macOS reported Kannu for using too much CPU."
        case .hang: return "macOS reported Kannu for not responding."
        case .other: return "macOS wrote a diagnostic about Kannu."
        }
    }

    var issueTitle: String {
        "Kannu \(kind.label) — \(summary.prefix(70)) (\(appVersion))"
    }

    /// Budgeted against the *raw* body, while what has to fit is the percent-encoded URL — every
    /// space becomes `%20` and every newline `%0A`, so a stack inflates by about a third.
    static let issueBodyLimit = 4200

    /// The whole report a user sends. Every line here comes from a field this type named, so nothing
    /// arrives by accident.
    var issueBody: String {
        var body = """
        **What happened:** \(alertMessage)

        <!-- Please add what you were doing at the time. -->

        | | |
        | --- | --- |
        | Kannu | \(appVersion) (\(buildNumber)) |
        | macOS | \(systemVersion) |
        | Architecture | \(architecture) |
        | Mac model | \(modelCode) |
        | Reported | \(recordedAt) |
        | Diagnostic | `\(sourceName)` |
        | Failure | \(summary) |

        """
        if !messages.isEmpty {
            body += "\n```\n" + messages.joined(separator: "\n") + "\n```\n"
        }
        if frames.isEmpty {
            body += "\nNo stack was available in this report.\n"
            return body
        }
        body += "\n<details><summary>Crashing thread</summary>\n\n```\n"
        var stack = ""
        for frame in frames {
            if body.count + stack.count + frame.count + 32 > Self.issueBodyLimit {
                stack += "… trimmed\n"
                break
            }
            stack += frame + "\n"
        }
        return body + stack + "```\n\n</details>\n"
    }

    func issueURL(repository: String) -> URL? {
        let label = kind == .crash ? "crash" : "diagnostic"
        return GitHubIssue.url(repository: repository, title: issueTitle, body: issueBody, label: label)
            ?? GitHubIssue.url(repository: repository, title: issueTitle, body: stacklessIssueBody, label: label)
    }

    /// The body when even a trimmed stack will not fit in a URL. The diagnostic is named so the user
    /// can attach it.
    private var stacklessIssueBody: String {
        """
        **What happened:** \(alertMessage)

        | | |
        | --- | --- |
        | Kannu | \(appVersion) (\(buildNumber)) |
        | macOS | \(systemVersion) |
        | Architecture | \(architecture) |
        | Mac model | \(modelCode) |
        | Reported | \(recordedAt) |
        | Failure | \(summary) |

        The stack was too long to carry in a link. The report is `\(sourceName)` in
        `~/Library/Logs/DiagnosticReports` — please attach it.
        """
    }
}
