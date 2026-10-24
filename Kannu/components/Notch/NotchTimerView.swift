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

import SwiftUI
import Defaults
#if canImport(AppKit)
import AppKit
#endif

struct NotchTimerView: View {
    @Environment(\.notchForeground) private var notchForeground
    @EnvironmentObject var vm: KannuViewModel
    @ObservedObject var timerManager = TimerManager.shared
    @ObservedObject var coordinator = KannuViewCoordinator.shared
    @Default(.enableTimerFeature) var enableTimerFeature
    @Default(.enableMinimalisticUI) private var enableMinimalisticUI
    @Default(.timerPresets) private var timerPresets
    @Default(.timerIconColorMode) private var colorMode
    @Default(.timerSolidColor) private var solidColor
    @Default(.timerShowsProgress) private var showsProgress
    @Default(.timerProgressStyle) private var progressStyle
    @Default(.showTimerPresetsInNotchTab) private var showTimerPresetsInNotchTab
    @Default(.timerInputStyle) private var timerInputStyle
    @Default(.enableTasks) private var enableTasks
    /// Read so a new width in Settings lays the columns out again (`sideColumnWidth`).
    @Default(.openNotchWidth) private var openNotchWidth

    @AppStorage("customTimerDuration") private var customTimerDuration: Double = 600
    @State private var customHours: Int = 0
    @State private var customMinutes: Int = 10
    @State private var customSeconds: Int = 0
    @State private var isSyncingCustomDuration = false
    @State private var lockedAccentColor: Color?
    /// The name typed for the next session (`TimerSessionName`); cleared once a session starts.
    @State private var pendingSessionName = ""
    @State private var isRenamingSession = false
    @State private var renameDraft = ""
    /// The session the rename began in (`TimerManager.sessionID`).
    @State private var renamingSessionID: UUID?
    /// Keeps the notch open while a name is being typed (`KannuViewModel.setAutoCloseSuppression`).
    @State private var nameEditingToken = UUID()
    @FocusState private var focusedNameField: NameField?
    /// The side column's page once one is picked (`TimerSideColumn`). Nil until then, so the tab
    /// opens on `TimerSideColumn.initialPage` from its first frame; cleared each time the tab
    /// appears, never persisted.
    @State private var pickedSidePage: TimerSidePage?
    /// The pointer is over the ruler strip (`RulerTimerPicker.onScrollAreaHover`): a sideways
    /// scroll there sets the minutes, so the tab-wide page swipe leaves it alone. A second guard:
    /// the swipe yields over the ruler by its live frame first (`ScrollWheelMonitor`), since this
    /// state reaches the monitor only after a re-render, which a scroll can beat.
    @State private var isOverRuler = false
    /// The task form in place of the name field and the composer (`TimerTaskForm`): a new task, or
    /// one task's edit; while a timer runs, only the running task's edit (`shownTaskForm`). Nil
    /// shows them. Cleared when a timer starts or stops, when its session ends or is replaced, and
    /// each time the tab appears, never persisted.
    @State private var taskForm: TimerTaskFormMode?
    /// The task picked from the bar's typed search for the next session (`TimerSessionPick`),
    /// kept on `TimerManager.sessionPick` while the notch is closed. It lasts while the bar still
    /// says its name.
    @State private var sessionPick: TimerSessionPick?
    /// The bar's typed search (`TimerTaskSuggestions`): its rows, the highlighted row, and the text
    /// it was closed on.
    @State private var suggestions = TaskSuggestionState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum NameField: Hashable {
        case pending
        case rename
    }

    var body: some View {
        Group {
            if enableTimerFeature {
                HStack(alignment: .top, spacing: timerManager.isTimerActive ? 0 : TimerComposerMetrics.tabColumnSpacing) {
                    leftColumn
                    if shouldShowSideColumn {
                        // Ends where the composer and the page do. The Tasks page hangs its icon
                        // rail on this line and draws the hairline under them itself.
                        Divider()
                            .frame(height: sidePageHeight)
                            .opacity(shownSidePage == .tasks ? 0 : 0.2)
                        sideColumn
                    }
                }
                .frame(maxHeight: maxTabContentHeight, alignment: .top)
                .padding(.horizontal, TimerComposerMetrics.tabHorizontalPadding)
                .padding(.vertical, TimerComposerMetrics.tabVerticalPadding)
                // A click anywhere in the tab that no control takes ends typing, which saves a rename.
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { focusedNameField = nil }
                )
#if canImport(AppKit)
                // A two-finger swipe anywhere on the tab (composer, divider or column) turns the
                // side column's page, except over the ruler, whose sideways scroll sets minutes:
                // the monitor yields there by the ruler's frame, and by its hover as well.
                .background {
                    if hasPageSwipe {
                        HorizontalSwipeMonitor(current: shownSidePage, isSuspended: isOverRuler, onSwipe: selectSidePage)
                            // Down into the footer, so the "Tasks · Presets" labels hanging there
                            // are swipeable too.
                            .padding(.bottom, -TimerComposerMetrics.pageSwipeFooterReach)
                            // It watches scroll events only; clicks stay with the tap layer above.
                            .allowsHitTesting(false)
                    }
                }
#endif
                .transition(.opacity.combined(with: .blurReplace))
                .onAppear { syncCustomDuration(with: customTimerDuration) }
                .onChange(of: customTimerDuration) { _, newValue in syncCustomDuration(with: newValue) }
                .onChange(of: customHours) { _, _ in updateStoredCustomDuration() }
                .onChange(of: customMinutes) { _, _ in updateStoredCustomDuration() }
                .onChange(of: customSeconds) { _, _ in updateStoredCustomDuration() }
            } else {
                disabledState
            }
        }
        .onAppear {
            lockAccentColorIfNeeded()
            // Each time the tab appears it opens on the initial page again, with the composer, and
            // the session name typed before the notch closed.
            pickedSidePage = nil
            taskForm = nil
            pendingSessionName = timerManager.typedSessionName
            // The pick comes back with its name, and only with tasks on; a stale one is dropped
            // from the timer's copy too.
            let restored = isTasksPageAvailable ? timerManager.sessionPick?.kept(typed: timerManager.typedSessionName) : nil
            sessionPick = restored
            timerManager.sessionPick = restored
            warmTasks(ifNamed: timerManager.typedSessionName)
        }
        .onChange(of: timerManager.isTimerActive) { _, isActive in
            taskForm = nil
            if isActive {
                lockAccentColorIfNeeded()
            } else {
                lockedAccentColor = nil
                isRenamingSession = false
                focusedNameField = nil
            }
        }
        .onChange(of: focusedNameField) { previous, current in
            vm.setAutoCloseSuppression(current != nil, token: nameEditingToken)
            if previous == .rename, current != .rename {
                commitRename()
            }
        }
        // Tasks or the timer switched off under the form: the composer comes back, and a pick goes.
        .onChange(of: isTasksPageAvailable) { _, isAvailable in
            if !isAvailable {
                taskForm = nil
                sessionPick = nil
            }
        }
        // The running session's task changed: a replace never fires the isTimerActive observer
        // (docs/REGRESSIONS.md entry 10), so the old task's form closes here.
        .onChange(of: timerManager.sessionTaskID) { _, _ in
            taskForm = nil
        }
        // The session ran out: the form gives the card back, with Stop, while the alarm rings.
        .onChange(of: timerManager.isFinished) { _, finished in
            if finished { taskForm = nil }
        }
        // However the form goes away (its ×, a start, the notch closing, any observer), the bar
        // gets back its text: a new task's title, as the form wrote it (one text with the bar).
        .onChange(of: taskForm) { _, form in
            if form == nil { pendingSessionName = timerManager.typedSessionName }
        }
        .onChange(of: pendingSessionName) { _, newValue in
            if newValue.count > TimerSessionName.maxLength {
                pendingSessionName = String(newValue.prefix(TimerSessionName.maxLength))
            }
            // The pick lasts while the bar still says its name: editing or clearing the text drops it.
            sessionPick = sessionPick?.kept(typed: pendingSessionName)
            suggestions.textChanged(to: pendingSessionName)
            // Kept while the notch is closed, so a half-typed name survives it (David, 2026-10-23).
            timerManager.typedSessionName = pendingSessionName
            warmTasks(ifNamed: pendingSessionName)
        }
        .onChange(of: sessionPick) { _, pick in
            timerManager.sessionPick = pick
        }
        // Closing the notch or switching tabs removes this view without a focus change.
        .onDisappear {
            commitRename()
            vm.setAutoCloseSuppression(false, token: nameEditingToken)
        }
        // A click into another app leaves the field focused in a window that is no longer key: save
        // the rename and drop the focus, which lets the notch auto-close again. A half-typed
        // next-session name is kept on `TimerManager.typedSessionName` while the notch is closed.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard note.object is KannuWindow else { return }
            commitRename()
            focusedNameField = nil
        }
        .onChange(of: timerManager.activePresetId) { _, _ in
            if timerManager.isTimerActive && lockedAccentColor == nil {
                lockAccentColorIfNeeded()
            }
        }
        // The colour the accent is built from changed (task tint, preset, or a new session with
        // neither): the accent follows it.
        .onChange(of: timerManager.sessionAccent) { _, _ in
            lockAccentColorIfNeeded()
        }
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let taskForm = shownTaskForm {
                TimerTaskForm(mode: taskForm, open: openTaskForm, close: closeTaskForm, started: taskStarted)
                    .id(taskForm)
                    .transition(.opacity)
                Spacer(minLength: 0)
            } else if timerManager.isTimerActive {
                Spacer(minLength: 0)
                activeTimerCard
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: TimerComposerMetrics.nameFieldSpacing) {
                    nameRow
                    customTimerComposer
                }
                .transition(.opacity)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: maxTabContentHeight, alignment: .top)
        .padding(.bottom, 2)
    }

    /// Tasks · Presets beside the composer. A task's ▶ starts it there; its name wins over a typed
    /// one, so the typed name is dropped.
    private var sideColumn: some View {
        TimerSideColumn(
            page: shownSidePage,
            select: selectSidePage,
            tasksAvailable: isTasksPageAvailable,
            presetsAvailable: showTimerPresetsInNotchTab,
            budget: maxTabContentHeight,
            pageHeight: sidePageHeight,
            columnWidth: sideColumnWidth,
            presets: timerPresets,
            activePresetID: timerManager.activePresetId,
            startPreset: { preset in
                startSession(duration: preset.duration, preset: preset, fallback: preset.name)
                if !enableMinimalisticUI {
                    coordinator.currentView = .timer
                }
            },
            taskStarted: taskStarted,
            editTask: { openTaskForm(.edit($0)) }
        )
    }

    /// A task started from its ▶, the form's Add & Start, or a preset with the form open: its name
    /// wins over a typed one, so the typed name and any pick are dropped, and the composer comes
    /// back for when the timer stops. The stored name is cleared directly: a "" → title → "" change
    /// in one turn never reaches the `pendingSessionName` observer (docs/REGRESSIONS.md entry 10).
    private func taskStarted() {
        pendingSessionName = ""
        timerManager.typedSessionName = ""
        sessionPick = nil
        focusedNameField = nil
        taskForm = nil
        if !enableMinimalisticUI {
            coordinator.currentView = .timer
        }
    }

    /// The form in the composer's place; the page switch's animation and reduced-motion rule.
    private func openTaskForm(_ mode: TimerTaskFormMode) {
        focusedNameField = nil
        if reduceMotion {
            taskForm = mode
        } else {
            withAnimation(.smooth(duration: 0.2)) { taskForm = mode }
        }
    }

    private func closeTaskForm() {
        if reduceMotion {
            taskForm = nil
        } else {
            withAnimation(.smooth(duration: 0.2)) { taskForm = nil }
        }
    }

    /// The task the running session times, when its form may open (Edit Task on the running card).
    private var runningTaskID: UUID? {
        guard isTasksPageAvailable, timerManager.hasManualTimerRunning else { return nil }
        return timerManager.sessionTaskID
    }

    /// The form in the left column: any while no timer runs; while one runs, only the running
    /// task's edit. A replaced session never fires the isTimerActive observer (docs/REGRESSIONS.md
    /// entry 10), so the form is matched against the session here as well.
    private var shownTaskForm: TimerTaskFormMode? {
        guard let taskForm, isTasksPageAvailable else { return nil }
        guard timerManager.isTimerActive else { return taskForm }
        return runningTaskID.map(TimerTaskFormMode.edit) == taskForm ? taskForm : nil
    }

    private var activeTimerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                leadingControlSection
                    .frame(width: 128, alignment: .leading)

                timerTitleSection

                countdownSection
            }

            progressSection
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var leadingControlSection: some View {
        if timerManager.allowsManualInteraction {
            HStack(spacing: 10) {
                // Paused in overtime (a pause from the Tasks popover, or an estimate edit that ran
                // past zero) still needs Resume.
                if !timerManager.isOvertime || timerManager.isPaused {
                    TimerControlButton(
                        icon: pauseIconName,
                        foreground: notchForeground.opacity(0.95),
                        background: timerAccentColor.opacity(0.32),
                        tooltip: pauseAccessibilityLabel,
                        action: togglePauseAction
                    )

                    TimerControlButton(
                        icon: timerManager.isOvertime ? "stop.fill" : "xmark",
                        foreground: notchForeground.opacity(0.95),
                        background: notchForeground.opacity(0.16),
                        tooltip: timerManager.isOvertime ? String(localized: "Stop") : String(localized: "Cancel"),
                        action: stopTimerAction
                    )
                } else {
                    TimerControlButton(
                        icon: "stop.fill",
                        foreground: notchForeground.opacity(0.95),
                        background: notchForeground.opacity(0.16),
                        tooltip: String(localized: "Stop"),
                        action: stopTimerAction
                    )
                }
            }
        } else {
            inactiveTimerPlaceholder
        }
    }

    /// The session's name, and under it a task's short key as a chip ("ds-vendors #4264"): the
    /// name is the task's title, so the key never crowds it out (`TimerManager.sessionTaskKey`).
    private var timerTitleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            timerNameRow
            if let key = timerManager.sessionTaskKey {
                SideChip(key, monospaced: true, truncates: true)
                    .accessibilityLabel(Text(verbatim: String(localized: "Task \(key)")))
            }
        }
    }

    private var timerNameRow: some View {
        GeometryReader { geometry in
            let status = timerStatusText
            let spacing: CGFloat = status == nil ? 0 : 8
            let badgeWidth: CGFloat = status.map(statusBadgeWidth) ?? 0
            let editsTask = runningTaskID != nil && !isRenamingSession
            let pencilWidth: CGFloat = editsTask ? Self.editTaskButtonSize + Self.editTaskButtonSpacing : 0
            let marqueeWidth = max(48, geometry.size.width - badgeWidth - spacing - pencilWidth)

            HStack(alignment: .center, spacing: spacing) {
                HStack(alignment: .center, spacing: Self.editTaskButtonSpacing) {
                    if isRenamingSession {
                        TextField(String(localized: "Session name"), text: $renameDraft)
                            .font(.system(size: 20, weight: .semibold))
                            .textFieldStyle(.plain)
                            .foregroundColor(notchForeground)
                            .tint(notchForeground)
                            .frame(width: marqueeWidth, height: 24, alignment: .leading)
                            .focused($focusedNameField, equals: .rename)
                            .onSubmit { commitRename() }
                            .onExitCommand { cancelRename() }
                    } else if timerManager.hasManualTimerRunning {
                        MarqueeText(
                            .constant(timerDisplayName),
                            font: .system(size: 20, weight: .semibold),
                            nsFont: .title3,
                            textColor: notchForeground,
                            minDuration: 0.2,
                            frameWidth: marqueeWidth
                        )
                        .frame(width: marqueeWidth, height: 24, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { beginRename() }
                        .hoverTooltip(String(localized: "Click to rename"), pointingHandCursor: true)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(Text("Renames this timer session"))
                    } else {
                        MarqueeText(
                            .constant(timerDisplayName),
                            font: .system(size: 20, weight: .semibold),
                            nsFont: .title3,
                            textColor: notchForeground,
                            minDuration: 0.2,
                            frameWidth: marqueeWidth
                        )
                        .frame(width: marqueeWidth, height: 24, alignment: .leading)
                    }

                    if editsTask, let taskID = runningTaskID {
                        editTaskButton(taskID)
                    }
                }

                if let status {
                    statusBadge(status)
                        .frame(width: badgeWidth)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 32)
    }

    private static let editTaskButtonSize: CGFloat = 20
    private static let editTaskButtonSpacing: CGFloat = 6

    /// The running task's form, in the card's place (David, 2026-10-23: "a task running also needs
    /// edit"). Clicking the name still renames only the session.
    private func editTaskButton(_ taskID: UUID) -> some View {
        Button {
            openTaskForm(.edit(taskID))
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(notchForeground.opacity(0.85))
                .frame(width: Self.editTaskButtonSize, height: Self.editTaskButtonSize)
                .background(notchForeground.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: String(localized: "Edit Task")))
        .hoverTooltip(String(localized: "Edit Task"), edge: .below)
    }

    @ViewBuilder
    private var countdownSection: some View {
        if showsProgress && progressStyle == .ring {
            TimerProgressRing(
                progress: timerManager.progress,
                tint: timerAccentColor,
                timeText: timerManager.formattedRemainingTime(),
                isOvertime: timerManager.isOvertime,
                remainingTime: timerManager.remainingTime
            )
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                Text(timerManager.formattedRemainingTime())
                    .font(.system(size: 36, weight: .black, design: .monospaced))
                    .foregroundStyle(timerManager.isOvertime ? Color.red : notchForeground)
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.25), value: timerManager.remainingTime)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if timerManager.isOvertime {
                    Text(String(localized: "Overtime"))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(width: 190, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        if showsProgress && progressStyle == .bar {
            Capsule()
                .fill(notchForeground.opacity(0.12))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(timerAccentColor)
                        .frame(height: 4)
                        .scaleEffect(x: normalizedProgress, y: 1, anchor: .leading)
                        .animation(.smooth(duration: 0.25), value: timerManager.progress)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .padding(.bottom, 2)
        }
    }

    private func togglePauseAction() {
        guard timerManager.allowsManualInteraction else { return }
        timerManager.isPaused ? timerManager.resumeTimer() : timerManager.pauseTimer()
    }

    private func stopTimerAction() {
        if timerManager.allowsManualInteraction {
            timerManager.stopTimer()
        } else {
            timerManager.endExternalTimer(triggerSmoothClose: false)
        }
    }

    private var customTimerComposer: some View {
        Group {
            if timerInputStyle == .ruler {
                RulerTimerPicker(
                    hours: $customHours,
                    minutes: $customMinutes,
                    seconds: $customSeconds,
                    tintColor: timerAccentColor,
                    startAction: startCustomTimer,
                    onScrollAreaHover: { isOverRuler = $0 },
                    isCovered: showsSuggestions
                )
            } else if hasSideColumn {
                VStack(alignment: .leading, spacing: TimerComposerMetrics.rowSpacing) {
                    DurationInputRow(
                        hours: $customHours,
                        minutes: $customMinutes,
                        seconds: $customSeconds,
                        fieldWidth: durationFieldWidth
                    )
                    .coveredBySuggestions(showsSuggestions)

                    HStack(spacing: 10) {
                        startButton
                        resetButton
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    DurationInputRow(
                        hours: $customHours,
                        minutes: $customMinutes,
                        seconds: $customSeconds,
                        fieldWidth: durationFieldWidth
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: TimerComposerMetrics.buttonColumnSpacing) {
                        startButton
                        resetButton
                    }
                    .frame(width: buttonColumnWidth, alignment: .top)
                }
            }
        }
        // Sized by TimerComposerMetrics so it fits the tab without the notch growing.
        .padding(TimerComposerMetrics.composerPadding)
        // A filled shape behind, never a clip over the fields: a clip is a mask on the AppKit
        // fields' layers, and one computed mid-animation can cut their digits.
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(notchForeground.opacity(0.04)))
        // The bar's typed search hangs from the bar's bottom edge over the duration (covered), and
        // ends above Start and Reset (`TimerComposerMetrics.suggestionListHeight`). Under the name
        // row's zIndex, so its tooltips stay on top.
        .overlay(alignment: .top) {
            if wantsSuggestions {
                TimerTaskSuggestions(typed: pendingSessionName, state: $suggestions, pick: pickSuggestion)
                    .offset(y: -TimerComposerMetrics.nameFieldSpacing)
            }
        }
    }

    // MARK: - The bar's typed search

    /// The bar's typed search shows: tasks on, nothing picked, a name being typed, while the bar has
    /// focus or the pointer is on the list, until Esc, Return, Tab or a pick closes it.
    private var wantsSuggestions: Bool {
        suggestions.wantsToShow(enabled: isTasksPageAvailable && sessionPick == nil, typed: pendingSessionName,
                                fieldFocused: focusedNameField == .pending)
    }

    /// The list has rows, so it covers the duration (never Start and Reset).
    private var showsSuggestions: Bool {
        suggestions.shows(enabled: isTasksPageAvailable && sessionPick == nil, typed: pendingSessionName,
                          fieldFocused: focusedNameField == .pending)
    }

    /// A row picked: a task is timed by the next preset or Start; the New row keeps the typed text
    /// as a new task. The pick and the bar's text change in one update, so the text check keeps it.
    private func pickSuggestion(_ row: TaskSuggestionState.Row) {
        let typed = pendingSessionName
        let pick: TimerSessionPick
        switch row {
        case .task(let id, let title):
            pick = TimerSessionPick(taskID: id, name: TimerSessionName.cleaned(title) ?? typed, typed: typed)
        case .newTask:
            pick = TimerSessionPick(taskID: nil, name: TimerSessionName.cleaned(typed) ?? typed, typed: typed)
        }
        suggestions.close(on: pick.name)
        sessionPick = pick
        pendingSessionName = pick.name
        // Next comes a length.
        focusedNameField = nil
    }

    /// The picked task left the list (done, archived, resynced away): the pick goes, and the bar
    /// gets back what the user had typed, in one update.
    private func pickLost() {
        guard let pick = sessionPick else { return }
        sessionPick = nil
        pendingSessionName = pick.typed
    }

    /// Return in the bar: the row the arrows highlighted, else the list closes and typing ends
    /// (`answerReturn`).
    private func submitName() {
        switch suggestions.answerReturn(showing: showsSuggestions) {
        case .pick(let row):
            pickSuggestion(row)
        case .closeList, .passOn:
            suggestions.close(on: pendingSessionName)
            focusedNameField = nil
        }
    }

    /// Escape in the bar closes the typed search on this text, rows or not: the bar has no Escape of
    /// its own, and rows that arrive later (the task file read, a sync) must not reopen it.
    private func exitName() {
        suggestions.close(on: pendingSessionName)
    }

    /// Builds the task list ahead of a typed start, so the first one after launch need not wait
    /// for the file: only for a name typed with tasks on, never because the tab appeared.
    private func warmTasks(ifNamed text: String) {
        guard isTasksPageAvailable, TimerSessionName.cleaned(text) != nil else { return }
        TimerTaskForm.prepareForTypedStart()
    }

    /// What VoiceOver adds to the bar while a pick holds it.
    private var pickHint: String {
        guard isTasksPageAvailable, let sessionPick else { return "" }
        return sessionPick.isNew
            ? String(localized: "New task: the next session makes it")
            : String(localized: "Picked task: the next session times it")
    }

    private var inactiveTimerPlaceholder: some View {
        Color.clear
            .frame(height: 46)
    }

    private var disabledState: some View {
        VStack(spacing: 16) {
            Image(systemName: "timer.slash")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)

            Text("Timer Disabled")
                .font(.title2)
                .fontWeight(.medium)

            Text("Enable the timer feature in Brain to access this tab.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The Tasks page needs tasks and the timer; the Presets page, Show presets in the notch tab.
    private var isTasksPageAvailable: Bool {
        enableTasks && enableTimerFeature
    }

    /// The side column shows when it has a page. The composer's stacked layout and narrow fields
    /// follow it, so the column always fits beside them without the notch growing.
    /// The side column's width: the golden split of the open notch's width
    /// (`TimerComposerMetrics.sideColumnWidth`). The open notch's own width (`openNotchSize`), not
    /// `vm.notchSize`, which shrinks to the closed size before this tab fades out.
    private var sideColumnWidth: CGFloat {
        TimerComposerMetrics.sideColumnWidth(notchWidth: openNotchSize.width)
    }

    /// The composer beside the column: the ruler, or the stacked fields.
    private var composerStyle: TimerComposerMetrics.Style {
        timerInputStyle == .ruler ? .ruler : .manualWithPresets
    }

    /// The column's page ends where the composer does (`TimerComposerMetrics.sidePageHeight`).
    private var sidePageHeight: CGFloat {
        TimerComposerMetrics.sidePageHeight(budget: maxTabContentHeight, style: composerStyle)
    }

    private var hasSideColumn: Bool {
        showTimerPresetsInNotchTab || isTasksPageAvailable
    }

    /// The side column's pages, left to right.
    private var sidePages: [TimerSidePage] {
        TimerSideColumn.pages(tasksAvailable: isTasksPageAvailable, presetsAvailable: showTimerPresetsInNotchTab)
    }

    /// The picked page, or the one the tab opens on (Tasks first when Jira or GitLab is
    /// connected), or the only page there is.
    private var shownSidePage: TimerSidePage {
        let page = pickedSidePage ?? TimerSideColumn.initialPage(
            tasksAvailable: isTasksPageAvailable,
            presetsAvailable: showTimerPresetsInNotchTab
        )
        return TimerSideColumn.shownPage(page, in: sidePages)
    }

    /// The one way the side column's page changes: a label click, the VoiceOver picker, or a
    /// swipe anywhere on the tab.
    private func selectSidePage(_ target: TimerSidePage) {
        guard target != shownSidePage, sidePages.contains(target) else { return }
        if reduceMotion {
            pickedSidePage = target
        } else {
            withAnimation(.smooth(duration: 0.2)) { pickedSidePage = target }
        }
    }

    private var shouldShowSideColumn: Bool {
        !timerManager.isTimerActive && hasSideColumn
    }

    /// The tab-wide page swipe: only with both pages, and only while no timer runs.
    private var hasPageSwipe: Bool {
        shouldShowSideColumn && sidePages.count > 1
    }

    private var resolvedNotchHeight: CGFloat {
        let height = vm.notchSize.height
        return height > 0 ? height : openNotchSize.height
    }

    private var headerHeight: CGFloat {
        max(24, vm.effectiveClosedNotchHeight)
    }

    private var maxTabContentHeight: CGFloat {
        let available = resolvedNotchHeight - headerHeight - 36
        return max(130, available)
    }

    private func lockAccentColorIfNeeded() {
        if timerManager.isTimerActive {
            lockedAccentColor = resolvedAccentColor
        }
    }

    private var timerAccentColor: Color {
        lockedAccentColor ?? resolvedAccentColor
    }

    private var resolvedAccentColor: Color {
        switch colorMode {
        case .adaptive:
            return timerManager.sessionAccent ?? timerManager.timerColor
        case .solid:
            return solidColor
        }
    }

    private var normalizedProgress: CGFloat {
        CGFloat(max(0, min(timerManager.progress, 1)))
    }

    private var timerDisplayName: String {
        timerManager.timerName.isEmpty ? "Timer" : timerManager.timerName
    }

    private var timerStatusText: String? {
        if timerManager.isOvertime {
            return String(localized: "Overtime")
        } else if timerManager.isPaused {
            return String(localized: "Paused")
        } else if timerManager.isFinished {
            return "Completed"
        }
        return nil
    }

    private var timerStatusColor: Color {
        timerManager.isOvertime ? .red : timerAccentColor
    }

    private func statusBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(timerStatusColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(timerStatusColor.opacity(0.18))
            .clipShape(Capsule())
    }

    private func statusBadgeWidth(for text: String) -> CGFloat {
#if canImport(AppKit)
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
#elseif canImport(UIKit)
        let font = UIFont.systemFont(ofSize: 12, weight: .semibold)
#else
        return 80
#endif
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return width + 24
    }

    private var pauseIconName: String {
        timerManager.isPaused ? "play.fill" : "pause.fill"
    }

    private var pauseAccessibilityLabel: String {
        timerManager.isPaused ? String(localized: "Resume") : String(localized: "Pause")
    }

    private var startButtonColor: Color {
        Color(red: 0.142, green: 0.633, blue: 0.265)
    }

    private var isStartDisabled: Bool {
        customDurationInSeconds == 0
    }

    private var durationFieldWidth: CGFloat {
        hasSideColumn ? TimerComposerMetrics.stackedFieldWidth : TimerComposerMetrics.wideFieldWidth
    }

    private var buttonColumnWidth: CGFloat { 210 }

    private var startButton: some View {
        Button(action: startCustomTimer) {
            Label(String(localized: "Start"), systemImage: "play.fill")
                .font(.system(size: TimerComposerMetrics.buttonFontSize, weight: .semibold))
                .foregroundStyle(Color.white) // on the accent-filled button
                .frame(maxWidth: .infinity)
                .frame(height: TimerComposerMetrics.buttonHeight)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(startButtonColor.opacity(isStartDisabled ? 0.5 : 1))
                )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(notchForeground.opacity(0.15), lineWidth: 1)
        )
        .opacity(isStartDisabled ? 0.7 : 1)
        .disabled(isStartDisabled)
    }

    private var resetButton: some View {
        Button(action: resetCustomTimerInputs) {
            Label(String(localized: "Reset"), systemImage: "arrow.counterclockwise")
                .font(.system(size: TimerComposerMetrics.buttonFontSize, weight: .semibold))
                .foregroundStyle(notchForeground.opacity(0.9))
                .frame(maxWidth: .infinity)
                .frame(height: TimerComposerMetrics.buttonHeight)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(notchForeground.opacity(0.16))
                )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(notchForeground.opacity(0.08), lineWidth: 1)
        )
    }

    private var customDurationInSeconds: TimeInterval {
        TimeInterval(customHours * 3600 + customMinutes * 60 + customSeconds)
    }

    private func startCustomTimer() {
        withAnimation(.smooth) {
            startSession(duration: customDurationInSeconds, fallback: String(localized: "Custom Timer"))
            if !enableMinimalisticUI {
                coordinator.currentView = .timer
            }
        }
    }

    /// The session name field, and beside it, with tasks on, the New task button. Drawn above the
    /// composer, so the button's tooltip (opening downward) is never painted over.
    private var nameRow: some View {
        HStack(spacing: TimerComposerMetrics.nameFieldSpacing) {
            sessionNameField
            if isTasksPageAvailable {
                newTaskButton
            }
        }
        .zIndex(1)
    }

    /// Turns the left panel into the task form (`TimerTaskForm`): a new task, or, while a task is
    /// picked in the bar, that task's edit (its estimate, say, before timing it). The name field's
    /// look, square.
    private var newTaskButton: some View {
        let picked = isTasksPageAvailable ? sessionPick?.taskID : nil
        let label = picked == nil ? String(localized: "New Task") : String(localized: "Edit Task")
        return Button {
            openTaskForm(picked.map(TimerTaskFormMode.edit) ?? .add)
        } label: {
            Image(systemName: picked == nil ? "square.and.pencil" : "pencil")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(notchForeground.opacity(0.85))
                .frame(width: TimerComposerMetrics.newTaskButtonSize, height: TimerComposerMetrics.newTaskButtonSize)
                .background(notchForeground.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: label))
        .hoverTooltip(label, edge: .below)
    }

    /// One line above the composer: the name the next session starts with, from a preset or Start.
    /// With tasks on, a typed name is timed as a task, and the typed search offers the tasks already
    /// in the list; a picked one shows its colour before the name and its key and time after.
    private var sessionNameField: some View {
        HStack(spacing: 4) {
            if isTasksPageAvailable, let sessionPick {
                if let taskID = sessionPick.taskID {
                    TimerTaskPickDot(taskID: taskID)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            TextField(String(localized: "Do you want to name this session?"), text: $pendingSessionName)
                .font(.system(size: 12, weight: .medium))
                .textFieldStyle(.plain)
                .foregroundColor(notchForeground)
                .tint(notchForeground)
                .focused($focusedNameField, equals: .pending)
                .onSubmit(submitName)
                .onExitCommand(perform: exitName)
                .accessibilityLabel(Text("Session name"))
                .accessibilityHint(Text(verbatim: pickHint))
            if isTasksPageAvailable, let taskID = sessionPick?.taskID {
                TimerTaskPickInfo(taskID: taskID, lost: pickLost)
            }
            // A clear button at the end of the box, like the task form's; it never takes focus.
            if !pendingSessionName.isEmpty {
                Button {
                    pendingSessionName = ""
                    focusedNameField = .pending
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityLabel(Text(verbatim: String(localized: "Clear Name")))
                .hoverTooltip(String(localized: "Clear Name"), edge: .below)
            }
        }
            .padding(.horizontal, 10)
            .frame(height: TimerComposerMetrics.nameFieldHeight)
            .background(notchForeground.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .suggestionListKeys(isActive: showsSuggestions, move: { suggestions.move($0) }, tab: {
                suggestions.close(on: pendingSessionName)
                return true
            })
    }

    /// Every session started from this tab. A form showing starts what it shows
    /// (`TimerTaskForm.startFromForm`). Otherwise, with tasks on, a typed name or a picked task is
    /// timed as a task, the user's own block (`TimerTaskForm.startNamed`); with no name, or tasks
    /// off, or when no task can start, the session is plain: the typed name, or the preset's or
    /// "Custom Timer".
    private func startSession(duration: TimeInterval, preset: TimerPreset? = nil, fallback: String) {
        let form = shownTaskForm
        if let form {
            switch TimerTaskForm.startFromForm(form, duration: duration, preset: preset) {
            case .started:
                taskStarted()
                return
            case .held:
                // A new task's estimate that cannot be read: the form stays to be fixed.
                return
            case .gone:
                // The edited task left the list: an edit never falls through to the bar.
                closeTaskForm()
                return
            case .fallThrough:
                closeTaskForm()
            }
        }
        // With a form open, a new task's title is the bar's text: read what the form left, not
        // this view's copy, which the form's closing has not refreshed yet.
        let typed = form == nil ? pendingSessionName : timerManager.typedSessionName
        let plain = {
            TimerManager.shared.startTimer(
                duration: duration,
                name: TimerSessionName.resolved(typed: typed, fallback: fallback),
                preset: preset,
                fallbackName: fallback
            )
        }
        let route = TimerTypedStart.route(tasksAvailable: isTasksPageAvailable, typed: typed, pick: sessionPick)
        if route == .plain {
            plain()
        } else {
            TimerTaskForm.startNamed(route, typed: typed, duration: duration, preset: preset, otherwise: plain)
        }
        // Written directly as well: "" again would never reach the observer (REGRESSIONS entry 10).
        pendingSessionName = ""
        timerManager.typedSessionName = ""
        sessionPick = nil
        focusedNameField = nil
    }

    private func beginRename() {
        guard timerManager.hasManualTimerRunning else { return }
        renameDraft = timerManager.timerName
        renamingSessionID = timerManager.sessionID
        isRenamingSession = true
        DispatchQueue.main.async { focusedNameField = .rename }
    }

    private func commitRename() {
        guard isRenamingSession, let session = renamingSessionID else { return }
        isRenamingSession = false
        renamingSessionID = nil
        timerManager.renameSession(to: renameDraft, session: session)
        focusedNameField = nil
    }

    private func cancelRename() {
        isRenamingSession = false
        renamingSessionID = nil
        focusedNameField = nil
    }

    private func resetCustomTimerInputs() {
        withAnimation(.smooth(duration: 0.2)) {
            customHours = 0
            customMinutes = 0
            customSeconds = 0
        }
        customTimerDuration = 0
    }

    private func syncCustomDuration(with value: Double) {
        isSyncingCustomDuration = true
        let components = TimerPreset.components(for: value)
        customHours = components.hours
        customMinutes = components.minutes
        customSeconds = components.seconds
        isSyncingCustomDuration = false
    }

    private func updateStoredCustomDuration() {
        guard !isSyncingCustomDuration else { return }
        customTimerDuration = customDurationInSeconds
    }
}

private struct TimerControlButton: View {
    let icon: String
    let foreground: Color
    let background: Color
    /// Hover bubble text, doubling as the accessibility label (docs/TOOLTIPS.md).
    let tooltip: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 46, height: 46)
                .background(background.opacity(isHovering ? 0.95 : 0.8))
                .clipShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        // One hover source: this handler drives both the highlight and the bubble. The
        // self-hovering `.hoverTooltip(_:edge:)` used to sit here too, a second handler.
        .onHover { hovering in isHovering = hovering }
        .hoverTooltip(tooltip, edge: .below, isHovering: isHovering)
        .accessibilityLabel(tooltip)
    }
}

private struct TimerProgressRing: View {
    @Environment(\.notchForeground) private var notchForeground
    let progress: Double
    let tint: Color
    let timeText: String
    let isOvertime: Bool
    let remainingTime: TimeInterval

    private var clampedProgress: Double { min(max(progress, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(notchForeground.opacity(0.12), lineWidth: 8)

            Circle()
                .trim(from: 0, to: clampedProgress)
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.3), value: clampedProgress)

            Text(timeText)
                .font(.system(size: 28, weight: .black, design: .monospaced))
                .foregroundStyle(isOvertime ? Color.red : notchForeground)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.25), value: remainingTime)
        }
        .frame(width: 110, height: 110)
    }
}

private struct DurationInputRow: View {
    @Environment(\.notchForeground) private var notchForeground
    @Binding var hours: Int
    @Binding var minutes: Int
    @Binding var seconds: Int
    let fieldWidth: CGFloat

    init(
        hours: Binding<Int>,
        minutes: Binding<Int>,
        seconds: Binding<Int>,
        fieldWidth: CGFloat = 64
    ) {
        _hours = hours
        _minutes = minutes
        _seconds = seconds
        self.fieldWidth = fieldWidth
    }

    var body: some View {
        HStack(alignment: .center, spacing: TimerComposerMetrics.durationRowSpacing) {
            DurationField(label: String(localized: "Hours"), value: $hours, range: 0...23, width: fieldWidth)
            colon
            DurationField(label: String(localized: "Minutes"), value: $minutes, range: 0...59, width: fieldWidth)
            colon
            DurationField(label: String(localized: "Seconds"), value: $seconds, range: 0...59, width: fieldWidth)
        }
    }

    private var colon: some View {
        Text(":")
            .font(.system(size: TimerComposerMetrics.fieldDigitSize, weight: .black, design: .monospaced))
            .foregroundStyle(notchForeground.opacity(0.65))
    }
}

private struct DurationField: View {
    @Environment(\.notchForeground) private var notchForeground
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let width: CGFloat

    init(
        label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        width: CGFloat = 64
    ) {
        self.label = label
        _value = value
        self.range = range
        self.width = width
    }

    var body: some View {
        VStack(spacing: TimerComposerMetrics.captionGap) {
            // Our own field, sized to the box and centred: SwiftUI's TextField could be measured
            // for the default font mid-animation and show only the digits' top half.
            DurationDigitField(value: $value, range: range, width: width, accessibilityLabel: label)
                .frame(width: width, height: TimerComposerMetrics.fieldBoxHeight)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(notchForeground.opacity(0.08)))

            Text(label)
                .font(.caption2)
                .foregroundStyle(notchForeground.opacity(0.65))
                .frame(height: TimerComposerMetrics.captionHeight)
        }
    }
}

#Preview {
    NotchTimerView()
        .environmentObject(KannuViewModel())
        .frame(width: 600, height: 320)
        .background(.black)
}
