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

/// Brain › Tasks › Time to log: the time recorded on Jira and GitLab tasks, one card per entry,
/// shown only while an entry waits. Kannu always asks first: a card's Log, Retry or Send Again is
/// the only thing that calls `TasksManager.confirmWorklog`, and nothing else sends time anywhere
/// (`WorklogConsentRulesTests`).
///
/// A card: "Log 1h 15m to PROJ-123?", "started today 14:02 · Jira", the length (editable, read
/// with `WorkDuration.parse`), a comment for Jira, Log to Jira / Log to GitLab, Not now, and ⋯ with
/// Keep local only, Never ask for this task and Open in Jira / GitLab. A card that cannot be sent
/// from here — not connected, another site, a read-only GitLab token — says why and offers Keep
/// local only. Rows only, in the `SettingsComponents` shapes (docs/SETTINGS.md); issue keys and
/// server reasons render verbatim.
struct TimeToLogSection: View {
    @ObservedObject private var manager = TasksManager.shared

    private func highlightID(_ title: String) -> String { "tasks-\(title)" }

    var body: some View {
        let open = manager.openDrafts
        if !open.isEmpty {
            Section {
                LabeledContent {
                    SettingsValueText(open.count == 1 ? String(localized: "1 waiting") : String(localized: "\(open.count) waiting"))
                } label: {
                    SettingsRowLabel("Time to log", description: "Time you recorded on Jira and GitLab tasks. Kannu always asks first: nothing is sent until you choose Log.")
                }
                .settingsHighlight(id: highlightID("Time to log"))

                ForEach(open) { draft in
                    WorklogDraftCard(draft: draft)
                }
            } header: {
                SettingsSectionHeader("Time to log")
            } footer: {
                SettingsFooter("Jira entries are logged without emailing the issue's watchers, and take the time off its remaining estimate. GitLab records the time when you log it. Not now keeps an entry until more time is added to it; Keep local only keeps the time on this Mac.")
            }
        }
    }
}

/// One Time to log entry, wherever Kannu asks about it: here, and in the notch's Tasks popover
/// ("Log time?"). It works out whether the entry can be sent from here and where Open in… goes,
/// then draws `WorklogDraftRow` — so both places show one card, with one set of answers and one
/// path to `TasksManager.confirmWorklog`. The card is a `LabeledContent`: a Form lays it out as a
/// row, and the popover stacks it with a `LabeledContentStyle` of its own.
struct WorklogDraftCard: View {
    @ObservedObject private var manager = TasksManager.shared
    @Default(.jiraSiteHost) private var jiraSiteHost
    @Default(.gitlabHost) private var gitlabHost
    @Default(.gitlabCanLogTime) private var gitlabCanLogTime
    let draft: WorklogDraft

    var body: some View {
        let task = manager.task(for: draft)
        WorklogDraftRow(
            draft: draft,
            task: task,
            availability: WorklogDrafts.availability(
                of: draft, task: task,
                jiraHost: jiraSiteHost, gitlabHost: gitlabHost, gitlabCanLogTime: gitlabCanLogTime
            ),
            openLink: openLink(for: task)
        )
        // A new length (more time folded in, or the one just sent) starts the fields again.
        .id("\(draft.id.uuidString)-\(draft.seconds)")
    }

    private func openLink(for task: TaskItem?) -> WorklogDraftRow.Link? {
        guard let task else { return nil }
        if let url = manager.jiraBrowseURL(for: task) { return WorklogDraftRow.Link(title: "Open in Jira", url: url) }
        if let url = manager.gitlabBrowseURL(for: task) { return WorklogDraftRow.Link(title: "Open in GitLab", url: url) }
        return nil
    }
}

/// One entry's card: a row whose label says what would be logged where, and whose trailing column
/// holds the fields and the answers.
private struct WorklogDraftRow: View {
    struct Link {
        let title: LocalizedStringKey
        let url: URL
    }

    let draft: WorklogDraft
    let task: TaskItem?
    let availability: WorklogDrafts.Availability
    let openLink: Link?
    @State private var durationText: String
    @State private var comment: String

    init(draft: WorklogDraft, task: TaskItem?, availability: WorklogDrafts.Availability, openLink: Link?) {
        self.draft = draft
        self.task = task
        self.availability = availability
        self.openLink = openLink
        _durationText = State(initialValue: WorkDuration.format(draft.seconds))
        _comment = State(initialValue: draft.comment ?? "")
    }

    private var manager: TasksManager { TasksManager.shared }
    private var source: TaskSource { task?.source ?? .local }
    private var sourceName: String { WorklogDrafts.sourceName(source) }
    /// "PROJ-123", "group/app!12": the source's own key, verbatim.
    private var key: String { task?.remote?.key ?? task?.title ?? "" }
    private var typedSeconds: Int? { WorklogDrafts.loggableSeconds(typed: durationText) }
    private var isSending: Bool { draft.state == .sending }
    private var isReady: Bool { availability == .ready }
    /// The length and comment can change until the entry is sent, and after a refusal. An entry
    /// that may already be logged is sent again as it was.
    private var showsFields: Bool { isReady && (draft.state == .awaiting || draft.state == .failed || isSending) }

    var body: some View {
        if draft.state == .awaiting && draft.deferredAt != nil {
            deferredRow
        } else {
            card
        }
    }

    // MARK: - The card

    private var card: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: SettingsMetrics.rowContent) {
                if showsFields {
                    HStack(spacing: SettingsMetrics.rowContent) {
                        // No .onSubmit: Return confirms the length, never sends it. Only Log does.
                        TextField("Length", text: $durationText, prompt: Text(verbatim: "1h 15m"))
                            .labelsHidden()
                            .disabled(isSending)
                        if source == .jira {
                            TextField("Comment", text: $comment, prompt: Text("Comment (optional)"))
                                .labelsHidden()
                                .disabled(isSending)
                        }
                    }
                }
                HStack(spacing: SettingsMetrics.rowContent) {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                    }
                    answers
                    SettingsMoreMenu {
                        moreItems
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: SettingsMetrics.labelStack) {
                SettingsRowLabel(Text(verbatim: headline), description: Text(verbatim: caption))
                if let note {
                    Text(verbatim: note.text)
                        .settingsDescriptionStyle(tint: note.tint)
                }
            }
        }
    }

    private var headline: String {
        let seconds = showsFields ? (typedSeconds ?? draft.seconds) : draft.seconds
        if isSending {
            return String(localized: "Logging \(WorkDuration.format(seconds)) to \(key)…")
        }
        return WorklogDrafts.headline(seconds: seconds, key: key)
    }

    private var caption: String {
        WorklogDrafts.caption(started: draft.started, now: Date(), source: source)
    }

    /// Why the card cannot send, what the last attempt ended with, or a length that will not do.
    private var note: (text: String, tint: Color?)? {
        switch availability {
        case .notConnected:
            let place = source == .gitlab ? GitLabHost.displayName(draft.hostScope) : draft.hostScope
            return (String(localized: "\(sourceName) is not connected to \(place), so Kannu cannot log this. Connect it in Sources, or keep the time on this Mac."), .orange)
        case .readOnly:
            return (String(localized: "Your GitLab token is read-only (read_api), so Kannu cannot log time with it. Connect again with an api token, or keep the time on this Mac."), .orange)
        case .missingDetails:
            return (String(localized: "Kannu does not know enough about this item to log to it. Refresh \(sourceName) in Sources, or keep the time on this Mac."), .orange)
        case .ready:
            break
        }
        if showsFields, !isSending, typedSeconds == nil {
            return (String(localized: "Type a length of at least a minute, such as 1h 15m, 45m or 1.5h."), .red)
        }
        guard let message = draft.message else { return nil }
        return (message, draft.state == .uncertain ? .orange : .red)
    }

    @ViewBuilder
    private var answers: some View {
        if !isReady {
            if !isSending {
                Button("Keep Local Only") { manager.keepWorklogLocal(draft.id) }
            }
        } else {
            switch draft.state {
            case .awaiting, .sending:
                Button(logTitle, action: log)
                    .disabled(isSending || typedSeconds == nil)
                Button("Not Now") { manager.deferWorklog(draft.id) }
                    .disabled(isSending)
            case .failed:
                Button("Retry", action: log)
                    .disabled(typedSeconds == nil)
            case .uncertain where source == .gitlab:
                // GitLab keeps no entry Kannu could find again: the user looks, then says.
                Button("Mark Logged") { manager.markWorklogLogged(draft.id) }
                Button("Send Again") { manager.confirmWorklog(draft.id, seconds: draft.seconds, comment: nil) }
            case .uncertain:
                // Jira is checked for the entry first; it is sent again only if it is not there.
                Button("Retry") { manager.confirmWorklog(draft.id, seconds: draft.seconds, comment: draft.comment) }
            case .logged, .keptLocal:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var moreItems: some View {
        if !isSending {
            if draft.state == .uncertain && !(isReady && source == .gitlab) {
                Button("Mark as Logged") { manager.markWorklogLogged(draft.id) }
            }
            if isReady {
                Button("Keep Local Only") { manager.keepWorklogLocal(draft.id) }
            }
            if let task {
                Button("Never Ask for This Task") { manager.setAsksToLogTime(false, for: task.id) }
            }
        }
        if let openLink {
            Divider()
            Button(openLink.title) { NSWorkspace.shared.open(openLink.url) }
        }
    }

    private var logTitle: LocalizedStringKey {
        source == .gitlab ? "Log to GitLab" : "Log to Jira"
    }

    private func log() {
        guard isReady, !isSending, let seconds = typedSeconds else { return }
        manager.confirmWorklog(draft.id, seconds: seconds, comment: source == .jira ? comment : nil)
    }

    // MARK: - Put off

    /// Not now: one line, until more time is added or the user opens it again.
    private var deferredRow: some View {
        LabeledContent {
            HStack(spacing: SettingsMetrics.rowContent) {
                Button("Log…") { manager.askAboutWorklogAgain(draft.id) }
                SettingsMoreMenu {
                    moreItems
                }
            }
        } label: {
            SettingsRowLabel(
                Text(verbatim: "\(key) · \(WorkDuration.format(draft.seconds))"),
                description: Text(verbatim: String(localized: "Not now · \(caption)"))
            )
        }
    }
}
