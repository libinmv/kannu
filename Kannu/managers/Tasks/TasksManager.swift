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
import Defaults
import Foundation
import os

/// The user's tasks, their order and estimates, and the actual time recorded when one is timed with
/// Kannu's timer.
///
/// **Lazy.** Nothing creates this at launch: the first touch is Brain › Tasks with tasks turned on,
/// so `continueLaunch()` and the Terms gate are untouched (`LaunchGateRulesTests`). Creating it
/// reads `tasks.json` on `TaskFileStore`, off the main actor.
///
/// **How time is recorded.** `start(_:)` starts an ordinary timer session and remembers which task
/// it is for. From then on `TimerManager.sessionEvents` drives everything: started opens a segment,
/// paused closes it, resumed opens another, ended closes it and unlinks. Each segment edge uses the
/// event's own date. It never reads `$isTimerActive` or `$isPaused` (docs/REGRESSIONS.md entry 10;
/// `TimerSessionEventRulesTests` pins that). Every way of stopping the timer — the notch, the
/// popover, the control overlay, the lock-screen widget — ends the task's time the same way,
/// because they all end the session.
@MainActor
final class TasksManager: ObservableObject {
    static let shared = TasksManager()

    enum LoadState: Equatable {
        case loading
        case ready
        /// The file is there but could not be read. Nothing is saved over it.
        case failed(String)
    }

    struct Timing: Equatable {
        let taskID: UUID
        var isPaused: Bool
    }

    /// A segment left open by a quit or a crash, with its task.
    struct InterruptedSession: Identifiable {
        let task: TaskItem
        let segment: WorkSegment
        var id: UUID { segment.id }
    }

    /// Every task, in the user's order. Done, hidden and gone tasks keep their place.
    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var drafts: [WorklogDraft] = []
    @Published private(set) var loadState: LoadState = .loading
    /// The task being timed right now, if any.
    @Published private(set) var timing: Timing?
    /// Set when the file could not be decoded and was moved aside: names the kept copy.
    @Published private(set) var movedAsideFileName: String?

    private struct Link {
        let session: UUID
        let taskID: UUID
        var isPaused: Bool
    }

    private let store: TaskFileStore
    private let logger = os.Logger(subsystem: "com.kannu.app", category: "Tasks")
    private var cancellables = Set<AnyCancellable>()
    /// The session `start(_:)` just began, until its `.started` event arrives.
    private var pendingLink: (session: UUID, taskID: UUID)?
    private var link: Link? {
        didSet { timing = link.map { Timing(taskID: $0.taskID, isPaused: $0.isPaused) } }
    }
    private var isAsleep = false
    private var sleepObservers: [NSObjectProtocol] = []
    private var terminateObserver: NSObjectProtocol?
    private var revision = 0
    private var savedRevision = 0

    private init() {
        store = TaskFileStore(directory: { AppSupportPaths.child("Tasks") })
        TimerManager.shared.sessionEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }
            .store(in: &cancellables)
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveBeforeQuit() }
        }
        Task { await load() }
    }

    // MARK: - What the views read

    var isReady: Bool { loadState == .ready }

    /// The task order, top first.
    var activeTasks: [TaskItem] { TaskOrdering.active(tasks) }

    var doneAndHiddenTasks: [TaskItem] { tasks.filter { $0.visibility != .active } }

    /// Segments left open by a quit or a crash, newest first, with their task.
    var interruptedSessions: [InterruptedSession] {
        tasks.flatMap { task in task.segments.filter(\.isInterrupted).map { InterruptedSession(task: task, segment: $0) } }
            .sorted { $0.segment.start > $1.segment.start }
    }

    func trackedSeconds(of task: TaskItem, now: Date = Date()) -> Int {
        TaskTimeMath.trackedSeconds(task.segments, now: now)
    }

    // MARK: - Timing

    /// Times the task with Kannu's timer, for what is left of its estimate (or the default session
    /// length). A session already running is replaced, and its own task's time ends with it.
    func start(_ taskID: UUID) {
        guard isReady, Defaults[.enableTimerFeature], timing?.taskID != taskID,
              let task = tasks.first(where: { $0.id == taskID }), task.visibility == .active else { return }
        let length = TaskTimeMath.sessionLengthSeconds(
            estimate: task.effectiveEstimateSeconds,
            tracked: trackedSeconds(of: task),
            defaultMinutes: Defaults[.tasksDefaultSessionMinutes]
        )
        let typed = task.remote.map { "\($0.key) \(task.title)" } ?? task.title
        let fallback = TimerSessionName.resolved(typed: task.title, fallback: String(localized: "Task"))
        let timer = TimerManager.shared
        timer.startTimer(
            duration: TimeInterval(length),
            name: TimerSessionName.resolved(typed: typed, fallback: fallback),
            fallbackName: fallback,
            playsSoundOnFinish: Defaults[.tasksSoundAtEstimate]
        )
        // The id is minted inside startTimer; its .started event is already queued behind this.
        pendingLink = (timer.sessionID, taskID)
    }

    /// Stops the timer when it is timing a task. The session's `.ended` closes the task's time.
    func stopTiming() {
        guard let link, TimerManager.shared.sessionID == link.session, TimerManager.shared.hasManualTimerRunning else { return }
        TimerManager.shared.forceStopTimer()
    }

    private func handle(_ event: TimerSessionEvent) {
        switch event.kind {
        case .started:
            guard let pending = pendingLink, pending.session == event.session else { return }
            pendingLink = nil
            guard isReady, tasks.contains(where: { $0.id == pending.taskID }) else { return }
            link = Link(session: event.session, taskID: pending.taskID, isPaused: false)
            observeSleep()
            update(pending.taskID) { $0.segments = TaskTimeMath.opening($0.segments, at: event.at) }
        case .paused:
            guard var current = link, current.session == event.session else { return }
            current.isPaused = true
            link = current
            close(current.taskID, at: event.at)
        case .resumed:
            guard var current = link, current.session == event.session else { return }
            current.isPaused = false
            link = current
            // Asleep, the wake opens it; a resume never records time the Mac spent sleeping.
            guard !isAsleep else { return }
            update(current.taskID) { $0.segments = TaskTimeMath.opening($0.segments, at: event.at) }
        case .ended:
            if pendingLink?.session == event.session { pendingLink = nil }
            guard let current = link, current.session == event.session else { return }
            unlink()
            close(current.taskID, at: event.at)
        }
    }

    private func unlink() {
        link = nil
        isAsleep = false
        let center = NSWorkspace.shared.notificationCenter
        for observer in sleepObservers { center.removeObserver(observer) }
        sleepObservers = []
    }

    /// Sleep closes the segment and wake opens a new one, without pausing the timer: the timer
    /// behaves exactly as it does for a session with no task. Observed only while a task is timed.
    private func observeSleep() {
        guard sleepObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemWillSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemDidWake() }
            },
        ]
    }

    private func systemWillSleep() {
        guard let link, !isAsleep else { return }
        isAsleep = true
        if !link.isPaused { close(link.taskID, at: Date()) }
    }

    private func systemDidWake() {
        guard let link, isAsleep else { return }
        isAsleep = false
        if !link.isPaused {
            update(link.taskID) { $0.segments = TaskTimeMath.opening($0.segments, at: Date()) }
        }
    }

    /// Closes the task's live segment and offers the finished time for logging where that applies.
    private func close(_ taskID: UUID, at date: Date) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        var task = tasks[index]
        task.segments = TaskTimeMath.closing(task.segments, at: date)
        let folded = WorklogDrafts.folding(task, into: drafts)
        tasks[index] = folded.task
        drafts = folded.drafts
        persist()
    }

    // MARK: - Editing

    @discardableResult
    func addTask(title: String, estimateSeconds: Int?) -> Bool {
        guard isReady, let title = TaskItem.cleanedTitle(title) else { return false }
        let task = TaskItem(title: title, localEstimateSeconds: estimateSeconds.flatMap { $0 > 0 ? $0 : nil })
        tasks = TaskOrdering.inserting(task, into: tasks)
        persist()
        return true
    }

    /// Nil, or zero, removes the estimate.
    func setEstimate(_ seconds: Int?, for taskID: UUID) {
        update(taskID) { $0.localEstimateSeconds = seconds.flatMap { $0 > 0 ? $0 : nil } }
    }

    /// Records `seconds` of work that ended now, for time worked away from the timer.
    func addManualTime(_ seconds: Int, to taskID: UUID, endingAt end: Date = Date()) {
        guard seconds > 0, let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        var task = tasks[index]
        task.segments.append(WorkSegment(start: end.addingTimeInterval(-TimeInterval(seconds)), end: end, origin: .manual))
        let folded = WorklogDrafts.folding(task, into: drafts)
        tasks[index] = folded.task
        drafts = folded.drafts
        persist()
    }

    func moveToTop(_ taskID: UUID) { reorder { TaskOrdering.movingToTop(taskID, in: $0) } }
    func moveUp(_ taskID: UUID) { reorder { TaskOrdering.movingUp(taskID, in: $0) } }
    func moveDown(_ taskID: UUID) { reorder { TaskOrdering.movingDown(taskID, in: $0) } }

    func move(activeOffsets: IndexSet, toActiveOffset destination: Int) {
        reorder { TaskOrdering.moving(activeOffsets: activeOffsets, toActiveOffset: destination, in: $0) }
    }

    /// Marking the task being timed done stops the timer first, which ends its time.
    func markDone(_ taskID: UUID) {
        if timing?.taskID == taskID { stopTiming() }
        update(taskID) { $0.visibility = .done }
    }

    /// Back into the task order, where it was.
    func reopen(_ taskID: UUID) {
        update(taskID) { $0.visibility = .active }
    }

    /// Local tasks only, and never the one being timed.
    func delete(_ taskID: UUID) {
        guard isReady, timing?.taskID != taskID, pendingLink?.taskID != taskID,
              let task = tasks.first(where: { $0.id == taskID }), task.source == .local else { return }
        tasks.removeAll { $0.id == taskID }
        drafts.removeAll { $0.taskID == taskID }
        persist()
    }

    /// Ends an interrupted session where the user says it ended: never before it started, never in
    /// the future.
    func setEndTime(_ end: Date, segmentID: UUID, taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }),
              let segmentIndex = tasks[index].segments.firstIndex(where: { $0.id == segmentID && $0.isInterrupted }) else { return }
        var task = tasks[index]
        let start = task.segments[segmentIndex].start
        task.segments[segmentIndex].end = min(max(start, end), max(start, Date()))
        let folded = WorklogDrafts.folding(task, into: drafts)
        tasks[index] = folded.task
        drafts = folded.drafts
        persist()
    }

    func discardInterruptedSession(segmentID: UUID, taskID: UUID) {
        update(taskID) { task in task.segments.removeAll { $0.id == segmentID && $0.isInterrupted } }
    }

    private func update(_ taskID: UUID, _ change: (inout TaskItem) -> Void) {
        guard isReady, let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        change(&tasks[index])
        persist()
    }

    private func reorder(_ change: ([TaskItem]) -> [TaskItem]) {
        guard isReady else { return }
        let reordered = change(tasks)
        guard reordered != tasks else { return }
        tasks = reordered
        persist()
    }

    // MARK: - Loading and saving

    private func load() async {
        switch await store.load() {
        case .empty:
            apply(.empty)
        case .loaded(let file):
            apply(file)
        case .movedAside(let name):
            logger.error("tasks.json did not decode; moved aside and starting empty")
            movedAsideFileName = name
            apply(.empty)
        case .failed(let reason):
            logger.error("tasks.json could not be read: \(reason, privacy: .private)")
            loadState = .failed(reason)
        }
    }

    private func apply(_ loaded: TasksFile) {
        var file = loaded
        let interrupted = file.markOpenSegmentsInterrupted()
        let normalized = WorklogDrafts.normalizedAtLoad(file.drafts)
        tasks = file.tasks
        drafts = normalized
        loadState = .ready
        logger.info("Loaded \(file.tasks.count, privacy: .public) tasks, \(interrupted, privacy: .public) interrupted sessions")
        if interrupted > 0 || normalized != file.drafts { persist() }
    }

    private var snapshot: TasksFile {
        TasksFile(tasks: tasks, drafts: drafts)
    }

    /// Saves on the store, off the main actor. Saves can land out of order; the revision lets the
    /// store drop an older one.
    private func persist() {
        guard isReady else { return }
        revision += 1
        let revision = revision
        let snapshot = snapshot
        Task { [weak self, store] in
            let outcome = await store.save(snapshot, revision: revision)
            self?.didSave(outcome, revision: revision)
        }
    }

    private func didSave(_ outcome: TaskFileStore.SaveOutcome, revision: Int) {
        switch outcome {
        case .written:
            savedRevision = max(savedRevision, revision)
        case .stale:
            break
        case .failed(let reason):
            logger.error("Saving tasks failed: \(reason, privacy: .private)")
        }
    }

    /// Kannu is quitting: the task being timed stops being timed now. The app exits before an
    /// awaited save could run, so this one small write happens here, on the quit path.
    private func saveBeforeQuit() {
        guard isReady else { return }
        var changed = false
        if let current = link {
            if !current.isPaused && !isAsleep, let index = tasks.firstIndex(where: { $0.id == current.taskID }) {
                var task = tasks[index]
                task.segments = TaskTimeMath.closing(task.segments, at: Date())
                let folded = WorklogDrafts.folding(task, into: drafts)
                tasks[index] = folded.task
                drafts = folded.drafts
                changed = true
            }
            unlink()
        }
        guard changed || savedRevision < revision else { return }
        revision += 1
        if case .failed(let reason) = store.saveImmediately(snapshot, revision: revision) {
            logger.error("Saving tasks at quit failed: \(reason, privacy: .private)")
        }
    }
}
