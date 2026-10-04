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
///
/// **Jira.** Jira Cloud is a source of tasks (Brain › Tasks › Sources). A sync reads the user's
/// issues and folds them into the list with `TaskMerge`, on the main actor, against the list as it
/// is then. It runs only when the Tasks page appears and the last sync is over 5 minutes old, on
/// Refresh, and right after Connect: no timer, no polling, nothing at launch. The credential is read
/// from the Keychain off the main actor (`JiraCredentialStore`), non-interactively unless the user
/// clicked something, and the host it is used with is the Keychain's own, never a Defaults copy.
///
/// **GitLab.** The same, for the user's open GitLab issues and, with Include merge requests on, the
/// open merge requests assigned to them or waiting for their review (`GitLabClient`,
/// `GitLabCredentialStore`). Each source keeps its own sync state, generation and in-flight marker,
/// and merges only its own tasks: one failing or being slow never shows on, or holds up, the other.
///
/// **Ask, then log.** When timing a Jira or GitLab task ends, its unlogged time is folded into one
/// draft (`WorklogDrafts.folding`, rounded to the nearest 15 minutes) that Brain › Tasks › Time to
/// log asks about. Kannu always asks first: only `confirmWorklog`, from the user's Log, Retry or
/// Send Again, builds a write request (`WorklogConsentRulesTests`), and it saves the draft as
/// `.sending` before the request goes out, so a relaunch knows to check instead of sending twice.
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
    @Published private(set) var jiraSync: SourceSyncState = .idle
    /// Disconnect could not delete the saved token from the Keychain, so it is still there.
    @Published private(set) var jiraTokenRemovalFailed = false
    @Published private(set) var gitlabSync: SourceSyncState = .idle
    /// Disconnect could not delete the saved GitLab token from the Keychain, so it is still there.
    @Published private(set) var gitlabTokenRemovalFailed = false

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
    /// Drafts whose send is under way, so a second click cannot start another.
    private var sendsInFlight = Set<UUID>()

    /// A sync older than this is refreshed when the Tasks page appears (Jira and GitLab alike).
    static let jiraStaleAfter: TimeInterval = 5 * 60
    /// The last sync that succeeded.
    private var lastJiraSync: Date?
    /// Bumped by Connect and Disconnect: a sync started before carries the old value, and its result
    /// is dropped instead of landing on a list that has moved on.
    private var jiraGeneration = 0
    /// The generation of the sync in flight, if any.
    private var jiraSyncInFlight: Int?
    /// The page appeared before the task file was read: sync once it is.
    private var pendingJiraSyncWhenReady = false
    /// The same four, for GitLab. Its generation also moves when Include merge requests is switched
    /// during a sync, which read the old setting.
    private var lastGitLabSync: Date?
    private var gitlabGeneration = 0
    private var gitlabSyncInFlight: Int?
    private var pendingGitLabSyncWhenReady = false

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
        // Which tasks the order lists depends on these; the views read it through `activeTasks`.
        // `options: []`, so subscribing does not fire.
        Publishers.MergeMany(
            Defaults.publisher(.showLocalTasks, options: []).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.jiraEnabled, options: []).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.jiraSiteHost, options: []).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.gitlabEnabled, options: []).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.gitlabHost, options: []).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.gitlabIncludeMergeRequests, options: []).map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
        .store(in: &cancellables)
        Task { await load() }
    }

    // MARK: - What the views read

    var isReady: Bool { loadState == .ready }

    /// The task order, top first: active tasks of the sources that are switched on.
    var activeTasks: [TaskItem] { TaskOrdering.active(tasks, listed: listed) }

    /// Whether the task order shows this task: Local tasks, Sync Jira and Sync GitLab decide by
    /// source, and Include merge requests for GitLab's merge requests. The moves use the same
    /// filter, so a task the user cannot see never shifts one.
    func isListed(_ task: TaskItem) -> Bool { listed(task) }

    private var listed: TaskOrdering.Listed {
        TaskOrdering.listedFilter(
            showLocal: Defaults[.showLocalTasks],
            showJira: Defaults[.jiraEnabled] || !isJiraConnected,
            showGitLab: Defaults[.gitlabEnabled] || !isGitLabConnected,
            showGitLabMergeRequests: Defaults[.gitlabIncludeMergeRequests] || !isGitLabConnected,
            alwaysListed: timing?.taskID
        )
    }

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

    func moveUp(_ taskID: UUID) {
        let listed = listed
        reorder { TaskOrdering.movingUp(taskID, in: $0, listed: listed) }
    }

    func moveDown(_ taskID: UUID) {
        let listed = listed
        reorder { TaskOrdering.movingDown(taskID, in: $0, listed: listed) }
    }

    func move(activeOffsets: IndexSet, toActiveOffset destination: Int) {
        let listed = listed
        reorder { TaskOrdering.moving(activeOffsets: activeOffsets, toActiveOffset: destination, in: $0, listed: listed) }
    }

    /// Marking the task being timed done stops the timer first, which ends its time.
    func markDone(_ taskID: UUID) {
        if timing?.taskID == taskID { stopTiming() }
        update(taskID) { $0.visibility = .done }
    }

    /// Out of the task order, into Done and hidden; Show puts it back. A remote task is hidden, never
    /// deleted: the next sync would only bring it back.
    func hide(_ taskID: UUID) {
        if timing?.taskID == taskID { stopTiming() }
        update(taskID) { $0.visibility = .hidden }
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
    ///    notifyUsers=false`; a lost answer is checked once more, read-only.
    ///    **GitLab:** `POST …/add_spent_time?duration=`; a lost answer is uncertain, and the user
    ///    chooses Mark Logged or Send Again.
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
                switch await JiraCredentialStore.load(allowInteraction: true) {
                case .found(let stored) where stored.site == draft.hostScope && JiraSite.isValidHost(stored.site):
                    credential = stored
                case .found, .missing, .broken:
                    self.restoreUnsent(draftID, to: previous, message: String(localized: "The saved Jira sign-in is missing, or is for another site. Reconnect Jira to \(draft.hostScope) in Sources. Nothing was sent."))
                    return
                case .needsApproval:
                    self.restoreUnsent(draftID, to: previous, message: String(localized: "macOS did not let Kannu read the saved Jira token, so nothing was sent."))
                    return
                }
                let lookup = JiraWorklogLookup(
                    credential: credential, issueID: remote.remoteID, entry: draft.id,
                    accountID: accountID, started: draft.started, seconds: draft.seconds
                )
                // 3. A retry may follow a send that arrived: check, read-only, before sending again.
                if event == .retry {
                    switch await poster.findJiraWorklog(lookup) {
                    case .found(let remoteID):
                        self.finishSend(draftID, verdict: .logged(remoteID: remoteID), source: source)
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
                self.finishSend(draftID, verdict: verdict, source: source)
            case .gitlab:
                let credential: GitLabCredential
                switch await GitLabCredentialStore.load(allowInteraction: true) {
                case .found(let stored) where stored.baseURL == draft.hostScope && GitLabHost.isValidBase(stored.baseURL):
                    credential = stored
                case .found, .missing, .broken:
                    self.restoreUnsent(draftID, to: previous, message: String(localized: "The saved GitLab sign-in is missing, or is for another server. Reconnect GitLab to \(GitLabHost.displayName(draft.hostScope)) in Sources. Nothing was sent."))
                    return
                case .needsApproval:
                    self.restoreUnsent(draftID, to: previous, message: String(localized: "macOS did not let Kannu read the saved GitLab token, so nothing was sent."))
                    return
                }
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
                self.finishSend(draftID, verdict: verdict, source: source)
            case .local:
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

    /// Mark Logged: the user checked the server and found the entry Kannu could not confirm.
    /// Nothing is sent.
    func markWorklogLogged(_ draftID: UUID) {
        guard !sendsInFlight.contains(draftID) else { return }
        updateDraft(draftID) { draft in
            guard draft.state == .uncertain, let next = WorklogDrafts.transition(draft.state, on: .succeeded) else { return }
            draft.state = next
            draft.message = nil
        }
    }

    /// Never Ask to Log Time (`false`): the task's time stays on this Mac, and its open entries are
    /// kept local. Ask to Log Time (`true`) offers its unlogged time again.
    func setAsksToLogTime(_ asks: Bool, for taskID: UUID) {
        guard isReady, let index = tasks.firstIndex(where: { $0.id == taskID }), tasks[index].source != .local else { return }
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

    private func finishSend(_ draftID: UUID, verdict: WorklogDrafts.Verdict, source: TaskSource) {
        let resolution = WorklogDrafts.resolution(of: verdict, source: source)
        var remoteID: String?
        if case .logged(let id) = verdict { remoteID = id }
        if case .authRejected(let status) = verdict {
            // The token was refused: the Sources row says so, and no sync re-sends it on its own.
            switch source {
            case .jira where !isJiraSyncing: jiraSync = .authFailed(status: status)
            case .gitlab where !isGitLabSyncing: gitlabSync = .authFailed(status: status)
            default: break
            }
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

    // MARK: - Jira

    /// Connected, as far as the display copies say. The Keychain has the final word at sync time.
    var isJiraConnected: Bool { !Defaults[.jiraSiteHost].isEmpty }

    /// Connected and "Sync Jira" on.
    var isJiraSyncOn: Bool { isJiraConnected && Defaults[.jiraEnabled] }

    var isJiraSyncing: Bool { jiraSyncInFlight == jiraGeneration }

    /// The page appeared. Syncs when Jira is on, nothing is in flight, and
    /// `SourceSyncState.allowsSyncOnAppear` agrees: the last sync is over 5 minutes old, no rate limit
    /// is running, and Jira has not refused the token (a refused token is only ever retried by the
    /// user). Never shows the Keychain dialog: a read that would need it ends in
    /// `.needsKeychainApproval`, and the user's click retries.
    func syncJiraIfStale(now: Date = Date()) {
        guard isJiraSyncOn, !isJiraSyncing else { return }
        guard isReady else {
            if loadState == .loading { pendingJiraSyncWhenReady = true }
            return
        }
        guard jiraSync.allowsSyncOnAppear(lastSuccess: lastJiraSync, now: now, staleAfter: Self.jiraStaleAfter) else { return }
        syncJira(interactive: false, using: nil)
    }

    /// Refresh, and Allow Keychain Access: the user asked, so the Keychain may ask them too.
    func refreshJira(now: Date = Date()) {
        guard isJiraSyncOn, isReady, !isJiraSyncing else { return }
        if case .rateLimited(let until) = jiraSync, until > now { return }
        syncJira(interactive: true, using: nil)
    }

    /// Checks the site, email and token with Jira, then stores them and syncs. Nil on success, or
    /// what to tell the user. Nothing is stored until Jira has accepted the token.
    func connectJira(siteInput: String, email: String, token: String) async -> String? {
        let host: String
        switch JiraSite.normalize(siteInput) {
        case .success(let normalized): host = normalized
        case .failure(let error): return Self.message(for: error)
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
        let verified: JiraMyself
        switch await JiraClient().verify(credential) {
        case .verified(let myself): verified = myself
        case .failed(let failure): return Self.connectMessage(for: failure, host: host)
        }
        guard !Task.isCancelled else { return String(localized: "Cancelled.") }
        guard await JiraCredentialStore.save(credential) else {
            return String(localized: "Jira accepted the token, but Kannu could not save it in your Keychain.")
        }
        Defaults[.jiraSiteHost] = host
        Defaults[.jiraAccountID] = verified.accountId
        Defaults[.jiraAccountDisplayName] = verified.displayName ?? ""
        Defaults[.jiraEnabled] = true
        jiraGeneration += 1
        jiraSyncInFlight = nil
        lastJiraSync = nil
        jiraSync = .idle
        // The save replaced whatever a failed Disconnect left in the Keychain.
        jiraTokenRemovalFailed = false
        logger.info("Jira connected")
        if isReady {
            // The credential is in hand: no Keychain read for the first sync.
            syncJira(interactive: false, using: credential)
        } else if loadState == .loading {
            pendingJiraSyncWhenReady = true
        }
        return nil
    }

    /// Forgets the token and stops syncing. With `removeTasks`, the Jira tasks and their unlogged
    /// time go too (timing one stops first); without, they stay in the order as they are, and their
    /// Time to log entries stay: kept local, or sent once Jira is connected to the same site again.
    /// A Log still saving or waiting for the Keychain sends nothing (`canStillSend`); one whose
    /// request is already out cannot be recalled, and its answer is dropped with the entry.
    func disconnectJira(removeTasks: Bool) {
        jiraGeneration += 1
        jiraSyncInFlight = nil
        pendingJiraSyncWhenReady = false
        lastJiraSync = nil
        jiraSync = .idle
        Defaults[.jiraEnabled] = false
        Defaults[.jiraSiteHost] = ""
        Defaults[.jiraAccountID] = ""
        Defaults[.jiraAccountDisplayName] = ""
        removeJiraToken()
        logger.info("Jira disconnected, tasks removed: \(removeTasks, privacy: .public)")
        guard removeTasks, isReady else { return }
        if let timed = timing?.taskID, tasks.first(where: { $0.id == timed })?.source == .jira {
            stopTiming()
        }
        let removed = Set(tasks.filter { $0.source == .jira }.map(\.id))
        guard !removed.isEmpty else { return }
        if let pending = pendingLink, removed.contains(pending.taskID) { pendingLink = nil }
        tasks.removeAll { removed.contains($0.id) }
        drafts.removeAll { removed.contains($0.taskID) }
        persist()
    }

    /// Disconnect could not delete the saved token: the user asks again. The delete may raise the
    /// Keychain dialog (an item saved by a differently signed build); it runs off the main actor.
    func retryRemovingJiraToken() {
        guard !isJiraConnected else { return }
        removeJiraToken()
    }

    /// Deletes the saved token off the main actor, and says so when it could not. A result that
    /// lands after a new Connect is dropped: that Connect saved a token of its own.
    private func removeJiraToken() {
        let generation = jiraGeneration
        jiraTokenRemovalFailed = false
        Task { [weak self] in
            let removed = await JiraCredentialStore.remove()
            guard let self, generation == self.jiraGeneration else { return }
            self.jiraTokenRemovalFailed = !removed
            if !removed { self.logger.error("Jira: the saved sign-in could not be removed from the Keychain") }
        }
    }

    /// The issue's page, built from the host the task came from, or nil for anything else.
    func jiraBrowseURL(for task: TaskItem) -> URL? {
        guard task.source == .jira, let remote = task.remote else { return nil }
        return JiraSite.browseURL(host: remote.hostScope, key: remote.key)
    }

    private func syncJira(interactive: Bool, using known: JiraCredential?) {
        let generation = jiraGeneration
        jiraSyncInFlight = generation
        jiraSync = .syncing
        let expectedHost = Defaults[.jiraSiteHost]
        let jql = JiraAPI.effectiveJQL(Defaults[.jiraJQL])
        Task { [weak self] in
            let credential: JiraCredential
            if let known {
                credential = known
            } else {
                switch await JiraCredentialStore.load(allowInteraction: interactive) {
                case .found(let stored):
                    credential = stored
                case .needsApproval:
                    self?.finishJiraSync(generation, .needsKeychainApproval)
                    return
                case .missing, .broken:
                    self?.finishJiraSync(generation, .needsReconnect)
                    return
                }
            }
            // The Keychain's host is the only one a token is sent to. A Defaults copy that
            // disagrees means the setup changed under Kannu: reconnect, never a request elsewhere.
            guard credential.site == expectedHost, JiraSite.isValidHost(credential.site) else {
                self?.finishJiraSync(generation, .needsReconnect)
                return
            }
            let result = await JiraClient().fetchIssues(credential, jql: jql)
            self?.didFetchJira(result.outcome, failure: result.failure, host: credential.site, generation: generation)
        }
    }

    private func finishJiraSync(_ generation: Int, _ state: SourceSyncState) {
        guard generation == jiraGeneration else { return }
        jiraSyncInFlight = nil
        jiraSync = state
    }

    private func didFetchJira(_ outcome: SyncOutcome, failure: JiraClient.Failure?, host: String, generation: Int) {
        // Connected again or disconnected meanwhile: this result belongs to a setup that is gone.
        guard generation == jiraGeneration else { return }
        let now = Date()
        guard case .fetched(let fetch) = outcome else {
            finishJiraSync(generation, Self.syncState(for: failure, now: now))
            logger.notice("Jira sync failed")
            return
        }
        guard isReady else {
            finishJiraSync(generation, .failed(String(localized: "Kannu could not read its task list, so Jira issues cannot be added to it.")))
            return
        }
        // The task being timed stays in the order however the issue changed: its row holds the
        // list's Stop button. The first sync after its timing ends decides.
        let timed = Set([timing?.taskID, pendingLink?.taskID].compactMap { $0 })
        let merged = TaskMerge.apply(outcome, source: .jira, hostScope: host, to: tasks, now: now, keepingActive: timed)
        tasks = merged.tasks
        if merged.changed { persist() }
        lastJiraSync = now
        finishJiraSync(generation, .synced(at: now, count: fetch.issues.count, complete: fetch.complete))
        logger.info("Jira sync: \(fetch.issues.count, privacy: .public) issues, complete \(fetch.complete, privacy: .public), \(merged.added, privacy: .public) added, \(merged.updated, privacy: .public) updated, \(merged.gone, privacy: .public) gone")
    }

    private static func syncState(for failure: JiraClient.Failure?, now: Date) -> SourceSyncState {
        switch failure {
        case .http(.offline):
            return .offline
        case .http(.rateLimited(let seconds)):
            return .rateLimited(until: now.addingTimeInterval(seconds))
        case .http(.auth(let status)):
            return .authFailed(status: status)
        case .http(.rejected(400)):
            return .failed(String(localized: "Jira refused the issue filter (400). Check it under Advanced, or reset it."))
        case .http(.rejected(let status)):
            return .failed(String(localized: "Jira refused the request (\(status)). The account may have lost access to this site."))
        case .http(.redirected(let status)):
            return .failed(String(localized: "The site answered with a redirect (\(status)), which Kannu never follows."))
        case .http(.failedBeforeSend):
            return .failed(String(localized: "Kannu could not reach the Jira site. Check your connection."))
        case .http(.ambiguous(let status?)):
            return .failed(String(localized: "Jira did not answer properly (\(status)). Try again later."))
        case .http(.ambiguous(nil)), .http(.ok):
            return .failed(String(localized: "Jira did not answer in time. Try again later."))
        case .decode:
            return .failed(String(localized: "Jira's answer could not be read."))
        case .badSite, nil:
            return .needsReconnect
        }
    }

    private static func message(for error: JiraSiteError) -> String {
        switch error {
        case .empty:
            return String(localized: "Type your Jira site, such as acme or acme.atlassian.net.")
        case .notHTTPS:
            return String(localized: "Kannu connects to Jira over HTTPS only.")
        case .userInfo:
            return String(localized: "The site has a name and @ before the host. Type just the site, such as acme.atlassian.net.")
        case .port:
            return String(localized: "Jira Cloud uses the standard HTTPS port. Remove the port from the site.")
        case .notAtlassianCloud, .malformed:
            return String(localized: "That is not a Jira Cloud site. It looks like acme.atlassian.net.")
        }
    }

    private static func connectMessage(for failure: JiraClient.Failure, host: String) -> String {
        switch failure {
        case .badSite:
            return message(for: .notAtlassianCloud)
        case .decode, .http(.ok):
            return String(localized: "\(host) answered, but not the way Jira Cloud does. Check the site.")
        case .http(.auth(let status)):
            return String(localized: "Jira did not accept that email and token (\(status)). Check both, or create a new token.")
        case .http(.rejected(404)):
            return String(localized: "No Jira site answered at \(host) (404). Check the site.")
        case .http(.rejected(let status)):
            return String(localized: "Jira refused the request (\(status)).")
        case .http(.redirected(let status)):
            return String(localized: "\(host) answered with a redirect (\(status)), which Kannu never follows. Check the site.")
        case .http(.rateLimited):
            return String(localized: "Jira is limiting requests right now. Try again in a minute.")
        case .http(.offline):
            return String(localized: "This Mac is offline.")
        case .http(.failedBeforeSend):
            return String(localized: "Kannu could not reach \(host). Check the site and your connection.")
        case .http(.ambiguous):
            return String(localized: "Jira did not answer. Try again.")
        }
    }

    // MARK: - GitLab

    /// Connected, as far as the display copies say. The Keychain has the final word at sync time.
    var isGitLabConnected: Bool { !Defaults[.gitlabHost].isEmpty }

    /// Connected and "Sync GitLab" on.
    var isGitLabSyncOn: Bool { isGitLabConnected && Defaults[.gitlabEnabled] }

    var isGitLabSyncing: Bool { gitlabSyncInFlight == gitlabGeneration }

    /// The page appeared. Syncs when GitLab is on, nothing is in flight, and
    /// `SourceSyncState.allowsSyncOnAppear` agrees: the last sync is over 5 minutes old, no rate
    /// limit is running, and GitLab has not refused the token. Never shows the Keychain dialog: a
    /// read that would need it ends in `.needsKeychainApproval`, and the user's click retries.
    func syncGitLabIfStale(now: Date = Date()) {
        guard isGitLabSyncOn, !isGitLabSyncing else { return }
        guard isReady else {
            if loadState == .loading { pendingGitLabSyncWhenReady = true }
            return
        }
        guard gitlabSync.allowsSyncOnAppear(lastSuccess: lastGitLabSync, now: now, staleAfter: Self.jiraStaleAfter) else { return }
        syncGitLab(interactive: false, using: nil)
    }

    /// Refresh, Allow Keychain Access, and Include merge requests switched: the user asked, so the
    /// Keychain may ask them too.
    func refreshGitLab(now: Date = Date()) {
        guard isGitLabSyncOn, isReady, !isGitLabSyncing else { return }
        if case .rateLimited(let until) = gitlabSync, until > now { return }
        syncGitLab(interactive: true, using: nil)
    }

    /// Include merge requests was switched. The task order follows at once (`listed`); what is
    /// fetched follows with a sync, started now when one can run. A sync already in flight read the
    /// old setting, so its result is dropped and a new one starts. Until a sync succeeds with the new
    /// setting, the next page visit syncs again: offline, a rate limit or Sync GitLab off only delay
    /// it.
    func gitlabMergeRequestsSwitched(now: Date = Date()) {
        if isGitLabSyncing {
            gitlabGeneration += 1
            gitlabSyncInFlight = nil
            gitlabSync = .idle
        }
        lastGitLabSync = nil
        refreshGitLab(now: now)
    }

    /// Checks the server and token with GitLab, then stores them and syncs. Nil on success, or what
    /// to tell the user. Nothing is stored until GitLab has accepted the token, and a token that can
    /// list nothing is refused.
    func connectGitLab(serverInput: String, token: String) async -> String? {
        let base: String
        switch GitLabHost.normalize(serverInput) {
        case .success(let normalized): base = normalized
        case .failure(let error): return Self.message(for: error)
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
        let user: GitLabUser
        let access: GitLabAccess
        switch await GitLabClient().verify(credential) {
        case .verified(let verified, let scopes):
            user = verified
            access = GitLabAPI.access(scopes: scopes)
        case .failed(let failure):
            return Self.gitlabConnectMessage(for: failure, server: server)
        }
        guard access != .cannotList else {
            return String(localized: "This token cannot list your issues. Create one with the read_api scope, or api to log time later.")
        }
        guard GitLabAPI.isUsername(user.username) else {
            return String(localized: "\(server) answered, but not the way GitLab does. Check the server.")
        }
        guard !Task.isCancelled else { return String(localized: "Cancelled.") }
        guard await GitLabCredentialStore.save(credential) else {
            return String(localized: "GitLab accepted the token, but Kannu could not save it in your Keychain.")
        }
        Defaults[.gitlabHost] = base
        Defaults[.gitlabUsername] = user.username
        Defaults[.gitlabAccountDisplayName] = user.name ?? ""
        Defaults[.gitlabCanLogTime] = access == .canLogTime
        Defaults[.gitlabEnabled] = true
        gitlabGeneration += 1
        gitlabSyncInFlight = nil
        lastGitLabSync = nil
        gitlabSync = .idle
        // The save replaced whatever a failed Disconnect left in the Keychain.
        gitlabTokenRemovalFailed = false
        logger.info("GitLab connected, can log time: \(access == .canLogTime, privacy: .public)")
        if isReady {
            // The credential is in hand: no Keychain read for the first sync.
            syncGitLab(interactive: false, using: credential)
        } else if loadState == .loading {
            pendingGitLabSyncWhenReady = true
        }
        return nil
    }

    /// Forgets the token and stops syncing. With `removeTasks`, the GitLab tasks and their unlogged
    /// time go too (timing one stops first); without, they stay in the order as they are, and their
    /// Time to log entries stay: kept local, or sent once GitLab is connected to the same server.
    /// A Log still saving or waiting for the Keychain sends nothing (`canStillSend`); one whose
    /// request is already out cannot be recalled, and its answer is dropped with the entry.
    func disconnectGitLab(removeTasks: Bool) {
        gitlabGeneration += 1
        gitlabSyncInFlight = nil
        pendingGitLabSyncWhenReady = false
        lastGitLabSync = nil
        gitlabSync = .idle
        Defaults[.gitlabEnabled] = false
        Defaults[.gitlabHost] = ""
        Defaults[.gitlabUsername] = ""
        Defaults[.gitlabAccountDisplayName] = ""
        Defaults[.gitlabCanLogTime] = false
        removeGitLabToken()
        logger.info("GitLab disconnected, tasks removed: \(removeTasks, privacy: .public)")
        guard removeTasks, isReady else { return }
        if let timed = timing?.taskID, tasks.first(where: { $0.id == timed })?.source == .gitlab {
            stopTiming()
        }
        let removed = Set(tasks.filter { $0.source == .gitlab }.map(\.id))
        guard !removed.isEmpty else { return }
        if let pending = pendingLink, removed.contains(pending.taskID) { pendingLink = nil }
        tasks.removeAll { removed.contains($0.id) }
        drafts.removeAll { removed.contains($0.taskID) }
        persist()
    }

    /// Disconnect could not delete the saved token: the user asks again, off the main actor.
    func retryRemovingGitLabToken() {
        guard !isGitLabConnected else { return }
        removeGitLabToken()
    }

    /// Deletes the saved token off the main actor, and says so when it could not. A result that
    /// lands after a new Connect is dropped: that Connect saved a token of its own.
    private func removeGitLabToken() {
        let generation = gitlabGeneration
        gitlabTokenRemovalFailed = false
        Task { [weak self] in
            let removed = await GitLabCredentialStore.remove()
            guard let self, generation == self.gitlabGeneration else { return }
            self.gitlabTokenRemovalFailed = !removed
            if !removed { self.logger.error("GitLab: the saved sign-in could not be removed from the Keychain") }
        }
    }

    /// The item's page, only when it is on the server the task came from.
    func gitlabBrowseURL(for task: TaskItem) -> URL? {
        guard task.source == .gitlab, let remote = task.remote, let link = remote.gitlabWebURL,
              GitLabHost.isWebURL(link, onServer: remote.hostScope) else { return nil }
        return URL(string: link)
    }

    private func syncGitLab(interactive: Bool, using known: GitLabCredential?) {
        let generation = gitlabGeneration
        gitlabSyncInFlight = generation
        gitlabSync = .syncing
        let expectedBase = Defaults[.gitlabHost]
        let username = Defaults[.gitlabUsername]
        let includeMergeRequests = Defaults[.gitlabIncludeMergeRequests]
        Task { [weak self] in
            let credential: GitLabCredential
            if let known {
                credential = known
            } else {
                switch await GitLabCredentialStore.load(allowInteraction: interactive) {
                case .found(let stored):
                    credential = stored
                case .needsApproval:
                    self?.finishGitLabSync(generation, .needsKeychainApproval)
                    return
                case .missing, .broken:
                    self?.finishGitLabSync(generation, .needsReconnect)
                    return
                }
            }
            // The Keychain's server is the only one a token is sent to. A Defaults copy that
            // disagrees means the setup changed under Kannu: reconnect, never a request elsewhere.
            guard credential.baseURL == expectedBase, GitLabHost.isValidBase(credential.baseURL) else {
                self?.finishGitLabSync(generation, .needsReconnect)
                return
            }
            let fetch = await GitLabClient().fetchItems(credential, username: username, includeMergeRequests: includeMergeRequests)
            self?.didFetchGitLab(fetch, base: credential.baseURL, generation: generation)
        }
    }

    private func finishGitLabSync(_ generation: Int, _ state: SourceSyncState) {
        guard generation == gitlabGeneration else { return }
        gitlabSyncInFlight = nil
        gitlabSync = state
    }

    private func didFetchGitLab(_ fetched: GitLabReader.Fetch, base: String, generation: Int) {
        // Connected again or disconnected meanwhile: this result belongs to a setup that is gone.
        guard generation == gitlabGeneration else { return }
        let now = Date()
        guard case .fetched(let fetch) = fetched.outcome else {
            finishGitLabSync(generation, Self.gitlabSyncState(for: fetched.failure, now: now))
            logger.notice("GitLab sync failed")
            return
        }
        guard isReady else {
            finishGitLabSync(generation, .failed(String(localized: "Kannu could not read its task list, so GitLab items cannot be added to it.")))
            return
        }
        // The task being timed stays in the order however the item changed: its row holds the
        // list's Stop button. The first sync after its timing ends decides.
        let timed = Set([timing?.taskID, pendingLink?.taskID].compactMap { $0 })
        let merged = TaskMerge.apply(fetched.outcome, source: .gitlab, hostScope: base, to: tasks, now: now, keepingActive: timed)
        tasks = merged.tasks
        if merged.changed { persist() }
        lastGitLabSync = now
        finishGitLabSync(generation, .synced(at: now, count: fetch.issues.count, complete: fetch.complete))
        logger.info("GitLab sync: \(fetched.issueCount, privacy: .public) issues, \(fetched.mergeRequestCount, privacy: .public) merge requests, complete \(fetch.complete, privacy: .public), \(merged.added, privacy: .public) added, \(merged.updated, privacy: .public) updated, \(merged.gone, privacy: .public) gone")
    }

    private static func gitlabSyncState(for failure: GitLabReader.Failure?, now: Date) -> SourceSyncState {
        switch failure {
        case .http(.offline):
            return .offline
        case .http(.rateLimited(let seconds)):
            return .rateLimited(until: now.addingTimeInterval(seconds))
        case .http(.auth(let status)):
            return .authFailed(status: status)
        case .http(.rejected(403)):
            return .failed(String(localized: "GitLab refused the request (403). The token may lack the read_api scope, or have lost access."))
        case .http(.rejected(let status)):
            return .failed(String(localized: "GitLab refused the request (\(status))."))
        case .http(.redirected(let status)):
            return .failed(String(localized: "The server answered with a redirect (\(status)), which Kannu never follows."))
        case .http(.failedBeforeSend):
            return .failed(String(localized: "Kannu could not reach the GitLab server over a trusted HTTPS connection. Check your connection."))
        case .http(.ambiguous(let status?)):
            return .failed(String(localized: "GitLab did not answer properly (\(status)). Try again later."))
        case .http(.ambiguous(nil)), .http(.ok):
            return .failed(String(localized: "GitLab did not answer in time. Try again later."))
        case .decode:
            return .failed(String(localized: "GitLab's answer could not be read."))
        case .badServer, .badUsername, nil:
            return .needsReconnect
        }
    }

    private static func message(for error: GitLabHostError) -> String {
        switch error {
        case .empty:
            return String(localized: "Type your GitLab server, such as https://gitlab.com or https://gitlab.example.com.")
        case .notHTTPS:
            return String(localized: "Kannu connects to GitLab over HTTPS only.")
        case .userInfo:
            return String(localized: "The server has a name and @ before the host. Type just the server, such as https://gitlab.example.com.")
        case .queryOrFragment, .badPath:
            return String(localized: "Type the server's address, not a page on it, such as https://gitlab.example.com or https://example.com/gitlab.")
        case .port:
            return String(localized: "That port is not a valid one.")
        case .malformed:
            return String(localized: "That is not a server address. It looks like https://gitlab.example.com.")
        }
    }

    private static func gitlabConnectMessage(for failure: GitLabReader.Failure, server: String) -> String {
        switch failure {
        case .badServer:
            return message(for: GitLabHostError.malformed)
        case .badUsername, .decode, .http(.ok):
            return String(localized: "\(server) answered, but not the way GitLab does. Check the server.")
        case .http(.auth(let status)):
            return String(localized: "GitLab did not accept that token (\(status)). It may have expired or been revoked: create a new one.")
        case .http(.rejected(403)):
            return String(localized: "GitLab refused the token (403). Create one with the read_api scope, or api to log time later.")
        case .http(.rejected(404)):
            return String(localized: "No GitLab answered at \(server) (404). Check the server, and its path if it has one.")
        case .http(.rejected(let status)):
            return String(localized: "GitLab refused the request (\(status)).")
        case .http(.redirected(let status)):
            return String(localized: "\(server) answered with a redirect (\(status)), which Kannu never follows. Check the server, and its path if it has one.")
        case .http(.rateLimited):
            return String(localized: "GitLab is limiting requests right now. Try again in a minute.")
        case .http(.offline):
            return String(localized: "This Mac is offline.")
        case .http(.failedBeforeSend):
            return String(localized: "Kannu could not reach \(server) over a trusted HTTPS connection. Check the server and your connection. A certificate macOS does not trust, such as a self-signed one, is refused.")
        case .http(.ambiguous):
            return String(localized: "GitLab did not answer. Try again.")
        }
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
        loadState = .ready
        let uncertain = normalized.filter { $0.state == .uncertain }.count
        logger.info("Loaded \(file.tasks.count, privacy: .public) tasks, \(interrupted, privacy: .public) interrupted sessions, \(uncertain, privacy: .public) uncertain entries")
        if interrupted > 0 || normalized != file.drafts || loadedTasks != file.tasks { persist() }
        if pendingJiraSyncWhenReady {
            pendingJiraSyncWhenReady = false
            syncJiraIfStale()
        }
        if pendingGitLabSyncWhenReady {
            pendingGitLabSyncWhenReady = false
            syncGitLabIfStale()
        }
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
