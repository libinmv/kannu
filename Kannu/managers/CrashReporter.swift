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

import AppKit
import Defaults
import Foundation

/// Notices that Kannu died last time, and gives the user a way to say so.
///
/// Until now Kannu never knew: no handler was installed, and the one "Copy Latest Crash Report"
/// button filtered for `.crash`, an extension macOS stopped writing in 12 — so it found nothing on
/// any modern Mac and users could only report "it crashes sometimes".
///
/// macOS already writes the evidence, into `~/Library/Logs/DiagnosticReports` and
/// `/Library/Logs/DiagnosticReports`. This reads the newest one about Kannu, trims and scrubs it
/// (`CrashReport`), and offers it. Kannu never sends anything: the button opens a GitHub issue with
/// the details filled in, and the user reads it and presses Submit.
///
/// **No signal handlers.** Catching a Swift trap safely means async-signal-safe code inside a
/// handler, and macOS's own report covers the same ground without that risk. An `NSException` handler
/// is safe and is installed, because the exception's reason is the one thing the system report can
/// bury.
///
/// **No MetricKit**, deliberately: `MXDiagnosticPayload` arrives on macOS's own schedule (often a day
/// later, often not at all for an app that is not from the App Store) and carries the same crash the
/// `.ips` already has, which this reads directly.
@MainActor
final class CrashReporter {
    static let shared = CrashReporter()
    private init() {}

    private static let searchPaths = [
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/DiagnosticReports"),
        URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")
    ]

    /// Written at launch, removed on a clean quit. Still there next time means the last run ended
    /// badly — but a user force-quitting a frozen app leaves the same trace, so this only writes a
    /// log line. What the user is actually offered comes from macOS's own report, which is evidence
    /// rather than inference.
    private static var runMarker: URL {
        HangWatchdog.reportsDirectory.appendingPathComponent("last-run.marker")
    }

    // MARK: - Lifecycle

    func start() {
        let endedBadly = FileManager.default.fileExists(atPath: Self.runMarker.path)
        if endedBadly {
            Logger.log("[CrashReporter] The previous run did not exit cleanly", category: .warning)
        }
        try? FileManager.default.createDirectory(
            at: HangWatchdog.reportsDirectory,
            withIntermediateDirectories: true
        )
        try? Data("\(Date())".utf8).write(to: Self.runMarker, options: .atomic)
        installExceptionHandler()
    }

    /// Called from `applicationWillTerminate`, so a clean quit leaves no marker.
    func noteCleanExit() {
        try? FileManager.default.removeItem(at: Self.runMarker)
    }

    /// An uncaught `NSException` aborts the process, which macOS reports — but its `reason` is the
    /// part that explains the bug and it is not always in that report. Written, never sent.
    private func installExceptionHandler() {
        // The handler is a C function pointer, so it can capture nothing and works out its own
        // paths. That is also why it stays this short.
        NSSetUncaughtExceptionHandler { exception in
            let home = NSHomeDirectory()
            let directory = URL(fileURLWithPath: home)
                .appendingPathComponent("Library/Logs/Kannu", isDirectory: true)
            let text = ([
                "Kannu uncaught exception",
                "name: \(exception.name.rawValue)",
                "reason: \(exception.reason ?? "none")",
                ""
            ] + exception.callStackSymbols).joined(separator: "\n")
            let url = directory.appendingPathComponent("exception-\(Int(Date().timeIntervalSince1970)).txt")
            try? Data(DiagnosticScrub.paths(in: text, home: home).utf8).write(to: url, options: .atomic)
        }
    }

    // MARK: - Finding what macOS wrote

    /// The newest diagnostic about Kannu, with its file name, or nil.
    ///
    /// Both directories are read; `/Library/...` is where resource reports land and the home one is
    /// where crashes land. A directory Kannu may not read is skipped rather than failing the lookup.
    static func newestReport() -> (url: URL, report: CrashReport)? {
        let manager = FileManager.default
        let home = NSHomeDirectory()
        let host = ProcessInfo.processInfo.hostName

        var candidates: [(URL, Date)] = []
        for directory in searchPaths {
            guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where CrashReport.isDiagnostic(fileName: name) {
                let url = directory.appendingPathComponent(name)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                candidates.append((url, modified))
            }
        }

        for (url, _) in candidates.sorted(by: { $0.1 > $1.1 }) {
            guard let contents = try? String(contentsOf: url, encoding: .utf8),
                  let report = CrashReport.parse(
                      fileName: url.lastPathComponent,
                      contents: contents,
                      home: home,
                      hostName: host
                  )
            else { continue }
            return (url, report)
        }
        return nil
    }

    // MARK: - The offer

    /// Offers the newest un-offered diagnostic, once. Called after launch settles, not during it: an
    /// alert with no window to hang from is app-modal, and one of those inside
    /// `applicationDidFinishLaunching` would stop the rest of startup.
    func offerNewestReport() {
        guard let (url, report) = Self.newestReport(),
              Defaults[.lastOfferedCrashReport] != url.lastPathComponent
        else { return }
        Defaults[.lastOfferedCrashReport] = url.lastPathComponent
        present(report, at: url, informative: String(localized: """
            macOS wrote a report about it. Nothing has been sent anywhere. Reporting it opens a \
            GitHub issue with the details filled in — the version, the failure and the stack, with \
            no name and nothing identifying your Mac — for you to read and submit.
            """))
    }

    /// About › "Report a problem": the same flow, on demand, whether or not anything crashed.
    func reportAProblem() {
        guard let (url, report) = Self.newestReport() else {
            if let plain = URL(string: "https://github.com/\(ReleaseInfo.repository)/issues/new") {
                NSWorkspace.shared.open(plain)
            }
            return
        }
        present(report, at: url, informative: String(localized: """
            This is the most recent report macOS wrote about Kannu. Nothing has been sent anywhere. \
            Reporting it opens a GitHub issue with the details filled in for you to read and submit.
            """))
    }

    private func present(_ report: CrashReport, at url: URL, informative: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = report.alertMessage
        alert.informativeText = informative
        alert.addButton(withTitle: String(localized: "Report It"))
        alert.addButton(withTitle: String(localized: "Show the Report"))
        alert.addButton(withTitle: String(localized: "Ignore"))

        ModalPresenter.present(alert) { response in
            switch response {
            case .alertFirstButtonReturn:
                if let issue = report.issueURL(repository: ReleaseInfo.repository) {
                    NSWorkspace.shared.open(issue)
                }
            case .alertSecondButtonReturn:
                NSWorkspace.shared.activateFileViewerSelecting([url])
            default:
                break
            }
        }
    }

    /// The text the old "Copy Latest Crash Report" button was meant to produce: the trimmed, scrubbed
    /// summary rather than the whole file, which carries the machine's identifiers.
    func copyNewestReportToPasteboard() -> Bool {
        guard let (_, report) = Self.newestReport() else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.issueBody, forType: .string)
        return true
    }
}
