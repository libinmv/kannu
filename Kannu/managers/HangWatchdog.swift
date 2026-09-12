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
import Combine
import Darwin
import Defaults
import Foundation

/// Notices when the main thread stops answering, and records what it was doing.
///
/// A freeze is the one failure Kannu could not explain: there is no crash report, the app is simply
/// unreachable, and by the time the user force-quits it the evidence is gone. The picker freeze was
/// only diagnosable because a sample was taken while the process was still stuck.
///
/// So: a background thread posts a token to the main queue every two seconds. If a token goes
/// unanswered for five, the main thread is suspended just long enough to read its registers and
/// walk its frame pointers, and a report lands in `~/Library/Logs/Kannu/`. Nothing is drawn and
/// nothing is said at the time — anything drawn would have to go through the wedged thread — and on
/// the next launch the user is offered the report.
///
/// Off unless `Defaults[.hangWatchdogEnabled]`, which the Developer profile turns on at onboarding
/// and the About tab exposes for everyone else. Cost while running: one wake every two seconds and
/// a block on the main queue, which is far below the 20 Hz hover poll the app already runs whenever
/// a hidden island is on screen.
@MainActor
final class HangWatchdog {
    static let shared = HangWatchdog()
    private init() {}

    /// Frames kept per report. Deep enough to cross AppKit and SwiftUI and reach Kannu's own code.
    private static let maxFrames = 64
    /// Hang logs kept on disk, newest first.
    private static let keptReports = 10

    private var settingObserver: AnyCancellable?
    private var worker: Thread?
    private let state = WatchdogState()
    /// A send right to the main thread, taken on the main thread so it names the right one.
    private var mainThreadPort: mach_port_t = 0

    // MARK: - Lifecycle

    /// Starts the watchdog when it is on, and follows the About toggle from then on.
    func start() {
        // `options: []` on purpose: the publisher would otherwise fire once on subscription and
        // start the thread a second time.
        settingObserver = Defaults.publisher(.hangWatchdogEnabled, options: [])
            .sink { [weak self] change in
                guard let self else { return }
                if change.newValue { self.startIfEnabled() } else { self.stop() }
            }
        startIfEnabled()
    }

    private func startIfEnabled() {
        guard Defaults[.hangWatchdogEnabled], worker == nil else { return }

        mainThreadPort = mach_thread_self()
        let port = mainThreadPort
        let state = state
        let worker = Thread {
            while !Thread.current.isCancelled {
                Self.tick(state: state, mainThreadPort: port)
                Thread.sleep(forTimeInterval: HangWatchdogSpec.pingInterval)
            }
        }
        worker.name = "com.kannu.hang-watchdog"
        worker.qualityOfService = .utility
        worker.stackSize = 512 * 1024
        self.worker = worker
        worker.start()
        Logger.log("[HangWatchdog] Watching the main thread", category: .lifecycle)
    }

    /// Runs `body` without the watchdog counting the time.
    ///
    /// A dialog waiting for the user *is* a stopped main thread, on purpose, and the first live
    /// test of this watchdog reported its own alert as a freeze. Because `runModal()` now lives in
    /// exactly one place, only `ModalPresenter` has to say so — and a modal loop entered anywhere
    /// else is still reported, which is the bug this whole change is about.
    func duringExpectedStall<T>(_ body: () -> T) -> T {
        state.beginExpectedStall()
        defer { state.endExpectedStall() }
        return body()
    }

    func stop() {
        worker?.cancel()
        worker = nil
        if mainThreadPort != 0 {
            mach_port_deallocate(mach_task_self_, mainThreadPort)
            mainThreadPort = 0
        }
    }

    // MARK: - The loop (runs on the watchdog thread)

    private static func tick(state: WatchdogState, mainThreadPort: mach_port_t) {
        guard let waiting = state.outstandingPingAge() else {
            state.sendPing()
            return
        }
        guard HangWatchdogSpec.isHung(unansweredFor: waiting), state.beginReporting() else { return }

        let frames = symbolise(mainThreadProgramCounters(of: mainThreadPort))
        let home = NSHomeDirectory()
        let report = HangReport(
            duration: waiting,
            recordedAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: machineArchitecture(),
            frames: frames.map { HangReport.scrub($0, home: home) }
        )
        write(report)
        // One line, no paths and no stack: the log is for the next launch to find, not for anyone
        // watching the console during the freeze.
        Logger.log("[HangWatchdog] Main thread unresponsive for \(Int(waiting))s; report written", category: .warning)
    }

    private static func write(_ report: HangReport) {
        let directory = reportsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(HangReport.fileName(for: report.recordedAt))
            try Data(report.fileContents.utf8).write(to: url, options: .atomic)
            prune(in: directory)
        } catch {
            Logger.log("[HangWatchdog] Could not write the report: \(error.localizedDescription)", category: .error)
        }
    }

    private static func prune(in directory: URL) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter(HangReport.isHangLogName)
            .sorted(by: >)
        for stale in names.dropFirst(keptReports) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(stale))
        }
    }

    static var reportsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Kannu", isDirectory: true)
    }

    // MARK: - Reading a wedged thread's stack

    /// Return addresses for the main thread, innermost first.
    ///
    /// The thread is suspended only for the register read and the frame walk, and every memory read
    /// goes through `mach_vm_read_overwrite`, which reports a bad address instead of faulting — a
    /// watchdog that crashes the app it is watching would be worse than no watchdog. Symbolisation
    /// deliberately happens *after* the resume: `dladdr` takes the dyld lock, and taking it while
    /// the thread that may hold it is suspended would wedge the watchdog too.
    private static func mainThreadProgramCounters(of thread: mach_port_t) -> [UInt] {
        guard thread != 0, thread_suspend(thread) == KERN_SUCCESS else { return [] }
        defer { thread_resume(thread) }

        var programCounters: [UInt] = []
        var framePointer: UInt = 0

#if arch(arm64)
        var registers = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &registers) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return [] }
        programCounters.append(UInt(registers.__pc))
        // The link register holds the caller when the callee has not pushed its frame yet, so it is
        // the one frame the pointer walk can miss.
        if registers.__lr != 0 { programCounters.append(UInt(registers.__lr)) }
        framePointer = UInt(registers.__fp)
#elseif arch(x86_64)
        var registers = x86_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &registers) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, x86_THREAD_STATE64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return [] }
        programCounters.append(UInt(registers.__rip))
        framePointer = UInt(registers.__rbp)
#else
        return []
#endif

        // A frame is [saved frame pointer, return address]. Stacks grow down, so each saved pointer
        // must be strictly higher than the last or the walk has left the stack.
        while programCounters.count < maxFrames, framePointer != 0, framePointer % 8 == 0 {
            var frame: (UInt, UInt) = (0, 0)
            guard read(framePointer, into: &frame), frame.1 != 0, frame.0 > framePointer else { break }
            programCounters.append(frame.1)
            framePointer = frame.0
        }
        return programCounters
    }

    private static func read<T>(_ address: UInt, into value: inout T) -> Bool {
        let size = mach_vm_size_t(MemoryLayout<T>.size)
        var read: mach_vm_size_t = 0
        let status = withUnsafeMutablePointer(to: &value) { destination -> kern_return_t in
            mach_vm_read_overwrite(
                mach_task_self_,
                mach_vm_address_t(address),
                size,
                mach_vm_address_t(UInt(bitPattern: destination)),
                &read
            )
        }
        return status == KERN_SUCCESS && read == size
    }

    /// `12  Kannu.debug.dylib  $s5Kannu…choosePolicyFileyyF + 84`.
    ///
    /// Swift names stay mangled — there is no public demangler — and `swift demangle` reads them
    /// back. The image is the file name only; the full path would carry the home folder.
    private static func symbolise(_ programCounters: [UInt]) -> [String] {
        programCounters.enumerated().map { index, programCounter in
            var info = Dl_info()
            guard let pointer = UnsafeRawPointer(bitPattern: programCounter),
                  dladdr(pointer, &info) != 0
            else {
                return String(format: "%2d  ???                0x%016lx", index, programCounter)
            }
            let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
            let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
            let offset = programCounter &- UInt(bitPattern: info.dli_saddr)
            return String(format: "%2d  %@  %@ + %lu", index, image, symbol, offset)
        }
    }

    private static func machineArchitecture() -> String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }

    // MARK: - The offer, on the next launch

    /// Shows the newest unreported freeze, once. Called after launch has settled, never during it:
    /// an alert with no window to hang from is app-modal, and one of those inside
    /// `applicationDidFinishLaunching` would stop the rest of startup.
    func offerNewestReport() {
        guard Defaults[.hangWatchdogEnabled],
              let (url, report) = Self.newestReport(),
              Defaults[.lastOfferedHangReport] != url.lastPathComponent
        else { return }

        Defaults[.lastOfferedHangReport] = url.lastPathComponent

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = report.alertMessage
        alert.informativeText = String(localized: """
            Kannu wrote down what its main thread was doing. Nothing has been sent anywhere. \
            Reporting it opens a GitHub issue with the details filled in, for you to read and submit.
            """)
        alert.addButton(withTitle: String(localized: "Report It"))
        alert.addButton(withTitle: String(localized: "Show the Log"))
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

    static func newestReport() -> (URL, HangReport)? {
        let directory = reportsDirectory
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter(HangReport.isHangLogName)
            .sorted(by: >)
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let report = HangReport.parse(fileContents: text)
            else { continue }
            return (url, report)
        }
        return nil
    }
}

/// The token exchange between the watchdog thread and the main queue.
///
/// Deliberately a plain lock around three fields: it is read on the watchdog thread while the main
/// thread may be wedged, so it must not touch anything that needs the main actor.
private final class WatchdogState: @unchecked Sendable {
    private let lock = NSLock()
    private var pingSentAt: Date?
    private var reportedThisHang = false
    private var suspendDepth = 0

    /// How long the outstanding token has gone unanswered, or nil when none is in flight.
    func outstandingPingAge() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard suspendDepth == 0, let pingSentAt else { return nil }
        return Date().timeIntervalSince(pingSentAt)
    }

    func sendPing() {
        lock.lock()
        guard suspendDepth == 0 else { lock.unlock(); return }
        pingSentAt = Date()
        lock.unlock()

        // Not `DispatchQueue.main.async`: the main queue is not drained while a nested run loop is
        // turning, so a context menu the user leaves open would read as a freeze. A run-loop block
        // in the tracking modes answers from menus, drags and window resizes alike.
        //
        // `NSModalPanelRunLoopMode` is deliberately absent. A modal session Kannu opened on purpose
        // is bracketed by `duringExpectedStall`; one entered anywhere else is the freeze that
        // started all of this, and it must still be reported.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), Self.pongModes) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pingSentAt = nil
            self.reportedThisHang = false
            self.lock.unlock()
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private static let pongModes: CFArray = [
        CFRunLoopMode.commonModes.rawValue as String,
        "NSEventTrackingRunLoopMode"
    ] as CFArray

    /// Nested count, because one expected stall can sit inside another (an alert raised from a
    /// sheet's completion).
    func beginExpectedStall() {
        lock.lock()
        suspendDepth += 1
        pingSentAt = nil
        lock.unlock()
    }

    func endExpectedStall() {
        lock.lock()
        suspendDepth = max(0, suspendDepth - 1)
        pingSentAt = nil
        reportedThisHang = false
        lock.unlock()
    }

    /// True the first time a given hang crosses the threshold, so one freeze writes one report.
    func beginReporting() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !reportedThisHang else { return false }
        reportedThisHang = true
        return true
    }
}
