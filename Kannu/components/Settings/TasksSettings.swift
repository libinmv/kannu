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
import SwiftUI

/// Brain › Tasks, as a tree: Source › Project › Task. The overview lists where tasks come from —
/// Local tasks, Jira Cloud, GitLab — each with how many it holds and a › to its page, then All
/// tasks, Time to log, Interrupted sessions and the Tasks options. A source's page holds its
/// connection, then its projects (or its tasks, with one project or none); a project's page its
/// tasks; a task's page everything about it (`TaskDetailPage`). All tasks is every source in one
/// order, with Find and the filters (`AllTasksPage`).
///
/// Brain has no navigation stack, so the tree is an in-tab view swap on `path`: empty is the
/// overview, opening a page appends it, and the back row atop every page goes up one level and
/// names where it goes ("‹ GitLab"); going back scrolls to the row that was opened. Search lands on
/// the overview's rows (the Advanced precedent, docs/SETTINGS.md), so any Tasks search or deep link
/// returns to the overview — except `SettingsDeepLink.tasksListOpenID`, which opens All tasks
/// ("Show all in Brain", a reminder's click).
///
/// Built only from the `SettingsComponents` shapes (docs/SETTINGS.md). Task titles are the user's
/// own text and render verbatim. With tasks off nothing here touches `TasksManager`, so the tab
/// never reads the task file. None of the Tasks pages reads the Keychain: a sync does, off the main
/// actor, in `TasksManager`.
struct TasksSettings: View {
    @Default(.enableTasks) private var enableTasks
    @Default(.tasksDefaultSessionMinutes) private var defaultSessionMinutes

    // On the Form, not on a row: rows of a long, lazy Form may not exist when these change.
    @State private var sheet: TaskSheet?
    @State private var pendingDelete: TaskItem?
    /// New Task's draft, kept between sheets so Cancel loses nothing. A box in `@State`, deliberately
    /// not `@StateObject`: this tab must not observe it, so typing redraws the sheet alone
    /// (`NewTaskSheet` observes it). A throwaway box made on a re-init is harmless; `@State` keeps
    /// the first.
    @State private var newTask = NewTaskDraft()
    /// The source whose Disconnect… was clicked, while its dialog asks what to keep.
    @State private var confirmsDisconnect: TaskSource?
    /// The pages opened below the overview; empty is the overview.
    @State private var path: [TasksPage] = []
    /// All tasks' Find field. Here, not on the page, so it survives a look at a task and back.
    @State private var query = ""
    /// The row to bring into view once the next page has appeared: the one that opened the page
    /// just left, or the row a search or deep link names.
    @State private var returnTo: AnyHashable?
    @ObservedObject private var highlights = SettingsHighlightCoordinator.shared

    private func highlightID(_ title: String) -> String { "tasks-\(title)" }

    /// ⌘N, New Task, on the Form rather than on Add a task's button: that row scrolls out of a long,
    /// lazy Form and would take a shortcut on its button with it. Only on the pages that have the
    /// row. The filter is read when pressed, so this tab observes neither the filters nor the
    /// manager (with Tasks off, nothing here touches `TasksManager`).
    @ViewBuilder
    private var newTaskShortcut: some View {
        if enableTasks, let page = path.last, page == .allTasks || page == .source(.local) {
            Button("New Task") {
                guard sheet == nil, TasksManager.shared.isReady else { return }
                sheet = .newTask(listFilter: page == .allTasks ? AllTasksPage.savedFilter(query: query) : .all)
            }
            .keyboardShortcut("n", modifiers: .command)
            // Invisible but in the hierarchy, so the shortcut still resolves.
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    private var context: TasksPageContext {
        TasksPageContext(
            sheet: $sheet,
            pendingDelete: $pendingDelete,
            confirmsDisconnect: $confirmsDisconnect,
            open: { path.append($0) },
            connect: { sheet = .connect($0) }
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                if enableTasks, let page = path.last {
                    Section {
                        backRow(from: page)
                    }
                    pageContent(page)
                } else {
                    overview
                }
            }
            // The page just built has appeared: the row it should show, in view. After this
            // update, so the row exists.
            .onAppear {
                guard let target = returnTo else { return }
                returnTo = nil
                DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center) }
            }
            .background { newTaskShortcut }
            // A page opens at its top.
            .id(path)
        }
        .navigationTitle(Text(verbatim: enableTasks ? path.last.map(Self.title) ?? Self.overviewTitle : Self.overviewTitle))
        // Search and deep links land on the overview's rows, never inside a page; only All tasks'
        // own deep link opens it. Settings scrolled before the page changed, so the rebuilt page
        // scrolls to the row again. `initial`: the link may arrive before this tab is built.
        .onChange(of: highlights.activeHighlightID, initial: true) { _, id in
            guard let id, id.hasPrefix(highlightID("")) else { return }
            let wasOpen = path
            path = id == SettingsDeepLink.tasksListOpenID ? [.allTasks] : []
            if path != wasOpen { returnTo = id }
        }
        // Tasks off: every reminder, waiting or on screen, is taken back, and the tree closes.
        // `TaskReminders` only — this never builds `TasksManager`.
        .onChange(of: enableTasks) { _, isOn in
            path = []
            if !isOn { TaskReminders.withdrawAll() }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .connect(.jira):
                JiraConnectSheet()
            case .connect(.gitlab):
                GitLabConnectSheet()
            case .connect(let source):
                SourceConnectSheet(source: source)
            case .tags(let taskID, let title, let current, let existing):
                TaskTagsSheet(taskID: taskID, title: title, current: current, existing: existing)
            case .newTask(let listFilter):
                NewTaskSheet(newTask: newTask, listFilter: listFilter) { path.append(.task($0)) }
            default:
                TaskValueSheet(sheet: sheet) { value in apply(value, from: sheet) }
            }
        }
        .alert(
            Text(verbatim: String(localized: "Delete “\(pendingDelete?.title ?? "")”?")),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { task in
            Button("Delete", role: .destructive) {
                TasksManager.shared.delete(task.id)
                // Its page, if open, has nothing left to show.
                path.removeAll { $0 == .task(task.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its recorded time is deleted too.")
        }
        .confirmationDialog(
            Text(verbatim: String(localized: "Disconnect \(confirmsDisconnect?.name ?? "")?")),
            isPresented: Binding(get: { confirmsDisconnect != nil }, set: { if !$0 { confirmsDisconnect = nil } }),
            titleVisibility: .visible,
            presenting: confirmsDisconnect
        ) { source in
            Button(String(localized: "Keep \(source.name) Tasks")) { disconnect(source, removeTasks: false) }
            Button(String(localized: "Remove \(source.name) Tasks"), role: .destructive) { disconnect(source, removeTasks: true) }
            Button("Cancel", role: .cancel) {}
        } message: { source in
            Text(verbatim: source.usesToken
                 ? String(localized: "Kannu forgets the token. Keep the \(source.name) tasks and their time, or remove them.")
                 : String(localized: "Kannu stops reading \(source.name). Keep its tasks and their time, or remove them."))
        }
    }

    // MARK: - The tree

    /// Up one level, to the page it names, which scrolls to the row that opened this one. All tasks'
    /// back row carries the page's own deep link, so an opened link lands on it.
    @ViewBuilder
    private func backRow(from page: TasksPage) -> some View {
        let parent = path.dropLast().last.map(Self.title) ?? Self.overviewTitle
        let row = TasksBackRow(parent: parent) { returnTo = Self.scrollTarget(of: path.removeLast()) }
        if page == .allTasks {
            row.settingsHighlight(id: SettingsDeepLink.tasksListOpenID)
        } else {
            row
        }
    }

    @ViewBuilder
    private func pageContent(_ page: TasksPage) -> some View {
        switch page {
        case .source(let source):
            TaskSourcePage(source: source, context: context)
        case .project(let source, let project):
            TaskProjectPage(source: source, project: project, context: context)
        case .task(let id):
            TaskDetailPage(taskID: id, context: context)
        case .allTasks:
            AllTasksPage(query: $query, context: context)
        }
    }

    private static var overviewTitle: String { String(localized: "Tasks") }

    /// What a page is called, in its back row's child and in the window's title.
    static func title(of page: TasksPage) -> String {
        switch page {
        case .source(let source): return source.title
        case .project(_, let project): return TaskFacets.projectShortName(project)
        case .task: return String(localized: "Task")
        case .allTasks: return String(localized: "All tasks")
        }
    }

    /// The row that opened a page: a source or All tasks by its highlight id, a project by its
    /// page, a task by its id.
    private static func scrollTarget(of page: TasksPage) -> AnyHashable {
        switch page {
        case .source(let source): return SettingsDeepLink.taskSourceRows[source] ?? SettingsDeepLink.tasksSourcesHighlightID
        case .project: return page
        case .task(let id): return id
        case .allTasks: return SettingsDeepLink.tasksListHighlightID
        }
    }

    // MARK: - The overview

    @ViewBuilder
    private var overview: some View {
        if enableTasks {
            TaskSourcesSection(context: context)
            TaskOverviewSections(sheet: $sheet, openAllTasks: { path.append(.allTasks) })
        }

        Section {
            SettingsRow("Enable tasks", description: "Plan your work and time it.") {
                Defaults.Toggle(key: .enableTasks) {
                    Text("Enable tasks")
                }
            }
            .settingsHighlight(id: highlightID("Enable tasks"))

            SettingsStepperRow(
                "Default session length",
                description: "Timer length when a task has no estimate.",
                value: $defaultSessionMinutes,
                in: 5...240,
                step: 5,
                valueText: Text("\(defaultSessionMinutes) min")
            )
            .settingsHighlight(id: highlightID("Default session length"))

            SettingsRow("Sound when the estimate is reached", description: "Play the timer sound at the estimate.") {
                Defaults.Toggle(key: .tasksSoundAtEstimate) {
                    Text("Sound when the estimate is reached")
                }
            }
            .settingsHighlight(id: highlightID("Sound when the estimate is reached"))
        } header: {
            SettingsSectionHeader("Tasks")
        } footer: {
            SettingsFooter("Tasks and their time stay on this Mac.")
        }
    }

    /// Disconnect, from the dialog: the source's page, if open, leaves with its tasks.
    private func disconnect(_ source: TaskSource, removeTasks: Bool) {
        TasksManager.shared.disconnect(source, removeTasks: removeTasks)
        path.removeAll { page in
            switch page {
            case .source(let shown), .project(let shown, _): return shown == source
            case .task, .allTasks: return false
            }
        }
    }

    private func apply(_ value: TaskValueSheet.Value, from sheet: TaskSheet) {
        switch (sheet, value) {
        case (.estimate(let taskID, _, _), .duration(let seconds)):
            TasksManager.shared.setEstimate(seconds, for: taskID)
        case (.addTime(let taskID, _), .duration(let seconds)):
            if let seconds { TasksManager.shared.addManualTime(seconds, to: taskID) }
        case (.endTime(let taskID, let segmentID, _, _, _), .date(let end)):
            TasksManager.shared.setEndTime(end, segmentID: segmentID, taskID: taskID)
        case (.schedule(let taskID, _, _), .date(let date)):
            TasksManager.shared.setSchedule(date, for: taskID)
        case (.schedule(let taskID, _, _), .cleared):
            TasksManager.shared.setSchedule(nil, for: taskID)
        default:
            break
        }
    }
}

/// A page of Brain › Tasks below the overview.
enum TasksPage: Hashable {
    /// A source's connection, then its projects — or its tasks, with one project or none.
    case source(TaskSource)
    /// One project's tasks: a key as `TaskFacets.project` gives it, or `TaskFacets.noProject`.
    case project(TaskSource, String)
    /// One task, opened from any list.
    case task(UUID)
    /// Every source's tasks in one order, with Find and the filters.
    case allTasks
}

/// What a page needs from the tab. The sheets (New Task's draft with them) and the alerts live on
/// the outer Form, because rows of a long, lazy Form may not exist when they change; `open` goes
/// one level in.
struct TasksPageContext {
    let sheet: Binding<TaskSheet?>
    let pendingDelete: Binding<TaskItem?>
    let confirmsDisconnect: Binding<TaskSource?>
    let open: (TasksPage) -> Void
    /// Connect…: the source's own sheet (a token, or Apple Reminders' permission).
    let connect: (TaskSource) -> Void
}

/// Atop every page, alone in its own Section: up one level, naming where it goes ("‹ GitLab"). The
/// one sanctioned lone leading button in Brain (docs/SETTINGS.md): it is navigation, not an action
/// on a row.
struct TasksBackRow: View {
    let parent: String
    let back: () -> Void

    var body: some View {
        Button(action: back) {
            Label {
                Text(verbatim: parent)
            } icon: {
                Image(systemName: "chevron.left")
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(verbatim: String(localized: "Back to \(parent)")))
    }
}

/// "40 open ›": a row's way into its page.
struct TasksOpenButton: View {
    let text: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SettingsMetrics.iconGap) {
                Text(verbatim: text)
                Image(systemName: "chevron.right")
            }
        }
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
    }
}

/// The overview's Sources: Local tasks, then each connected source with how many tasks it holds and a
/// › to its page, where its connection and settings are; then "Add a source", a Connect menu of the
/// sources not connected. A source not connected has no row of its own: its search entries land on
/// Add a source (`SettingsView.landingOnABuiltRow`), and tasks it kept from before stay in All tasks.
/// A separate view so `TasksManager` is created only once tasks are turned on.
///
/// Status comes from the Defaults display copies and the manager's sync state, never from the
/// Keychain (`TaskSourceStatus`). A source's row appearing asks for a sync only when the last one is
/// stale; a problem shows here as "Needs attention" and in full on the source's page. Each row
/// registers its own deep link, literally (`highlighted(_:for:)`), so search and the inventory test
/// find it.
private struct TaskSourcesSection: View {
    @ObservedObject private var manager = TasksManager.shared
    let context: TasksPageContext

    var body: some View {
        let counts = TaskFacets.sourceCounts(manager.activeTasks)
        let sources = manager.syncs.map(\.source)
        let connected = sources.filter(\.isConnected)
        let addable = sources.filter { !$0.isConnected }
        Section {
            LabeledContent {
                openButton(count: counts[.local] ?? 0, page: .source(.local))
            } label: {
                SettingsRowLabel("Local tasks", description: "Tasks you add here or in the notch.")
            }
            .settingsHighlight(id: SettingsDeepLink.tasksSourcesHighlightID)

            ForEach(connected, id: \.self) { source in
                highlighted(sourceRow(source, count: counts[source] ?? 0), for: source)
            }

            ForEach(addable.filter { manager.tokenRemovalFailed($0) }, id: \.self) { source in
                SettingsErrorText(String(localized: "Couldn't remove the \(source.name) token from your Keychain."))
                SettingsActionRow(
                    "Saved token",
                    description: String(localized: "Or delete com.kannu.app.secure-secrets (\(TaskSourceStatus.keychainItem(for: source))) in Keychain Access.")
                ) {
                    Button("Remove Token") { manager.retryRemovingToken(source) }
                }
            }

            if !addable.isEmpty {
                LabeledContent {
                    Menu("Connect…") {
                        ForEach(addable, id: \.self) { source in
                            Button(source.title) { context.connect(source) }
                        }
                    }
                    .fixedSize()
                } label: {
                    SettingsRowLabel("Add a source", description: Text(verbatim: addable.map(\.title).formatted(.list(type: .or))))
                }
                .settingsHighlight(id: SettingsDeepLink.tasksAddSourceHighlightID)
            }
        } header: {
            SettingsSectionHeader("Sources")
        } footer: {
            SettingsFooterStack {
                SettingsFooter("Tokens stay in your Keychain. Kannu writes nothing until you choose Log.")
                SettingsFooter("Make tokens just for Kannu, with an expiry date.")
            }
        }
    }

    private func openButton(count: Int, page: TasksPage) -> some View {
        TasksOpenButton(
            text: String(localized: "\(count) open"),
            accessibilityLabel: String(localized: "Open \(TasksSettings.title(of: page))")
        ) { context.open(page) }
    }

    /// A connected source: who it is connected as, or "Needs attention", and its open count.
    private func sourceRow(_ source: TaskSource, count: Int) -> some View {
        let state = manager.syncState(source)
        let problem = TaskSourceStatus.problem(state, source: source)
        let status = problem != nil || state == .needsKeychainApproval
            ? String(localized: "Needs attention")
            : TaskSourceStatus.text(for: source)
        return LabeledContent {
            openButton(count: count, page: .source(source))
        } label: {
            VStack(alignment: .leading, spacing: SettingsMetrics.labelStack) {
                Text(verbatim: source.title)
                SettingsStatusText(status, isReady: source.isSyncOn && problem == nil)
            }
        }
        .onAppear { manager.syncIfStale(source) }
    }

    /// Each source's row with its own deep link, written out so it is found by search and pinned by
    /// `SettingsHighlightInventoryTests`.
    @ViewBuilder
    private func highlighted(_ row: some View, for source: TaskSource) -> some View {
        switch source {
        case .local: row
        case .jira: row.settingsHighlight(id: SettingsDeepLink.tasksJiraSourceHighlightID)
        case .gitlab: row.settingsHighlight(id: SettingsDeepLink.tasksGitLabSourceHighlightID)
        case .github: row.settingsHighlight(id: SettingsDeepLink.tasksGitHubSourceHighlightID)
        case .linear: row.settingsHighlight(id: SettingsDeepLink.tasksLinearSourceHighlightID)
        case .todoist: row.settingsHighlight(id: SettingsDeepLink.tasksTodoistSourceHighlightID)
        case .appleReminders: row.settingsHighlight(id: SettingsDeepLink.tasksAppleRemindersSourceHighlightID)
        }
    }
}

/// The overview below the Sources: All tasks, Time to log and Interrupted sessions. A separate view
/// so `TasksManager` is created only once tasks are turned on.
private struct TaskOverviewSections: View {
    @ObservedObject private var manager = TasksManager.shared
    @Binding private var sheet: TaskSheet?
    private let openAllTasks: () -> Void

    init(sheet: Binding<TaskSheet?>, openAllTasks: @escaping () -> Void) {
        _sheet = sheet
        self.openAllTasks = openAllTasks
    }

    var body: some View {
        allTasksSection
        TimeToLogSection()
        interruptedSection
    }

    // MARK: - All tasks ›

    /// "12 to do · 3 in progress" — every task Kannu holds, whatever All tasks' filters hide — and
    /// the way in.
    private var allTasksSection: some View {
        let counts = TaskFacets.counts(manager.activeTasks)
        return Section {
            if case .failed(let reason) = manager.loadState {
                SettingsErrorText(String(localized: "Couldn't read the task list, so it can't change. \(reason)"))
            }
            LabeledContent {
                TasksOpenButton(
                    text: String(localized: "\(counts.toDo + counts.inProgress) open"),
                    accessibilityLabel: String(localized: "Open all tasks"),
                    action: openAllTasks
                )
            } label: {
                SettingsRowLabel(
                    "All tasks",
                    description: Text(verbatim: String(localized: "\(counts.toDo) to do · \(counts.inProgress) in progress"))
                )
            }
            .settingsHighlight(id: SettingsDeepLink.tasksListHighlightID)
        } header: {
            SettingsSectionHeader("Your tasks")
        }
    }

    // MARK: - Interrupted sessions

    @ViewBuilder
    private var interruptedSection: some View {
        let interrupted = manager.interruptedSessions
        if !interrupted.isEmpty {
            Section {
                ForEach(interrupted) { entry in
                    LabeledContent {
                        HStack(spacing: SettingsMetrics.rowContent) {
                            Button("Set End Time") {
                                sheet = .endTime(
                                    taskID: entry.task.id,
                                    segmentID: entry.segment.id,
                                    title: entry.task.title,
                                    start: entry.segment.start,
                                    nextSessionStart: entry.nextSessionStart
                                )
                            }
                            Button("Discard") {
                                manager.discardInterruptedSession(segmentID: entry.segment.id, taskID: entry.task.id)
                            }
                        }
                    } label: {
                        SettingsRowLabel(
                            Text(verbatim: entry.task.title),
                            description: Text(verbatim: String(localized: "Timing since \(entry.segment.start.formatted(date: .abbreviated, time: .shortened))"))
                        )
                    }
                }
            } header: {
                SettingsSectionHeader("Interrupted sessions")
            } footer: {
                SettingsFooter("Kannu stopped while timing these. Set an end time or discard.")
            }
        }
    }
}

/// What a task sheet edits.
enum TaskSheet: Identifiable {
    /// Right-click › Set Estimate: the task's estimate as `TaskFormDraft(editing:)` reads it.
    case estimate(taskID: UUID, title: String, draft: TaskFormDraft)
    case addTime(taskID: UUID, title: String)
    /// `nextSessionStart` is when the next session on the task began, if one has: the end may not
    /// pass it. The sheet caps it at now on its own render, so the clock stays live.
    case endTime(taskID: UUID, segmentID: UUID, title: String, start: Date, nextSessionStart: Date?)
    /// Add Tags on any task, served by `TaskTagsSheet`. `existing` are the tags in use on any task.
    case tags(taskID: UUID, title: String, current: [String], existing: [String])
    /// Schedule on a local task.
    case schedule(taskID: UUID, title: String, current: Date?)
    /// Connect… for a source: `JiraConnectSheet`, `GitLabConnectSheet`, or `SourceConnectSheet`.
    case connect(TaskSource)
    /// Add a task's New Task, served by `NewTaskSheet`. `listFilter` is what All tasks shows, so a
    /// task it would hide opens on its own page; `.all` from Local tasks.
    case newTask(listFilter: TaskFilter)

    var id: String {
        switch self {
        case .newTask: return "new-task"
        case .connect(let source): return "connect-\(source.rawValue)"
        case .estimate(let taskID, _, _): return "estimate-\(taskID)"
        case .addTime(let taskID, _): return "add-time-\(taskID)"
        case .endTime(_, let segmentID, _, _, _): return "end-time-\(segmentID)"
        case .tags(let taskID, _, _, _): return "tags-\(taskID)"
        case .schedule(let taskID, _, _): return "schedule-\(taskID)"
        }
    }
}

/// The small sheet behind Set Estimate, Add Time, Set End Time and Schedule. Its confirm button says
/// what it does: Save, Add or Schedule. Set Estimate takes the typed estimate New Task and a task's
/// page take (`TaskEstimateField`), checked as it is typed. A sheet pads its own content; a Form row
/// never does.
private struct TaskValueSheet: View {
    enum Value {
        /// Nil removes an estimate.
        case duration(Int?)
        case date(Date)
        /// Clear Schedule.
        case cleared
    }

    let sheet: TaskSheet
    let onSave: (Value) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    /// Set Estimate's typed estimate (`TaskFormDraft`).
    @State private var estimate: TaskFormDraft
    @State private var date: Date
    @State private var problem: String?

    init(sheet: TaskSheet, onSave: @escaping (Value) -> Void) {
        self.sheet = sheet
        self.onSave = onSave
        if case .estimate(_, _, let draft) = sheet {
            _estimate = State(initialValue: draft)
        } else {
            _estimate = State(initialValue: TaskFormDraft())
        }
        switch sheet {
        case .endTime(_, _, _, let start, _):
            // Kannu never guesses the end: the picker starts where the session started.
            _date = State(initialValue: start)
        case .schedule(_, _, let current):
            _date = State(initialValue: current.flatMap { $0 > Date() ? $0 : nil } ?? Self.nextHour())
        default:
            _date = State(initialValue: Date())
        }
    }

    /// The next whole hour: a schedule's starting point.
    private static func nextHour(after now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        return calendar.date(byAdding: .hour, value: 1, to: hour) ?? now.addingTimeInterval(3600)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowContent) {
            Text(heading)
                .font(.headline)
            if let subject {
                Text(verbatim: subject)
                    .settingsDescriptionStyle()
            }
            Text(explanation)
                .settingsDescriptionStyle()
            field
            // Only for a reminder that would notify: a muted task's re-timed reminder stays muted
            // (`setSchedule`), as on the task page and in New Task. The bell cannot change while the
            // sheet is up, so a lookup at render is enough.
            if case .schedule(let taskID, _, _) = sheet,
               TasksManager.shared.tasks.first(where: { $0.id == taskID })?.notifiesForReminder ?? true {
                ReminderPermissionNote()
            }
            if let problem {
                Text(verbatim: problem)
                    .settingsDescriptionStyle(tint: .red)
            }
            HStack(spacing: SettingsMetrics.rowContent) {
                if case .estimate(_, _, let draft) = sheet, draft.estimateSeconds != nil {
                    Button("Remove Estimate") {
                        onSave(.duration(nil))
                        dismiss()
                    }
                }
                if case .schedule(_, _, .some) = sheet {
                    Button("Clear Schedule") {
                        onSave(.cleared)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(primaryTitle) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isEstimate && estimate.estimateReading == .unreadable)
            }
        }
        .onChange(of: estimate.estimateText) { _, _ in problem = nil }
        // macOS's answer may have changed since the list last asked: the note follows it.
        .onAppear {
            if case .schedule = sheet { TasksManager.shared.checkReminderPermission() }
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(width: 380)
    }

    private var isEstimate: Bool {
        if case .estimate = sheet { return true }
        return false
    }

    @ViewBuilder
    private var field: some View {
        switch sheet {
        case .endTime(_, _, _, let start, let nextSessionStart):
            // Date() here, not a stored bound: the list may have rendered long before the click.
            DatePicker("Stopped working at", selection: $date, in: start...max(start, min(nextSessionStart ?? .distantFuture, Date())),
                       displayedComponents: [.date, .hourAndMinute])
        case .schedule:
            DatePicker("Remind me at", selection: $date, in: Date()...,
                       displayedComponents: [.date, .hourAndMinute])
        case .estimate:
            TaskEstimateField(draft: $estimate, onSubmit: save)
        default:
            TextField("Length", text: $text, prompt: Text("1h 30m"))
                .onSubmit(save)
                .onChange(of: text) { _, _ in problem = nil }
        }
    }

    private var heading: LocalizedStringKey {
        switch sheet {
        case .estimate: return "Set Estimate"
        case .addTime: return "Add Time"
        case .endTime: return "Set End Time"
        case .tags: return "Tags"
        case .schedule: return "Schedule"
        case .connect: return "Connect"
        case .newTask: return "New Task"
        }
    }

    /// The task's own title, verbatim.
    private var subject: String? {
        switch sheet {
        case .tags, .connect, .newTask: return nil
        case .estimate(_, let title, _), .addTime(_, let title), .endTime(_, _, let title, _, _),
             .schedule(_, let title, _):
            return title
        }
    }

    private var explanation: LocalizedStringKey {
        switch sheet {
        case .estimate:
            return "Such as 1h 30m, 90m, 1.5h or 2d. Nothing, or 0, removes it."
        case .addTime:
            return "Time worked without the timer, ending now."
        case .endTime(_, _, _, _, .none):
            return "When did you stop working on it?"
        case .endTime:
            return "When did you stop? Not after a later session began."
        case .schedule:
            return "A reminder with a Start button."
        case .tags, .connect, .newTask:
            return ""
        }
    }

    private var primaryTitle: LocalizedStringKey {
        switch sheet {
        case .addTime, .newTask: return "Add"
        case .schedule: return "Schedule"
        case .estimate, .endTime, .tags, .connect: return "Save"
        }
    }

    private func save() {
        switch sheet {
        case .endTime, .schedule:
            onSave(.date(date))
            dismiss()
            return
        case .estimate:
            // The typed estimate's own reading: nothing or 0 removes it, as on a task's page.
            switch estimate.estimateReading {
            case .none: onSave(.duration(nil))
            case .length(let seconds): onSave(.duration(seconds))
            case .unreadable:
                problem = String(localized: "Type at least a minute, such as 1h 30m.")
                return
            }
            dismiss()
            return
        default:
            break
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seconds = WorkDuration.parse(trimmed), seconds >= 60 else {
            problem = String(localized: "Type at least a minute, such as 1h 30m.")
            return
        }
        onSave(.duration(seconds))
        dismiss()
    }
}

/// The button to macOS's Notifications pane. One literal, for All tasks' note, a task page's
/// Notify, and the Schedule and New Task sheets (`BrainNamingRulesTests` allows it once: it means
/// the macOS pane, not Brain).
let openNotificationSettingsTitle: LocalizedStringKey = "Open Notification Settings"

/// "Notifications are off" with a way to turn them on, while macOS blocks Kannu's notifications:
/// in the Schedule and New Task sheets, so the user hears before setting a reminder that cannot
/// notify (`notificationsDenied`, macOS's answer, not whether any reminder waits yet).
struct ReminderPermissionNote: View {
    @ObservedObject private var manager = TasksManager.shared

    var body: some View {
        if manager.notificationsDenied {
            HStack(spacing: SettingsMetrics.rowContent) {
                Text("Notifications are off for Kannu.")
                    .settingsDescriptionStyle(tint: .orange)
                Button(openNotificationSettingsTitle) { TaskReminders.openNotificationSettings() }
            }
        }
    }
}
