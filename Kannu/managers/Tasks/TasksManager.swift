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
    @Published private(set) var jiraSync: JiraSyncState = .idle
    /// Disconnect could not delete the saved token from the Keychain, so it is still there.
    @Published private(set) var jiraTokenRemovalFailed = false

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

    /// A sync older than this is refreshed when the Tasks page appears.
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
        Publishers.Merge3(
            Defaults.publisher(.showLocalTasks, options: []).map { _ in () },
            Defaults.publisher(.jiraEnabled, options: []).map { _ in () },
            Defaults.publisher(.jiraSiteHost, options: []).map { _ in () }
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

    /// Whether the task order shows this task: Local tasks and Sync Jira decide by source. The
    /// moves use the same filter, so a task the user cannot see never shifts one.
    func isListed(_ task: TaskItem) -> Bool { listed(task) }

    private var listed: TaskOrdering.Listed {
        TaskOrdering.listedFilter(
            showLocal: Defaults[.showLocalTasks],
            showJira: Defaults[.jiraEnabled] || !isJiraConnected,
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

    // MARK: - Jira

    /// Connected, as far as the display copies say. The Keychain has the final word at sync time.
    var isJiraConnected: Bool { !Defaults[.jiraSiteHost].isEmpty }

    /// Connected and "Sync Jira" on.
    var isJiraSyncOn: Bool { isJiraConnected && Defaults[.jiraEnabled] }

    var isJiraSyncing: Bool { jiraSyncInFlight == jiraGeneration }

    /// The page appeared. Syncs when Jira is on, nothing is in flight, and
    /// `JiraSyncState.allowsSyncOnAppear` agrees: the last sync is over 5 minutes old, no rate limit
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
    /// time go too (timing one stops first); without, they stay in the order as they are.
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

    private func finishJiraSync(_ generation: Int, _ state: JiraSyncState) {
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

    private static func syncState(for failure: JiraClient.Failure?, now: Date) -> JiraSyncState {
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
        if pendingJiraSyncWhenReady {
            pendingJiraSyncWhenReady = false
            syncJiraIfStale()
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
