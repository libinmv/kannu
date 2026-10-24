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
/// **Lazy.** Nothing creates this at launch: the first touch is Brain › Tasks, the open notch's
/// Tasks button, the timer tab's Tasks page or task form, or a name typed in the timer tab's bar —
/// all only with tasks turned on, and never because the tab appeared — so `continueLaunch()` and
/// the Terms gate are untouched (`LaunchGateRulesTests`). Creating it reads `tasks.json` on
/// `TaskFileStore`, off the main actor.
///
/// **How time is recorded.** `start(_:)` starts an ordinary timer session and remembers which task
/// it is for. From then on `TimerManager.sessionEvents` drives everything: started opens a segment,
/// paused closes it, resumed opens another, ended closes it and unlinks. Each segment edge uses the
/// event's own date. It never reads `$isTimerActive` or `$isPaused` (docs/REGRESSIONS.md entry 10;
/// `TimerSessionEventRulesTests` pins that). Every way of stopping the timer — the notch, the
/// popover, the control overlay, the lock-screen widget — ends the task's time the same way,
/// because they all end the session.
///
/// **Sources.** Jira Cloud, GitLab and the other sources each have a `SourceSync`: a sync reads the
/// user's items and folds them into the list with `TaskMerge` (`merge(_:from:scope:at:)`), on the
/// main actor, against the list as it is then. It runs only when a page appears and the last sync is
/// over 5 minutes old, on Refresh, when the source says it changed, and right after Connect: no
/// timer, no polling, nothing at launch. The credential is read from the Keychain off the main actor
/// (`TaskCredentials`), non-interactively unless the user clicked something, and the site or server
/// it is used with is the Keychain's own, never a Defaults copy. Each source keeps its own state,
/// generation and in-flight marker, and merges only its own tasks: one failing or being slow never
/// shows on, or holds up, another.
///
/// **Ask, then log.** When timing a Jira or GitLab task ends, its unlogged time is folded into one
/// draft (`WorklogDrafts.folding`, rounded to the nearest 15 minutes) that Brain › Tasks › Time to
/// log asks about. Kannu always asks first: only `confirmWorklog`, from the user's Log, Retry or
/// Send Again, builds a write request (`WorklogConsentRulesTests`), and it saves the draft as
/// `.sending` before the request goes out, so a relaunch knows to check instead of sending twice.
@MainActor
final class TasksManager: ObservableObject, TaskSourceHost {
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
        /// When the next session on the task began, if one has: the end may not pass it
        /// (`TaskTimeMath.nextStart`). Clock-free, so the view caps it at now when it renders.
        let nextSessionStart: Date?
        var id: UUID { segment.id }
    }

    /// Every task, in the user's order. Done, hidden and gone tasks keep their place.
    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var drafts: [WorklogDraft] = []
    /// Each tag's colour, keyed by `TaskColoring.key(for:)`; saved in tasks.json with the tasks.
    @Published private(set) var tagColors: [String: TaskColor] = [:]
    @Published private(set) var loadState: LoadState = .loading
    /// The task being timed right now, if any.
    @Published private(set) var timing: Timing?
    /// Set when the file could not be decoded and was moved aside: names the kept copy.
    @Published private(set) var movedAsideFileName: String?
    /// macOS has Kannu's notifications turned off, so a schedule raises no reminder. Checked after
    /// a schedule, after the task file is read, and when the Task list opens.
    @Published private(set) var remindersBlocked = false
    /// Whether macOS denies Kannu's notifications, whatever the list wants. The task form's bell
    /// turns orange on it: `remindersBlocked` is false while every scheduled task is muted.
    @Published private(set) var notificationsDenied = false

    private struct Link {
        let session: UUID
        let taskID: UUID
        /// The tracked time `start(_:)` sized the session from, so an estimate edit can follow it
        /// (`TaskTimeMath.followedLength`). Nil for the user's own block — a preset or a typed
        /// length (`startBlock`) — which never follows the estimate.
        let trackedAtStart: Int?
        var isPaused: Bool
    }

    private let store: TaskFileStore
    private let logger = os.Logger(subsystem: "com.kannu.app", category: "Tasks")
    private var cancellables = Set<AnyCancellable>()
    /// The session `start(_:)` or `startBlock` just began, until its `.started` event arrives.
    private var pendingLink: (session: UUID, taskID: UUID, trackedAtStart: Int?)?
    /// The session timing a task, or about to (still waiting for its `.started`).
    private var timedSession: (session: UUID, taskID: UUID, trackedAtStart: Int?)? {
        link.map { (session: $0.session, taskID: $0.taskID, trackedAtStart: $0.trackedAtStart) } ?? pendingLink
    }
    private var link: Link? {
        didSet { timing = link.map { Timing(taskID: $0.taskID, isPaused: $0.isPaused) } }
    }
    private var isAsleep = false
    private var sleepObservers: [NSObjectProtocol] = []
    private var terminateObserver: NSObjectProtocol?
    /// The archive's own clock: a new day archives what waited long enough, with no sync needed.
    private var dayChangeObserver: NSObjectProtocol?
    private var revision = 0
    private var savedRevision = 0
    /// Drafts whose send is under way, so a second click cannot start another.
    private var sendsInFlight = Set<UUID>()

    /// The reminders macOS was last told about (`TaskReminderPlan.wanted`). Taken from the file at
    /// load; each save after that sends only what changed; emptied when Tasks is turned off, which
    /// takes them all back. `checkReminderPermission` checks it against what macOS actually holds.
    private var reminderBaseline: [UUID: TaskReminderPlan.Reminder] = [:]
    /// A reminder's Start clicked before the task file was read, what to do if it cannot start,
    /// and the notification's completion: tried once the file is read, or the fallback runs when
    /// it cannot be, and the completion runs after either.
    private var pendingReminderStart: (taskID: UUID, otherwise: () -> Void, completion: () -> Void)?
    /// A name typed in the timer tab started before the task file was read (`startTyped`): tried
    /// once it is read, or `otherwise` (the plain named session) runs when it cannot be. One start
    /// waits at a time, with `pendingReminderStart`: the later click wins.
    private var pendingTypedStart: (typed: String, reuse: Bool, duration: TimeInterval, preset: TimerPreset?,
                                    otherwise: () -> Void)?

    #if DEBUG
    /// DEBUG snapshot boards only (`DebugSnapshots`): the tasks the manager starts with, instead of
    /// reading tasks.json. Set before the first touch. While set, nothing is saved, synced, observed
    /// or asked of macOS, so a snapshot never writes the user's file.
    static var snapshotFile: TasksFile?
    #endif

    private init() {
        store = TaskFileStore(directory: { AppSupportPaths.child("Tasks") })
        #if DEBUG
        if let file = Self.snapshotFile {
            tasks = file.tasks
            drafts = file.drafts
            tagColors = file.tagColors
            loadState = .ready
            return
        }
        #endif
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
        // A Mac that stays up for weeks, with no source to sync, still archives on time: the closed
        // tasks' days are counted again each new day (CodeRabbit on #107).
        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshArchive() }
        }
        // What the views read through the manager depends on these data keys: the connected baseline
        // (`activeTasks`) and whether each source syncs (`SourceSync.isSyncOn`). No view
        // filter belongs here: those change what one view shows, never the data. `options: []`, so
        // subscribing does not fire.
        Publishers.MergeMany(
            TaskSource.remoteSources.compactMap(\.enabledKey).map { Defaults.publisher($0, options: []).map { _ in () }.eraseToAnyPublisher() }
                + TaskSource.remoteSources.compactMap(\.scopeKey).map { Defaults.publisher($0, options: []).map { _ in () }.eraseToAnyPublisher() }
                + [Defaults.publisher(.gitlabIncludeMergeRequests, options: []).map { _ in () }.eraseToAnyPublisher()]
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
        .store(in: &cancellables)
        // The integration colours: `color(of:)` reads them, and the timed task's colour is the
        // running timer's accent. `options: []` here too.
        Publishers.MergeMany(
            TaskSource.allCases.map { Defaults.publisher($0.colorKey, options: []).map { _ in () }.eraseToAnyPublisher() }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            MainActor.assumeIsolated {
                self?.objectWillChange.send()
                self?.refreshTimedTint()
            }
        }
        .store(in: &cancellables)
        // Tasks off: Settings takes every reminder back (`TaskReminders.withdrawAll`), so macOS holds
        // none, and the baseline must say so — or the next save would send only what changed since,
        // and the unchanged reminders would stay missing. Tasks on: they are sent again at once, and
        // the baseline is the list again, as at load — left empty, the next save would count every
        // reminder as changed and take back one that fired in between (`TaskReminderPlanTests`).
        Defaults.publisher(.enableTasks, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if change.newValue {
                        self.reminderBaseline = TaskReminderPlan.wanted(self.tasks)
                        self.checkReminderPermission()
                    } else {
                        self.reminderBaseline = [:]
                    }
                    self.updateRemindersObserver()
                }
            }
            .store(in: &cancellables)
        Defaults.publisher(.appleRemindersEnabled, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRemindersObserver() }
            }
            .store(in: &cancellables)
        Task { await load() }
    }

    // MARK: - What the views read

    var isReady: Bool { loadState == .ready }

    /// The task order, top first: every active task Kannu holds (`TaskOrdering.connectedFilter`).
    /// Sync Jira and Sync GitLab only decide what is fetched, so a paused source's tasks stay here.
    /// A view narrows this with a filter of its own: the Task list's (`listedTasks`), the notch's
    /// Show in notch (`TaskOrdering.viewFilter`).
    var activeTasks: [TaskItem] { TaskOrdering.active(tasks, listed: connected) }

    /// The connected baseline. Include merge requests is the one data setting that narrows it, and
    /// only while GitLab is connected: merge requests kept after a disconnect stay in sight.
    private var connected: TaskOrdering.Listed {
        TaskOrdering.connectedFilter(
            showGitLabMergeRequests: Defaults[.gitlabIncludeMergeRequests] || !gitlab.isConnected,
            alwaysListed: timing?.taskID
        )
    }

    /// Done and gone tasks, until `TaskArchive` archives them: Brain's Recently closed.
    var recentlyClosedTasks: [TaskItem] { tasks.filter { $0.visibility == .done || $0.visibility == .gone } }

    /// Brain's Archive: out of every other list.
    var archivedTasks: [TaskItem] { tasks.filter { $0.visibility == .archived } }

    /// The Task list's rows: the task order narrowed by its filters, which are the Task list's own.
    func listedTasks(_ filter: TaskFilter) -> [TaskItem] {
        TaskOrdering.active(tasks, listed: listed(filter))
    }

    /// What the Task list shows: the connected baseline, narrowed by the Task list's filters.
    private func listed(_ filter: TaskFilter) -> TaskOrdering.Listed {
        filter.isNarrowing ? TaskFacets.listed(connected, filter: filter) : connected
    }

    /// Segments left open by a quit or a crash, newest first, with their task.
    var interruptedSessions: [InterruptedSession] {
        tasks.flatMap { task in
            task.segments.filter(\.isInterrupted).map { segment in
                InterruptedSession(
                    task: task,
                    segment: segment,
                    nextSessionStart: TaskTimeMath.nextStart(after: segment, in: task.segments)
                )
            }
        }
        .sorted { $0.segment.start > $1.segment.start }
    }

    func trackedSeconds(of task: TaskItem, now: Date = Date()) -> Int {
        TaskTimeMath.trackedSeconds(task.segments, now: now)
    }

    // MARK: - Timing

    /// Times the task with Kannu's timer, for what is left of its estimate (or the default session
    /// length). A session already running is replaced, and its own task's time ends with it.
    /// Returns false when nothing could start: not loaded, the timer is off, or the task is gone,
    /// done or hidden. Timing the task already counts as started.
    @discardableResult
    func start(_ taskID: UUID) -> Bool {
        guard isReady, Defaults[.enableTimerFeature],
              let task = tasks.first(where: { $0.id == taskID }), task.visibility == .active else { return false }
        guard timing?.taskID != taskID else { return true }
        let tracked = trackedSeconds(of: task)
        let length = TaskTimeMath.sessionLengthSeconds(
            estimate: task.effectiveEstimateSeconds,
            tracked: tracked,
            defaultMinutes: Defaults[.tasksDefaultSessionMinutes]
        )
        // The session is named by the title alone and the key rides beside it as a chip: a raw key
        // in front ("discern_security/applications/ds-vendors#4264 …") filled the 40-character name
        // before its number, let alone the title.
        let fallback = TimerSessionName.resolved(typed: task.title, fallback: String(localized: "Task"))
        let timer = TimerManager.shared
        timer.startTimer(
            duration: TimeInterval(length),
            name: TimerSessionName.resolved(typed: task.title, fallback: fallback),
            fallbackName: fallback,
            playsSoundOnFinish: Defaults[.tasksSoundAtEstimate],
            tint: color(of: task).tint,
            taskKey: TaskDetailSummary.shortKey(for: task),
            taskID: task.id
        )
        // The id is minted inside startTimer; its .started event is already queued behind this.
        // Sized from the estimate, so the session follows its edits (`refreshTimedLength`).
        pendingLink = (timer.sessionID, taskID, tracked)
        return true
    }

    /// Times the task for `duration`, the user's own block (a preset, a typed length): it never
    /// follows the estimate and rings at zero like any preset. Named by the task's title, coloured
    /// and keyed like `start(_:)`, and replaces a running session the same way. False when nothing
    /// could start: not loaded, the timer is off, or the task is gone, done or hidden.
    @discardableResult
    func startBlock(_ taskID: UUID, duration: TimeInterval, preset: TimerPreset?) -> Bool {
        guard isReady, Defaults[.enableTimerFeature], duration > 0,
              let task = tasks.first(where: { $0.id == taskID }), task.visibility == .active else { return false }
        let fallback = TimerSessionName.resolved(typed: task.title, fallback: String(localized: "Task"))
        let timer = TimerManager.shared
        timer.startTimer(
            duration: duration,
            name: TimerSessionName.resolved(typed: task.title, fallback: fallback),
            preset: preset,
            fallbackName: fallback,
            tint: color(of: task).tint,
            taskKey: TaskDetailSummary.shortKey(for: task),
            taskID: task.id
        )
        pendingLink = (timer.sessionID, taskID, nil)
        return true
    }

    /// A name typed in the timer tab's bar, started with a preset or a typed length: the first
    /// active local task with that title when `reuse` (`TaskItem.reusable`; the New row turns it
    /// off), else the user's kept new-task draft when it is that title, else a new task with no
    /// estimate, timed as a block (`startBlock`). Before the task file is read it waits, as a
    /// reminder's Start does; `otherwise` (the plain named session) runs when no task can start.
    func startTyped(_ typed: String, reuse: Bool, duration: TimeInterval, preset: TimerPreset?,
                    otherwise: @escaping () -> Void) {
        switch loadState {
        case .loading:
            // The later click wins; a reminder's Start waiting before this one is answered.
            if let reminder = pendingReminderStart {
                pendingReminderStart = nil
                reminder.completion()
            }
            pendingTypedStart = (typed, reuse, duration, preset, otherwise)
        case .failed:
            otherwise()
        case .ready:
            if !startTypedNow(typed, reuse: reuse, duration: duration, preset: preset) { otherwise() }
        }
    }

    private func startTypedNow(_ typed: String, reuse: Bool, duration: TimeInterval, preset: TimerPreset?) -> Bool {
        guard isReady, Defaults[.enableTimerFeature], duration > 0, TaskItem.cleanedTitle(typed) != nil else { return false }
        let taskID: UUID?
        if reuse, let reused = TaskItem.reusable(titled: typed, in: tasks) {
            taskID = reused.id
        } else if let kept = keptFormDraft(editing: nil), kept.isTitled(typed), kept.canSave {
            // The bar and the New Task title are one text: the form's estimate, tags and reminder
            // come with it, and the draft is used up, so no second task is made from it later.
            taskID = addTask(from: kept)
        } else if let added = addTask(title: typed, estimateSeconds: nil) {
            showLocalTasks()
            taskID = added
        } else {
            taskID = nil
        }
        guard let taskID else { return false }
        return startBlock(taskID, duration: duration, preset: preset)
    }

    /// Stops the timer when it is timing a task. The session's `.ended` closes the task's time.
    func stopTiming() {
        guard let link, TimerManager.shared.sessionID == link.session, TimerManager.shared.hasManualTimerRunning else { return }
        TimerManager.shared.forceStopTimer()
    }

    /// Pauses the timer when it is timing a task (the notch popover's Now card). The session's
    /// `.paused` closes the task's time; nothing is offered for logging until timing ends.
    func pauseTiming() {
        guard let link, !link.isPaused, TimerManager.shared.sessionID == link.session,
              TimerManager.shared.hasManualTimerRunning else { return }
        TimerManager.shared.pauseTimer()
    }

    /// Resumes it. The session's `.resumed` opens the task's time again.
    func resumeTiming() {
        guard let link, link.isPaused, TimerManager.shared.sessionID == link.session,
              TimerManager.shared.hasManualTimerRunning else { return }
        TimerManager.shared.resumeTimer()
    }

    /// Recolours the running timer after the timed task's colour may have changed: its tags, a
    /// tag's colour, or its integration's colour. Called by those changes themselves, never from
    /// `$tasks` or `$tagColors` (docs/REGRESSIONS.md entry 10). A session still waiting for its
    /// `.started` counts as well.
    private func refreshTimedTint() {
        guard let target = timedSession,
              let task = tasks.first(where: { $0.id == target.taskID }) else { return }
        TimerManager.shared.updateSessionTint(color(of: task).tint, session: target.session)
    }

    /// Renames the running session after its task was renamed (the task form's Save).
    private func refreshTimedName(_ taskID: UUID) {
        guard let target = timedSession, target.taskID == taskID,
              let task = tasks.first(where: { $0.id == taskID }) else { return }
        TimerManager.shared.updateSessionName(
            TimerSessionName.resolved(typed: task.title, fallback: String(localized: "Task")),
            session: target.session
        )
    }

    /// The user edited the timed task's estimate (a sync never comes through here): a session
    /// `start(_:)` sized from it follows (`TaskTimeMath.followedLength`); a block, or an estimate
    /// removed or used up before the session, leaves the countdown alone.
    private func refreshTimedLength(_ taskID: UUID) {
        guard let target = timedSession, target.taskID == taskID,
              let task = tasks.first(where: { $0.id == taskID }),
              let length = TaskTimeMath.followedLength(estimate: task.effectiveEstimateSeconds,
                                                       trackedAtStart: target.trackedAtStart) else { return }
        TimerManager.shared.updateSessionLength(length, session: target.session)
    }

    private func handle(_ event: TimerSessionEvent) {
        switch event.kind {
        case .started:
            guard let pending = pendingLink, pending.session == event.session else { return }
            pendingLink = nil
            guard isReady, tasks.contains(where: { $0.id == pending.taskID }) else { return }
            link = Link(session: event.session, taskID: pending.taskID, trackedAtStart: pending.trackedAtStart,
                        isPaused: false)
            observeSleep()
            update(pending.taskID) { $0.segments = TaskTimeMath.opening($0.segments, at: event.at) }
        case .paused:
            guard var current = link, current.session == event.session else { return }
            current.isPaused = true
            link = current
            // A pause is not the end of the work: the time is offered for logging when timing ends.
            close(current.taskID, at: event.at, offeringTime: false)
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
            // Timing ended: a Jira or GitLab task's unlogged time becomes its Time to log card.
            close(current.taskID, at: event.at, offeringTime: true)
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
        if !link.isPaused { close(link.taskID, at: Date(), offeringTime: false) }
    }

    private func systemDidWake() {
        guard let link, isAsleep else { return }
        isAsleep = false
        if !link.isPaused {
            update(link.taskID) { $0.segments = TaskTimeMath.opening($0.segments, at: Date()) }
        }
    }

    /// Closes the task's live segment. With `offeringTime` (timing ended), a Jira or GitLab task's
    /// unlogged time is folded into the draft its Time to log card asks about; a pause or a sleep
    /// only closes the segment, so the card does not appear while the task is still being timed.
    private func close(_ taskID: UUID, at date: Date, offeringTime: Bool) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        var task = tasks[index]
        task.segments = TaskTimeMath.closing(task.segments, at: date)
        if offeringTime {
            let folded = WorklogDrafts.folding(task, into: drafts)
            task = folded.task
            drafts = folded.drafts
        }
        tasks[index] = task
        persist()
    }

    // MARK: - Editing

    /// A local task at the top of the order; its id, so a caller can tag, schedule or start it.
    /// Nil when there is no title or the task list cannot change.
    @discardableResult
    func addTask(title: String, estimateSeconds: Int?) -> UUID? {
        guard isReady, let title = TaskItem.cleanedTitle(title) else { return nil }
        let task = TaskItem(title: title, localEstimateSeconds: estimateSeconds.flatMap { $0 > 0 ? $0 : nil })
        tasks = TaskOrdering.inserting(task, into: tasks)
        persist()
        return task.id
    }

    /// The notch's task form's new task (`insertTask`); then the draft is used up, and a list
    /// hiding local tasks shows them again so the task does not vanish as it is added. One path for
    /// Add, Add & Start, a preset clicked with the form open, and a typed name whose title the form
    /// held. Nil when it cannot be saved.
    @discardableResult
    func addTask(from draft: TaskFormDraft) -> UUID? {
        guard let id = insertTask(from: draft) else { return nil }
        forgetFormDraft(editing: nil)
        showLocalTasks()
        return id
    }

    /// A new task as a form typed it: a local task at the top with its tags and reminder, the bell
    /// before the schedule so a muted reminder is never sent first. Brain's New Task adds through
    /// this alone, so a task half-typed in the notch stays kept and the notch's Show local stays as
    /// the user left it. Nil when it cannot be saved.
    @discardableResult
    func insertTask(from draft: TaskFormDraft) -> UUID? {
        guard draft.isNew, draft.canSave, let id = addTask(title: draft.title, estimateSeconds: draft.estimateSeconds) else {
            return nil
        }
        let tags = draft.tags
        if !tags.isEmpty { setTags(tags, for: id) }
        if draft.reminder != nil, !draft.notifies { setReminderNotifies(false, for: id) }
        if let reminder = draft.reminder { setSchedule(reminder, for: id) }
        return id
    }

    /// The task form's edit, saved: only what changed (`TaskFormDraft.edits`), each through its
    /// own edit, then the draft is forgotten. False, with nothing saved, when it cannot be saved or
    /// the task is gone; an edit that changes nothing saves as nothing.
    @discardableResult
    func applyEdits(_ draft: TaskFormDraft, to id: UUID) -> Bool {
        guard draft.editing == id, draft.canSave, let task = activeTasks.first(where: { $0.id == id }) else { return false }
        for edit in draft.edits(to: task) {
            switch edit {
            case .title(let title): renameTask(id, to: title)
            case .estimate(let seconds): setEstimate(seconds, for: id)
            case .tags(let tags): setTags(tags, for: id)
            case .notifies(let notifies): setReminderNotifies(notifies, for: id)
            case .schedule(let date): setSchedule(date, for: id)
            }
        }
        forgetFormDraft(editing: id)
        return true
    }

    /// Local tasks hidden in the notch come back when one is added, so it does not vanish as it
    /// is made. A reused or picked task is listed while it runs anyway.
    private func showLocalTasks() {
        if !Defaults[.tasksPopoverShowLocal] { Defaults[.tasksPopoverShowLocal] = true }
    }

    /// A local task's new title (`TaskItem.cleanedTitle`). A Jira or GitLab title is the server's,
    /// and the next sync would put it back, so it is never renamed here. The save sends a scheduled
    /// reminder again under the new title (`syncReminders`).
    @discardableResult
    func renameTask(_ taskID: UUID, to title: String) -> Bool {
        guard let title = TaskItem.cleanedTitle(title),
              let task = tasks.first(where: { $0.id == taskID }), task.source == .local else { return false }
        if title != task.title {
            update(taskID) { $0.title = title }
            refreshTimedName(taskID)
        }
        return true
    }

    /// Nil, or zero, removes the estimate. A running session `start(_:)` sized from the estimate
    /// follows the edit (`refreshTimedLength`).
    func setEstimate(_ seconds: Int?, for taskID: UUID) {
        update(taskID) { $0.localEstimateSeconds = seconds.flatMap { $0 > 0 ? $0 : nil } }
        refreshTimedLength(taskID)
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

    /// The task's own tags, cleaned (`TaskItem.cleanedTags`). Kannu's only: never sent anywhere.
    func setTags(_ tags: [String], for taskID: UUID) {
        update(taskID) { $0.tags = TaskItem.cleanedTags(tags) }
        refreshTimedTint()
    }

    /// A tag's colour; `.glass` when it has none.
    func tagColor(for tag: String) -> TaskColor {
        tagColors[TaskColoring.key(for: tag)] ?? .glass
    }

    /// One tag's colour, shared by every task carrying the tag. `.glass` removes the entry: it is
    /// the default and never stored.
    func setTagColor(_ color: TaskColor, for tag: String) {
        setTagColors([tag: color])
    }

    /// Several tag colours in one save, for a sheet that stages its changes until Save. Each entry
    /// is set as `setTagColor` sets it; a tag not named keeps its colour.
    func setTagColors(_ colors: [String: TaskColor]) {
        guard isReady else { return }
        var updated = tagColors
        for (tag, color) in colors {
            let key = TaskColoring.key(for: tag)
            guard !key.isEmpty else { continue }
            updated[key] = color == .glass ? nil : color
        }
        guard updated != tagColors else { return }
        tagColors = updated
        persist()
        refreshTimedTint()
    }

    /// The colour a task shows: strictly its first tag's, or its integration's when it has no tags
    /// (`TaskColoring.color`).
    func color(of task: TaskItem) -> TaskColor {
        TaskColoring.color(of: task, tagColors: tagColors, integrations: [task.source: Defaults[task.source.colorKey]])
    }

    /// Every integration's colour, read from Defaults once: a list works its rows' colours out
    /// with it (`TaskListRows`) instead of reading Defaults on every row.
    var integrationColors: [TaskSource: TaskColor] {
        Dictionary(uniqueKeysWithValues: TaskSource.allCases.map { ($0, Defaults[$0.colorKey]) })
    }

    // MARK: - Every source at once

    /// Each source whose sync is on, with where its sync stands: the notch's Refresh and its lines
    /// (`TaskSyncSummary`).
    var syncStates: [TaskSource: SourceSyncState] {
        Dictionary(uniqueKeysWithValues: syncs.filter(\.isSyncOn).map { ($0.source, $0.state) })
    }

    /// The sources whose sync is on, so a view can sync one the moment it is switched on.
    var syncOnSources: Set<TaskSource> { Set(syncStates.keys) }

    /// Whether any source is syncing now.
    var isAnySyncing: Bool { syncs.contains(where: \.isSyncing) }

    /// Each source whose last sync is stale, never with the Keychain dialog (`SourceSync.syncIfStale`).
    func syncAllIfStale() {
        #if DEBUG
        if Self.snapshotFile != nil { return }
        #endif
        for sync in syncs { sync.syncIfStale(now: Date()) }
    }

    /// The user's Refresh: every source that syncs. One that is off, syncing or rate limited is
    /// skipped; each may ask macOS for its Keychain item.
    func refreshAll() {
        for sync in syncs { sync.refresh(now: Date()) }
    }

    /// The item's page on its own site or server, checked; nil for a task with none.
    func browseURL(for task: TaskItem) -> URL? {
        switch task.source {
        case .jira: return jiraBrowseURL(for: task)
        case .gitlab: return gitlabBrowseURL(for: task)
        case .github:
            guard let remote = task.remote, let link = remote.gitlabWebURL,
                  GitHubHost.isWebURL(link, onServer: remote.hostScope) else { return nil }
            return URL(string: link)
        case .linear:
            guard let remote = task.remote, let link = remote.gitlabWebURL,
                  LinearAPI.isIssueURL(link, in: remote.hostScope) else { return nil }
            return URL(string: link)
        case .todoist:
            guard let link = task.remote?.gitlabWebURL, link.hasPrefix(TodoistAPI.taskPageBase) else { return nil }
            return URL(string: link)
        case .local, .appleReminders: return nil
        }
    }

    /// Turns one local task's reminder notification on or off; its time stays. Off keeps the task out
    /// of the reminders macOS is asked to show (`TaskReminderPlan.wanted`), and `persist` takes back
    /// one already waiting. Asks macOS nothing: only `setSchedule` may.
    func setReminderNotifies(_ notifies: Bool, for taskID: UUID) {
        guard let task = tasks.first(where: { $0.id == taskID }), task.source == .local,
              task.notifiesForReminder != notifies else { return }
        update(taskID) { $0.reminderMuted = notifies ? nil : true }
        // What the list wants changed: read macOS's answer again (it asks nothing), so the
        // "notifications are off" notes follow the bell.
        checkReminderPermission()
    }

    // MARK: - The task form's unsaved drafts

    /// The task form's drafts while it is closed (`KeptTaskFormDrafts`). In memory only.
    private var keptFormDrafts = KeptTaskFormDrafts()

    /// Bumped when a preset clicked over a new task's form could not start it because its
    /// estimate cannot be read (`TimerTaskForm.startFromForm`): the form moves focus to the estimate.
    @Published private(set) var estimateFocusRequests = 0

    func requestEstimateFocus() {
        estimateFocusRequests &+= 1
    }

    /// The unsaved draft for a new task (nil) or the task with `id`, if one is kept and still fits.
    func keptFormDraft(editing id: UUID?) -> TaskFormDraft? {
        keptFormDrafts.draft(editing: id, baseline: id.flatMap(formBaseline(for:)), now: Date(), calendar: .current)
    }

    /// Keeps the form's draft as it is typed.
    func keepFormDraft(_ draft: TaskFormDraft) {
        keptFormDrafts.keep(draft, baseline: draft.editing.flatMap(formBaseline(for:)))
    }

    /// Forgets a draft: it was added or saved, or an edit was closed without saving.
    func forgetFormDraft(editing id: UUID?) {
        keptFormDrafts.forget(editing: id)
    }

    private func formBaseline(for id: UUID) -> TaskFormDraft? {
        tasks.first { $0.id == id }.map(TaskFormDraft.init(editing:))
    }

    /// A local task's reminder time; nil clears it. The first schedule is where Kannu asks macOS
    /// for notifications — never earlier.
    func setSchedule(_ date: Date?, for taskID: UUID) {
        guard let task = tasks.first(where: { $0.id == taskID }), task.source == .local else { return }
        update(taskID) {
            $0.scheduledAt = date
            // A mute belongs to the reminder it was set on; with no reminder there is no bell to show
            // it, and a later schedule must notify.
            if date == nil { $0.reminderMuted = nil }
        }
        guard date != nil else { return }
        Task { [weak self] in
            let permission = await TaskReminders.requestPermission()
            guard let self else { return }
            notificationsDenied = permission == .denied
            // The check's own rule (`checkReminderPermission`): blocked only while something wants
            // to notify. `persist` has already set the baseline to what the list wants, so a muted
            // reminder re-timed while macOS denies notifications turns nothing orange.
            remindersBlocked = permission == .denied && !reminderBaseline.isEmpty
            if permission == .allowed { resendReminders() }
        }
    }

    /// Whether macOS still lets the reminders show, and whether it holds the ones the list wants.
    /// Asks nothing. Judged from what macOS reports, not from the file: requests for tasks that
    /// are gone (or for everything, with tasks off) are taken back, and, while notifications are
    /// allowed, every wanted reminder still ahead is sent again, so one macOS holds with an older
    /// date is replaced. Runs after the task file is read, when Tasks is turned on and whenever
    /// the Task list opens — after any `withdrawAll` asked for before it, so a removal computed
    /// from an earlier snapshot never takes back what this resend sends.
    func checkReminderPermission() {
        guard isReady else { return }
        #if DEBUG
        if Self.snapshotFile != nil { return }
        #endif
        TaskReminders.serially { [weak self] in
            let permission = await TaskReminders.permission()
            let held = await TaskReminders.held()
            guard let self, isReady else { return }
            let wanted = Defaults[.enableTasks] ? TaskReminderPlan.wanted(tasks) : [:]
            notificationsDenied = permission == .denied
            remindersBlocked = permission == .denied && !wanted.isEmpty
            TaskReminders.apply(TaskReminderPlan.reconcile(
                pending: held.pending, delivered: held.delivered, wanted: wanted,
                now: Date(), canAdd: permission == .allowed
            ))
        }
    }

    /// Start, on a task's reminder: the user's click. Before the task file is read, it waits for
    /// it. When the task cannot start — the timer is off, the task is gone, or the file could not
    /// be read — `otherwise` runs, so the click is never silently lost. `completion` is the
    /// notification's own, and runs once the click has been answered: after the start, the
    /// fallback, or the load's failure — never before.
    func startFromReminder(_ taskID: UUID, otherwise: @escaping () -> Void, completion: @escaping () -> Void) {
        switch loadState {
        case .loading:
            // A second click before the file is read replaces the first, whose notification is done;
            // a typed start waiting before it gives way too (the later click wins).
            pendingTypedStart = nil
            pendingReminderStart?.completion()
            pendingReminderStart = (taskID, otherwise, completion)
        case .failed:
            otherwise()
            completion()
        case .ready:
            if !start(taskID) { otherwise() }
            completion()
        }
    }

    /// Marking the task being timed done stops the timer first, which ends its time. Done tasks
    /// are Recently closed until `TaskArchive` archives them.
    func markDone(_ taskID: UUID) {
        if timing?.taskID == taskID { stopTiming() }
        update(taskID) {
            $0.visibility = .done
            $0.closedAt = Date()
        }
    }

    /// Into the archive at once, whatever the source: for a remote task this is its delete, since
    /// a deleted one would only come back on the next sync. Stops the timer first if it is timed.
    /// It stays archived even if its source lists it again; Restore puts it back.
    func archive(_ taskID: UUID) {
        if timing?.taskID == taskID { stopTiming() }
        update(taskID) {
            $0.visibility = .archived
            $0.archivedAt = Date()
            $0.archivedByUser = true
        }
    }

    /// Out of the archive or Recently closed, back into the task order where it was. A remote
    /// task its source no longer lists goes back to Recently closed at the next complete sync.
    func reopen(_ taskID: UUID) {
        update(taskID) {
            $0.visibility = .active
            $0.closedAt = nil
            $0.archivedAt = nil
            $0.archivedByUser = false
        }
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
    /// the future, and never past the start of a later session on the task, so work timed again
    /// after a crash is not counted twice.
    func setEndTime(_ end: Date, segmentID: UUID, taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }),
              let segmentIndex = tasks[index].segments.firstIndex(where: { $0.id == segmentID && $0.isInterrupted }) else { return }
        var task = tasks[index]
        let segment = task.segments[segmentIndex]
        let bound = TaskTimeMath.endBound(for: segment, in: task.segments, now: Date())
        task.segments[segmentIndex].end = min(max(segment.start, end), bound)
        let folded = WorklogDrafts.folding(task, into: drafts)
        tasks[index] = folded.task
        drafts = folded.drafts
        persist()
    }

    func discardInterruptedSession(segmentID: UUID, taskID: UUID) {
        update(taskID) { task in task.segments.removeAll { $0.id == segmentID && $0.isInterrupted } }
    }

    /// `TaskArchive` over the list as it is now, after a sync. True when something changed (the
    /// caller saves). The task being timed, or about to be, is never archived or cleared.
    /// The archive's clock outside a sync: when Brain's Task list appears and when the day changes.
    /// Archives what waited `TaskArchive.closedDays`, and clears archived remote tasks after
    /// `TaskArchive.clearDays`. Before, only a launch or a Jira or GitLab sync did: a local-only user's
    /// done tasks sat in Recently closed, "archiving now", until the next launch.
    func refreshArchive(now: Date = Date()) {
        guard isReady else { return }
        let timed = Set([timing?.taskID, pendingLink?.taskID].compactMap { $0 })
        if applyArchive(now: now, protected: timed) { persist() }
    }

    private func applyArchive(now: Date, protected: Set<UUID>) -> Bool {
        let archive = TaskArchive.apply(tasks, drafts: drafts, protected: protected, now: now)
        guard archive.changed else { return false }
        tasks = archive.tasks
        drafts = archive.drafts
        if archive.archived + archive.cleared > 0 {
            logger.info("Archive: \(archive.archived, privacy: .public) archived, \(archive.cleared, privacy: .public) cleared")
        }
        return true
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

    // MARK: - Time to log

    /// What Time to log shows, oldest first: entries waiting for an answer (asked, or put off with
    /// Not now), being sent, refused, or perhaps already logged.
    var openDrafts: [WorklogDraft] { drafts.filter { WorklogDrafts.isOpen($0.state) } }

    func task(for draft: WorklogDraft) -> TaskItem? {
        tasks.first { $0.id == draft.taskID }
    }

    /// The user's Log, Retry or Send Again: the one way Kannu writes time to Jira or GitLab. Nothing
    /// else builds a write request, and this is called only from a view, on a click
    /// (`WorklogConsentRulesTests`). `seconds` is what the card's duration field says, rounded to
    /// whole minutes; `comment` is sent to Jira only, as typed.
    ///
    /// 1. **Write-ahead.** The draft becomes `.sending` and the list is written to disk, and waited
    ///    for, before any request. A save that fails sends nothing. A relaunch that finds `.sending`
    ///    treats it as uncertain.
    /// 2. The token is read from the Keychain (interactive: the user clicked) and used only with
    ///    the site or server the time was recorded against.
    /// 3. **Jira:** a retry first asks Jira, read-only, whether the entry is already there (its
    ///    `kannu` marker), and sends only if it is not. Then `POST …/worklog?adjustEstimate=auto&
    ///    notifyUsers=false`; a lost answer is checked read-only, twice a few seconds apart, before
    ///    it counts as not logged.
    ///    **GitLab:** `POST …/add_spent_time?duration=`; a lost answer is uncertain, and the user
    ///    chooses Mark as Logged or Send Again.
    /// 4. Immediately before either request is built, after the last wait, `canStillSend` looks
    ///    again: a Disconnect during the save or the Keychain dialog sends nothing.
    func confirmWorklog(_ draftID: UUID, seconds typedSeconds: Int, comment typedComment: String?) {
        guard isReady, !sendsInFlight.contains(draftID),
              let index = drafts.firstIndex(where: { $0.id == draftID }),
              let task = tasks.first(where: { $0.id == drafts[index].taskID }), let remote = task.remote,
              WorklogDrafts.availability(
                of: drafts[index], task: task,
                jiraHost: Defaults[.jiraSiteHost], gitlabHost: Defaults[.gitlabHost],
                gitlabCanLogTime: Defaults[.gitlabCanLogTime]
              ) == .ready,
              let seconds = WorklogDrafts.loggableSeconds(typedSeconds) else { return }
        let previous = drafts[index].state
        let event: WorklogDrafts.Event = previous == .awaiting ? .send : .retry
        guard let sending = WorklogDrafts.transition(previous, on: event) else { return }
        let source = task.source
        drafts[index].seconds = seconds
        drafts[index].comment = source == .jira ? JiraAPI.cleanedComment(typedComment) : nil
        drafts[index].state = sending
        drafts[index].message = nil
        drafts[index].deferredAt = nil
        let draft = drafts[index]
        let accountID = Defaults[.jiraAccountID]
        sendsInFlight.insert(draftID)
        logger.info("Logging time to \(source.rawValue, privacy: .public): \(event == .send ? "first send" : "retry", privacy: .public)")

        Task { [weak self] in
            guard let self else { return }
            // 1. Write-ahead: on disk as .sending before anything leaves this Mac.
            guard await self.saveNow() else {
                self.restoreUnsent(draftID, to: previous, message: String(localized: "Kannu could not save its task list, so nothing was sent. Try again."))
                return
            }
            let poster = WorklogPoster()
            switch source {
            case .jira:
                // 2. The Keychain's own site, and only the one the time was recorded against.
                let credential: JiraCredential
                switch await TaskCredentials.jira.load(allowInteraction: true) {
                case .found(let stored) where stored.site == draft.hostScope && JiraSite.isValidHost(stored.site):
                    credential = stored
                case .found, .missing, .broken:
                    self.restoreUnsent(draftID, to: previous, message: String(localized: "The saved Jira sign-in is missing, or is for another site. Reconnect Jira to \(draft.hostScope) in Sources. Nothing was sent."))
                    return
                case .needsApproval:
                    self.restoreUnsent(draftID, to: previous, message: String(localized: "macOS did not let Kannu read the saved Jira token, so nothing was sent."))
                    return
                }
                // The connection this token belongs to: a 401 for it says nothing about a newer one.
                let generation = self.jira.generation
                let lookup = JiraWorklogLookup(
                    credential: credential, issueID: remote.remoteID, entry: draft.id,
                    accountID: accountID, started: draft.started, seconds: draft.seconds
                )
                // 3. A retry may follow a send that arrived: check, read-only, before sending again.
                if event == .retry {
                    switch await poster.findJiraWorklog(lookup) {
                    case .found(let remoteID):
                        self.finishSend(draftID, verdict: .logged(remoteID: remoteID), source: source, generation: generation)
                        return
                    case .notFound:
                        break
                    case .failed(let outcome):
                        let failure = WorklogDrafts.checkFailure(outcome, mayAlreadyBeLogged: previous == .uncertain)
                        self.finishSend(draftID, event: failure.event, message: failure.message)
                        return
                    }
                }
                // 4. The waits above (the save, the Keychain dialog, the check) are where a Disconnect
                //    lands: look again, with nothing awaited between this and the request.
                guard self.canStillSend(draftID) else {
                    self.restoreUnsent(draftID, to: previous, message: String(localized: "Jira was disconnected, or connected to another site, before Kannu could send this, so nothing was sent."))
                    return
                }
                guard let request = JiraAPI.addWorklogRequest(
                    credential, issueID: remote.remoteID, entry: draft.id, seconds: draft.seconds,
                    started: draft.started, comment: draft.comment
                ) else {
                    self.restoreUnsent(draftID, to: previous, message: String(localized: "Kannu could not build the request for this issue. Nothing was sent."))
                    return
                }
                let verdict = await poster.postJiraWorklog(request, lookup: lookup)
                self.finishSend(draftID, verdict: verdict, source: source, generation: generation)
            case .gitlab:
                let credential: GitLabCredential
                switch await TaskCredentials.gitlab.load(allowInteraction: true) {
                case .found(let stored) where stored.baseURL == draft.hostScope && GitLabHost.isValidBase(stored.baseURL):
                    credential = stored
                case .found, .missing, .broken:
                    self.restoreUnsent(draftID, to: previous, message: String(localized: "The saved GitLab sign-in is missing, or is for another server. Reconnect GitLab to \(GitLabHost.displayName(draft.hostScope)) in Sources. Nothing was sent."))
                    return
                case .needsApproval:
                    self.restoreUnsent(draftID, to: previous, message: String(localized: "macOS did not let Kannu read the saved GitLab token, so nothing was sent."))
                    return
                }
                let generation = self.gitlab.generation
                guard self.canStillSend(draftID) else {
                    self.restoreUnsent(draftID, to: previous, message: String(localized: "GitLab was disconnected, or connected to another server, before Kannu could send this, so nothing was sent."))
                    return
                }
                guard let kind = remote.gitlabKind, let projectID = remote.gitlabProjectID, let iid = remote.gitlabIID,
                      let request = GitLabAPI.addSpentTimeRequest(credential, kind: kind, projectID: projectID, iid: iid, seconds: draft.seconds) else {
                    self.restoreUnsent(draftID, to: previous, message: String(localized: "Kannu could not build the request for this item. Nothing was sent."))
                    return
                }
                let verdict = await poster.postGitLabSpend(request)
                self.finishSend(draftID, verdict: verdict, source: source, generation: generation)
            case .local, .github, .linear, .todoist, .appleReminders:
                // Only Jira and GitLab take time (`TaskSource.logsTime`); no draft is made for others.
                self.restoreUnsent(draftID, to: previous, message: nil)
            }
        }
    }

    /// Not now: the card folds into one line until more time is added to the draft.
    func deferWorklog(_ draftID: UUID) {
        updateDraft(draftID) { draft in
            guard draft.state == .awaiting else { return }
            draft.deferredAt = Date()
        }
    }

    /// Opens a put-off card again.
    func askAboutWorklogAgain(_ draftID: UUID) {
        updateDraft(draftID) { $0.deferredAt = nil }
    }

    /// Keep local only: the time stays recorded here and is never offered again.
    func keepWorklogLocal(_ draftID: UUID) {
        guard !sendsInFlight.contains(draftID) else { return }
        updateDraft(draftID) { draft in
            guard let next = WorklogDrafts.transition(draft.state, on: .keepLocal) else { return }
            draft.state = next
            draft.message = nil
        }
    }

    /// Mark as Logged: the user checked the server and found the entry Kannu could not confirm.
    /// Nothing is sent.
    func markWorklogLogged(_ draftID: UUID) {
        guard !sendsInFlight.contains(draftID) else { return }
        updateDraft(draftID) { draft in
            guard draft.state == .uncertain, let next = WorklogDrafts.transition(draft.state, on: .succeeded) else { return }
            draft.state = next
            draft.message = nil
        }
    }

    /// Never Ask to Log (`false`): the task's time stays on this Mac, and its open entries are
    /// kept local. Ask to Log (`true`) offers its unlogged time again.
    func setAsksToLogTime(_ asks: Bool, for taskID: UUID) {
        guard isReady, let index = tasks.firstIndex(where: { $0.id == taskID }), tasks[index].source.logsTime else { return }
        var task = tasks[index]
        task.logPolicy = asks ? .ask : .localOnly
        if asks {
            let folded = WorklogDrafts.folding(task, into: drafts)
            task = folded.task
            drafts = folded.drafts
        } else {
            for draftIndex in drafts.indices where drafts[draftIndex].taskID == taskID && !sendsInFlight.contains(drafts[draftIndex].id) {
                if let next = WorklogDrafts.transition(drafts[draftIndex].state, on: .keepLocal) {
                    drafts[draftIndex].state = next
                    drafts[draftIndex].message = nil
                }
            }
        }
        tasks[index] = task
        persist()
    }

    private func updateDraft(_ draftID: UUID, _ change: (inout WorklogDraft) -> Void) {
        guard isReady, let index = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        var draft = drafts[index]
        change(&draft)
        guard draft != drafts[index] else { return }
        drafts[index] = draft
        persist()
    }

    /// Whether a send under way may still go out: its draft is still here and still `.sending` (a
    /// Disconnect that removed the tasks took it), and it can still be sent from here — the source is
    /// connected to the site or server it was recorded against, and a GitLab token can log time.
    /// Read from the current state, after every wait, immediately before the request is built.
    private func canStillSend(_ draftID: UUID) -> Bool {
        guard let draft = drafts.first(where: { $0.id == draftID }), draft.state == .sending else { return false }
        return WorklogDrafts.availability(
            of: draft, task: task(for: draft),
            jiraHost: Defaults[.jiraSiteHost], gitlabHost: Defaults[.gitlabHost],
            gitlabCanLogTime: Defaults[.gitlabCanLogTime]
        ) == .ready
    }

    /// Nothing left this Mac: the draft goes back to where it was, with what to tell the user.
    private func restoreUnsent(_ draftID: UUID, to state: WorklogState, message: String?) {
        sendsInFlight.remove(draftID)
        guard let index = drafts.firstIndex(where: { $0.id == draftID }), drafts[index].state == .sending else { return }
        drafts[index].state = state
        drafts[index].message = message
        persist()
        logger.notice("Logging time: nothing sent")
    }

    /// `generation` is the source's connection the send's token belonged to.
    private func finishSend(_ draftID: UUID, verdict: WorklogDrafts.Verdict, source: TaskSource, generation: Int) {
        let resolution = WorklogDrafts.resolution(of: verdict, source: source)
        var remoteID: String?
        if case .logged(let id) = verdict { remoteID = id }
        if case .authRejected(let status) = verdict {
            // The token was refused: the source's row says so, and no sync re-sends it on its own.
            syncing(source)?.markRejected(generation, status: status)
        }
        finishSend(draftID, event: resolution.event, message: resolution.message, remoteID: remoteID)
    }

    private func finishSend(_ draftID: UUID, event: WorklogDrafts.Event, message: String?, remoteID: String? = nil) {
        sendsInFlight.remove(draftID)
        guard let index = drafts.firstIndex(where: { $0.id == draftID }) else {
            // Its task was removed (Disconnect › Remove) while the request was already out.
            logger.notice("Logging time: an answer came for an entry that was removed meanwhile")
            return
        }
        guard drafts[index].state == .sending, let next = WorklogDrafts.transition(.sending, on: event) else { return }
        drafts[index].state = next
        drafts[index].message = message
        if let remoteID { drafts[index].remoteWorklogID = remoteID }
        // The source's own total catches up at the next sync; until then it includes this entry.
        if next == .logged, let taskIndex = tasks.firstIndex(where: { $0.id == drafts[index].taskID }), tasks[taskIndex].remote != nil {
            tasks[taskIndex].remote?.remoteSpentSeconds = (tasks[taskIndex].remote?.remoteSpentSeconds ?? 0) + drafts[index].seconds
        }
        persist()
        logger.info("Logging time ended: \(next.rawValue, privacy: .public)")
    }

    // MARK: - Sources

    /// Jira Cloud's sync (`SourceSync`): the user's issues, by the issue filter. Built on first use.
    private(set) lazy var jira = SourceSync(
        source: .jira,
        provider: JiraTaskSource(),
        store: TaskCredentials.jira,
        connection: { SourceConnection(scope: Defaults[.jiraSiteHost], syncOn: Defaults[.jiraEnabled]) },
        options: { JiraAPI.effectiveJQL(Defaults[.jiraJQL]) },
        forget: {
            Defaults[.jiraEnabled] = false
            Defaults[.jiraSiteHost] = ""
            Defaults[.jiraAccountID] = ""
            Defaults[.jiraAccountDisplayName] = ""
        },
        host: self
    )

    /// GitLab's: the user's open issues and, with Include merge requests on, the open merge
    /// requests assigned to them or waiting for their review.
    private(set) lazy var gitlab = SourceSync(
        source: .gitlab,
        provider: GitLabTaskSource(),
        store: TaskCredentials.gitlab,
        connection: { SourceConnection(scope: Defaults[.gitlabHost], syncOn: Defaults[.gitlabEnabled]) },
        options: {
            GitLabTaskSource.Options(username: Defaults[.gitlabUsername],
                                     includeMergeRequests: Defaults[.gitlabIncludeMergeRequests])
        },
        forget: {
            Defaults[.gitlabEnabled] = false
            Defaults[.gitlabHost] = ""
            Defaults[.gitlabUsername] = ""
            Defaults[.gitlabAccountDisplayName] = ""
            Defaults[.gitlabCanLogTime] = false
        },
        host: self
    )

    /// Apple Reminders': every incomplete reminder, by list. No token — macOS's permission — and a
    /// change in Reminders asks for a quiet sync (`AppleRemindersStore.observeChanges`).
    private(set) lazy var appleReminders = SourceSync(
        source: .appleReminders,
        provider: AppleRemindersTaskSource(),
        store: AppleRemindersAccessKeeper(),
        connection: { SourceConnection(scope: Defaults[.appleRemindersScope], syncOn: Defaults[.appleRemindersEnabled]) },
        options: { () },
        forget: {
            Defaults[.appleRemindersEnabled] = false
            Defaults[.appleRemindersScope] = ""
        },
        host: self
    )

    /// GitHub's, from github.com or a GitHub Enterprise Server: the open issues assigned to the user
    /// and, with Include pull requests on, the pull requests.
    private(set) lazy var github = SourceSync(
        source: .github,
        provider: GitHubTaskSource(),
        store: TaskCredentials.github,
        connection: { SourceConnection(scope: Defaults[.githubHost], syncOn: Defaults[.githubEnabled]) },
        options: { Defaults[.githubIncludePullRequests] },
        forget: {
            Defaults[.githubEnabled] = false
            Defaults[.githubHost] = ""
            Defaults[.githubUsername] = ""
            Defaults[.githubAccountDisplayName] = ""
        },
        host: self
    )

    /// Linear's: the issues assigned to the user that are not done or canceled.
    private(set) lazy var linear = SourceSync(
        source: .linear,
        provider: LinearTaskSource(),
        store: TaskCredentials.linear,
        connection: { SourceConnection(scope: Defaults[.linearWorkspace], syncOn: Defaults[.linearEnabled]) },
        options: { () },
        forget: {
            Defaults[.linearEnabled] = false
            Defaults[.linearWorkspace] = ""
            Defaults[.linearAccountDisplayName] = ""
        },
        host: self
    )

    /// Todoist's: the open tasks, or those the user's Todoist filter matches, not assigned to someone else.
    private(set) lazy var todoist = SourceSync(
        source: .todoist,
        provider: TodoistTaskSource(),
        store: TaskCredentials.todoist,
        connection: { SourceConnection(scope: Defaults[.todoistAccount], syncOn: Defaults[.todoistEnabled]) },
        options: { Defaults[.todoistFilter] },
        forget: {
            Defaults[.todoistEnabled] = false
            Defaults[.todoistAccount] = ""
            Defaults[.todoistAccountDisplayName] = ""
        },
        host: self
    )

    /// Every source's sync, in source order.
    var syncs: [any SourceSyncing] { [jira, gitlab, github, linear, todoist, appleReminders] }

    /// Reminders' change notice is listened to only while Reminders is connected, its sync is on,
    /// and tasks are on; it asks for a quiet sync, never one with a dialog.
    private func updateRemindersObserver() {
        let observe = Defaults[.enableTasks] && appleReminders.isSyncOn
        AppleRemindersStore.shared.observeChanges(observe) { [weak self] in
            self?.appleReminders.externalChange()
        }
    }

    /// A source's sync; nil for local tasks.
    func syncing(_ source: TaskSource) -> (any SourceSyncing)? {
        syncs.first { $0.source == source }
    }

    /// Where a source's syncing stands, for its row and page.
    func syncState(_ source: TaskSource) -> SourceSyncState { syncing(source)?.state ?? .idle }

    /// Disconnect could not delete the source's saved token from the Keychain.
    func tokenRemovalFailed(_ source: TaskSource) -> Bool { syncing(source)?.tokenRemovalFailed ?? false }

    func isSyncing(_ source: TaskSource) -> Bool { syncing(source)?.isSyncing ?? false }

    /// A page with the source's row appeared, or its Sync was switched on (`SourceSync.syncIfStale`).
    func syncIfStale(_ source: TaskSource) {
        #if DEBUG
        if Self.snapshotFile != nil { return }
        #endif
        syncing(source)?.syncIfStale(now: Date())
    }

    /// The user's Refresh, Allow Keychain Access or new filter (`SourceSync.refresh`).
    func refresh(_ source: TaskSource) { syncing(source)?.refresh(now: Date()) }

    /// An option that decides what the source fetches was switched (`SourceSync.optionsChanged`).
    func sourceOptionsChanged(_ source: TaskSource) { syncing(source)?.optionsChanged(now: Date()) }

    /// Disconnect could not delete the saved token: the user asks again, off the main actor.
    func retryRemovingToken(_ source: TaskSource) { syncing(source)?.retryRemovingToken() }

    /// Forgets the source's connection and token, and stops its syncing. With `removeTasks`, its
    /// tasks and their unlogged time go too (timing one stops first); without, they stay in the order
    /// as they are, and their Time to log entries stay: kept local, or sent once the source is
    /// connected to the same site or server again. A Log still saving or waiting for the Keychain
    /// sends nothing (`canStillSend`); one whose request is already out cannot be recalled, and its
    /// answer is dropped with the entry.
    func disconnect(_ source: TaskSource, removeTasks: Bool) {
        guard let sync = syncing(source) else { return }
        sync.disconnect()
        if source == .appleReminders { updateRemindersObserver() }
        logger.info("\(source.rawValue, privacy: .public) disconnected, tasks removed: \(removeTasks, privacy: .public)")
        guard removeTasks, isReady else { return }
        if let timed = timing?.taskID, tasks.first(where: { $0.id == timed })?.source == source {
            stopTiming()
        }
        let removed = Set(tasks.filter { $0.source == source }.map(\.id))
        guard !removed.isEmpty else { return }
        if let pending = pendingLink, removed.contains(pending.taskID) { pendingLink = nil }
        tasks.removeAll { removed.contains($0.id) }
        drafts.removeAll { removed.contains($0.taskID) }
        persist()
    }

    // MARK: - Connect

    /// Connect… from `SourceConnectSheet`: GitHub (with its server), Linear, Todoist, or Apple
    /// Reminders (no token: macOS asks). Nil on success, or what to tell the user.
    func connect(_ source: TaskSource, server: String, token: String) async -> String? {
        switch source {
        case .appleReminders:
            return await connectAppleReminders()
        case .github:
            return await connectGitHub(serverInput: server, token: token)
        case .linear:
            return await connectLinear(apiKey: token)
        case .todoist:
            return await connectTodoist(token: token)
        case .local, .jira, .gitlab:
            return String(localized: "\(source.name) cannot be connected in this version of Kannu.")
        }
    }

    /// Asks macOS for Reminders, once — the only place Kannu does — then syncs. Nil on success.
    private func connectAppleReminders() async -> String? {
        let failure = await appleReminders.connect {
            guard await AppleRemindersStore.shared.requestAccess() else {
                return .refused(String(localized: "macOS did not let Kannu read your reminders. Allow Kannu in Privacy & Security › Reminders, then connect again."))
            }
            return .accepted(AppleRemindersAccess()) {
                Defaults[.appleRemindersScope] = AppleReminders.scope
                Defaults[.appleRemindersEnabled] = true
            }
        }
        if failure == nil { logger.info("Apple Reminders connected") }
        updateRemindersObserver()
        return failure
    }

    /// The token page on a GitHub server typed so far; nil until it is one Kannu would connect to.
    nonisolated static func githubCreateTokenURL(server: String) -> URL? {
        guard case .success(let base) = GitHubHost.normalize(server) else { return nil }
        return GitHubHost.createTokenURL(base: base)
    }

    /// Checks the token with Todoist, which also says whose account it is, then stores both and
    /// syncs. Nil on success, or what to tell the user. Nothing is stored until Todoist accepted it.
    private func connectTodoist(token: String) async -> String? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TodoistAPI.isPlausibleToken(token) else {
            return String(localized: "Paste your API token from Todoist, under Integrations › Developer. It has no spaces in it.")
        }
        let failure = await todoist.connect {
            switch await TodoistClient().verify(token: token) {
            case .verified(let user):
                guard let account = TodoistAPI.scope(userID: user.id) else {
                    return .refused(String(localized: "Todoist answered, but not with an account Kannu can use."))
                }
                return .accepted(TodoistCredential(userID: user.id, token: token)) {
                    Defaults[.todoistAccount] = account
                    Defaults[.todoistAccountDisplayName] = user.fullName ?? ""
                    Defaults[.todoistEnabled] = true
                }
            case .failed(let failure):
                return .refused(TodoistAPI.connectMessage(for: failure))
            }
        }
        if failure == nil { logger.info("Todoist connected") }
        return failure
    }

    /// Checks the API key with Linear, which also says the workspace, then stores both and syncs.
    /// Nil on success, or what to tell the user. Nothing is stored until Linear has accepted the key.
    private func connectLinear(apiKey: String) async -> String? {
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LinearAPI.isPlausibleKey(apiKey) else { return LinearAPI.implausibleKeyMessage }
        let failure = await linear.connect {
            switch await LinearClient().verify(apiKey: apiKey) {
            case .verified(let viewer):
                guard let workspace = viewer.scope else {
                    return .refused(String(localized: "Linear answered, but its workspace address is not one Kannu can use."))
                }
                return .accepted(LinearCredential(workspace: workspace, apiKey: apiKey)) {
                    Defaults[.linearWorkspace] = workspace
                    Defaults[.linearAccountDisplayName] = viewer.displayName ?? viewer.name
                    Defaults[.linearEnabled] = true
                }
            case .failed(let failure):
                return .refused(LinearAPI.connectMessage(for: failure))
            }
        }
        if failure == nil { logger.info("Linear connected") }
        return failure
    }

    /// Checks the server and token with GitHub, then stores them and syncs. Nil on success, or what
    /// to tell the user. Nothing is stored until GitHub has accepted the token.
    private func connectGitHub(serverInput: String, token: String) async -> String? {
        let base: String
        switch GitHubHost.normalize(serverInput) {
        case .success(let normalized): base = normalized
        case .failure(let error): return GitHubAPI.message(for: error)
        }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GitHubAPI.isPlausibleToken(token) else {
            return String(localized: "Paste a personal access token from your GitHub settings. It has no spaces in it.")
        }
        let credential = GitHubCredential(baseURL: base, token: token)
        let server = GitHubHost.displayName(base)
        let failure = await github.connect {
            switch await GitHubClient().verify(credential) {
            case .verified(let user):
                return .accepted(credential) {
                    Defaults[.githubHost] = base
                    Defaults[.githubUsername] = user.login
                    Defaults[.githubAccountDisplayName] = user.name ?? ""
                    Defaults[.githubEnabled] = true
                }
            case .failed(let failure):
                return .refused(GitHubAPI.connectMessage(for: failure, server: server))
            }
        }
        if failure == nil { logger.info("GitHub connected") }
        return failure
    }

    /// Checks the site, email and token with Jira, then stores them and syncs. Nil on success, or
    /// what to tell the user. Nothing is stored until Jira has accepted the token.
    func connectJira(siteInput: String, email: String, token: String) async -> String? {
        let host: String
        switch JiraSite.normalize(siteInput) {
        case .success(let normalized): host = normalized
        case .failure(let error): return JiraTaskSource.message(for: error)
        }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !token.isEmpty else {
            return String(localized: "Type the email of your Atlassian account and an API token.")
        }
        guard !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            return String(localized: "An API token has no spaces in it. Copy it again from Atlassian.")
        }
        let credential = JiraCredential(site: host, email: email, token: token)
        let failure = await jira.connect {
            switch await JiraClient().verify(credential) {
            case .verified(let myself):
                return .accepted(credential) {
                    Defaults[.jiraSiteHost] = host
                    Defaults[.jiraAccountID] = myself.accountId
                    Defaults[.jiraAccountDisplayName] = myself.displayName ?? ""
                    Defaults[.jiraEnabled] = true
                }
            case .failed(let failure):
                return .refused(JiraTaskSource.connectMessage(for: failure, host: host))
            }
        }
        if failure == nil { logger.info("Jira connected") }
        return failure
    }

    /// Checks the server and token with GitLab, then stores them and syncs. Nil on success, or what
    /// to tell the user. Nothing is stored until GitLab has accepted the token, and a token that can
    /// list nothing is refused.
    func connectGitLab(serverInput: String, token: String) async -> String? {
        let base: String
        switch GitLabHost.normalize(serverInput) {
        case .success(let normalized): base = normalized
        case .failure(let error): return GitLabTaskSource.message(for: error)
        }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return String(localized: "Paste a personal access token from your GitLab profile.")
        }
        guard GitLabAPI.isPlausibleToken(token) else {
            return String(localized: "A personal access token has no spaces in it. Copy it again from GitLab.")
        }
        let credential = GitLabCredential(baseURL: base, token: token)
        let server = GitLabHost.displayName(base)
        let failure = await gitlab.connect {
            switch await GitLabClient().verify(credential) {
            case .verified(let user, let scopes):
                let access = GitLabAPI.access(scopes: scopes)
                guard access != .cannotList else {
                    return .refused(String(localized: "This token cannot list your issues. Create one with the read_api scope, or api to log time later."))
                }
                guard GitLabAPI.isUsername(user.username) else {
                    return .refused(String(localized: "\(server) answered, but not the way GitLab does. Check the server."))
                }
                return .accepted(credential) {
                    Defaults[.gitlabHost] = base
                    Defaults[.gitlabUsername] = user.username
                    Defaults[.gitlabAccountDisplayName] = user.name ?? ""
                    Defaults[.gitlabCanLogTime] = access == .canLogTime
                    Defaults[.gitlabEnabled] = true
                }
            case .failed(let failure):
                return .refused(GitLabTaskSource.connectMessage(for: failure, server: server))
            }
        }
        if failure == nil { logger.info("GitLab connected, can log time: \(Defaults[.gitlabCanLogTime], privacy: .public)") }
        return failure
    }

    /// The issue's page, built from the host the task came from, or nil for anything else.
    func jiraBrowseURL(for task: TaskItem) -> URL? {
        guard task.source == .jira, let remote = task.remote else { return nil }
        return JiraSite.browseURL(host: remote.hostScope, key: remote.key)
    }

    // MARK: - Where a sync's items land

    var readiness: SourceReadiness {
        switch loadState {
        case .loading: return .loading
        case .ready: return .ready
        case .failed: return .failed
        }
    }

    /// A sync's items, folded into the list as it is now. The task being timed stays in the order
    /// however its item changed: its row holds the list's Stop button. The first sync after its
    /// timing ends decides.
    func merge(_ fetch: RemoteFetch, from source: TaskSource, scope: String, at now: Date) {
        let timed = Set([timing?.taskID, pendingLink?.taskID].compactMap { $0 })
        let merged = TaskMerge.apply(.fetched(fetch), source: source, hostScope: scope, to: tasks, now: now, keepingActive: timed)
        tasks = merged.tasks
        let archived = applyArchive(now: now, protected: timed)
        if merged.changed || archived { persist() }
        logger.info("\(source.rawValue, privacy: .public) sync: \(fetch.issues.count, privacy: .public) items, complete \(fetch.complete, privacy: .public), \(merged.added, privacy: .public) added, \(merged.updated, privacy: .public) updated, \(merged.gone, privacy: .public) gone")
    }

    func sourceWillChange() {
        objectWillChange.send()
    }

    // MARK: - Linked merge requests

    /// What the task card's linked merge requests page shows.
    enum LinkedMergeRequestsResult: Equatable {
        case loaded([LinkedMergeRequest], complete: Bool)
        case failed(String)
        /// macOS did not let Kannu read the saved token.
        case needsKeychainApproval
        /// Disconnected, connected to another server, or the token was refused.
        case needsReconnect
    }

    /// The connection and the task's last sync a list was read under: a newer either reads again.
    private struct LinkedMergeRequestsStamp: Equatable {
        let generation: Int
        let lastSeenAt: Date
    }

    private var linkedMergeRequestsCache: [UUID: (stamp: LinkedMergeRequestsStamp, result: LinkedMergeRequestsResult)] = [:]
    private var linkedMergeRequestsInFlight: [UUID: Task<LinkedMergeRequestsResult, Never>] = [:]

    /// The merge requests that close a GitLab issue (`closed_by`), for the task card's linked page.
    /// A click asks, so the Keychain may be read with its dialog, as Refresh does. Read-only. A
    /// loaded list is kept until the task's next sync or a new connection; two asks at once share
    /// one request.
    func linkedMergeRequests(for taskID: UUID) async -> LinkedMergeRequestsResult {
        guard isReady, let task = tasks.first(where: { $0.id == taskID }), task.source == .gitlab,
              let remote = task.remote, remote.gitlabKind == .issue,
              let projectID = remote.gitlabProjectID, let iid = remote.gitlabIID,
              remote.hostScope == Defaults[.gitlabHost] else { return .needsReconnect }
        let stamp = LinkedMergeRequestsStamp(generation: gitlab.generation, lastSeenAt: remote.lastSeenAt)
        if let cached = linkedMergeRequestsCache[taskID], cached.stamp == stamp { return cached.result }
        if let running = linkedMergeRequestsInFlight[taskID] { return await running.value }
        let host = remote.hostScope
        let work = Task { [weak self] () -> LinkedMergeRequestsResult in
            guard let self else { return .needsReconnect }
            return await self.fetchLinkedMergeRequests(projectID: projectID, iid: iid, host: host)
        }
        linkedMergeRequestsInFlight[taskID] = work
        let result = await work.value
        linkedMergeRequestsInFlight[taskID] = nil
        if case .loaded = result, stamp.generation == gitlab.generation {
            linkedMergeRequestsCache[taskID] = (stamp, result)
        }
        return result
    }

    private func fetchLinkedMergeRequests(projectID: Int, iid: Int, host: String) async -> LinkedMergeRequestsResult {
        let credential: GitLabCredential
        switch await TaskCredentials.gitlab.load(allowInteraction: true) {
        case .found(let stored) where stored.baseURL == host && GitLabHost.isValidBase(stored.baseURL):
            credential = stored
        case .found, .missing, .broken:
            return .needsReconnect
        case .needsApproval:
            return .needsKeychainApproval
        }
        let generation = gitlab.generation
        let read = await GitLabClient().closingMergeRequests(credential, projectID: projectID, iid: iid)
        // Disconnected, or connected again, while the list was on its way: it is not this one's.
        guard generation == gitlab.generation else { return .needsReconnect }
        switch read {
        case .success(let list):
            return .loaded(list.items, complete: list.complete)
        case .failure(.http(.auth(let status))):
            gitlab.markRejected(generation, status: status)
            return .needsReconnect
        case .failure(let failure):
            switch GitLabTaskSource.syncState(for: failure, now: Date()) {
            case .failed(let reason):
                return .failed(reason)
            case .offline:
                return .failed(String(localized: "Kannu is offline. Try again when you are back online."))
            case .rateLimited(let until):
                return .failed(String(localized: "GitLab asked Kannu to wait until \(until.formatted(date: .omitted, time: .shortened))."))
            default:
                return .needsReconnect
            }
        }
    }

    /// The item's page, only when it is on the server the task came from.
    func gitlabBrowseURL(for task: TaskItem) -> URL? {
        guard task.source == .gitlab, let remote = task.remote, let link = remote.gitlabWebURL,
              GitLabHost.isWebURL(link, onServer: remote.hostScope) else { return nil }
        return URL(string: link)
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
            if let pending = pendingReminderStart {
                pendingReminderStart = nil
                pending.otherwise()
                pending.completion()
            }
            if let typed = pendingTypedStart {
                pendingTypedStart = nil
                typed.otherwise()
            }
        }
    }

    private func apply(_ loaded: TasksFile) {
        var file = loaded
        let interrupted = file.markOpenSegmentsInterrupted()
        // A draft still being sent when Kannu stopped may have arrived: it is uncertain now, and
        // is never sent again without a check (Jira) or the user's say-so (GitLab).
        var normalized = WorklogDrafts.normalizedAtLoad(file.drafts) { draft in
            file.tasks.first { $0.id == draft.taskID }?.source
        }
        // Nothing is being timed at launch, so time a crash left unfolded (closed by a pause or a
        // sleep, never ended) is offered now. Folding a task already folded changes nothing.
        var loadedTasks = file.tasks
        for index in loadedTasks.indices {
            let folded = WorklogDrafts.folding(loadedTasks[index], into: normalized)
            loadedTasks[index] = folded.task
            normalized = folded.drafts
        }
        tasks = loadedTasks
        drafts = normalized
        tagColors = file.tagColors
        // Closed tasks that waited long enough move to the archive, and archived remote ones whose
        // time is settled clear. Nothing is timed at launch, so nothing is protected.
        let archive = TaskArchive.apply(tasks, drafts: drafts, protected: [], now: Date())
        tasks = archive.tasks
        drafts = archive.drafts
        loadState = .ready
        // What earlier launches told macOS. It may not hold all of it (notifications turned on
        // since, a file replaced), so `checkReminderPermission` below checks with macOS.
        reminderBaseline = TaskReminderPlan.wanted(loadedTasks)
        let uncertain = normalized.filter { $0.state == .uncertain }.count
        logger.info("Loaded \(file.tasks.count, privacy: .public) tasks, \(interrupted, privacy: .public) interrupted sessions, \(uncertain, privacy: .public) uncertain entries")
        if interrupted > 0 || normalized != file.drafts || loadedTasks != file.tasks || archive.changed { persist() }
        for sync in syncs { sync.loadFinished() }
        updateRemindersObserver()
        if let pending = pendingReminderStart {
            pendingReminderStart = nil
            if !start(pending.taskID) { pending.otherwise() }
            pending.completion()
        }
        if let typed = pendingTypedStart {
            pendingTypedStart = nil
            if !startTypedNow(typed.typed, reuse: typed.reuse, duration: typed.duration, preset: typed.preset) {
                typed.otherwise()
            }
        }
        checkReminderPermission()
    }

    private var snapshot: TasksFile {
        TasksFile(tasks: tasks, drafts: drafts, tagColors: tagColors)
    }

    /// Saves on the store, off the main actor. Saves can land out of order; the revision lets the
    /// store drop an older one.
    private func persist() {
        guard isReady else { return }
        #if DEBUG
        if Self.snapshotFile != nil { return }
        #endif
        syncReminders()
        revision += 1
        let revision = revision
        let snapshot = snapshot
        Task { [weak self, store] in
            let outcome = await store.save(snapshot, revision: revision)
            self?.didSave(outcome, revision: revision)
        }
    }

    /// Tells macOS about reminders that changed with this edit: added, moved, retitled, or gone
    /// because the task was done, hidden, deleted or unscheduled. With Tasks off nothing is wanted:
    /// the baseline is empty then, and a save must not send the whole list back.
    private func syncReminders() {
        let wanted = Defaults[.enableTasks] ? TaskReminderPlan.wanted(tasks) : [:]
        let changes = TaskReminderPlan.changes(from: reminderBaseline, to: wanted, now: Date())
        reminderBaseline = wanted
        TaskReminders.apply(changes)
    }

    /// Sends every reminder still ahead again, once macOS allows them: one scheduled before the
    /// user answered the permission prompt, or while notifications were off, was refused. Adds
    /// only, so a reminder already on screen for another task stays.
    private func resendReminders() {
        TaskReminders.apply(TaskReminderPlan.resend(reminderBaseline, now: Date()))
    }

    /// Writes the list now and waits until it is on disk: the write-ahead before a send. A newer
    /// revision already written counts too — it was taken after this state, so it holds it.
    private func saveNow() async -> Bool {
        guard isReady else { return false }
        revision += 1
        let revision = revision
        let outcome = await store.save(snapshot, revision: revision)
        didSave(outcome, revision: revision)
        return outcome == .written || outcome == .stale
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
            // Quitting ends the timing, paused or not: its time is offered for logging next launch.
            if let index = tasks.firstIndex(where: { $0.id == current.taskID }) {
                var task = tasks[index]
                if !current.isPaused && !isAsleep {
                    task.segments = TaskTimeMath.closing(task.segments, at: Date())
                }
                let folded = WorklogDrafts.folding(task, into: drafts)
                changed = folded.task != tasks[index] || folded.drafts != drafts
                tasks[index] = folded.task
                drafts = folded.drafts
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
