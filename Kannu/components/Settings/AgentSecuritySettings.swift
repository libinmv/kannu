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

/// The Agent Security tab: what was found, ADR's scans, Kannu's own checks, the agent policy,
/// and opt-in session analysis. Split out of the Agents tab, which keeps the behaviour controls
/// (traffic light, indicator, click-through, hooks, notifications) — one tab says how agents
/// look, this one says whether they are safe.
struct AgentSecuritySettings: View {
    @ObservedObject private var adr = ADRConnection.shared
    @ObservedObject private var findingsStore = SecurityFindingsStore.shared
    @Default(.adrSnapshotDirectory) var adrSnapshotDirectory
    @Default(.adrToolDirectory) var adrToolDirectory
    @Default(.adrHighAlertMode) var adrHighAlertMode
    @Default(.adrPolicyFile) var adrPolicyFile
    @Default(.adrRunScansEnabled) var adrRunScansEnabled
    @Default(.adrDetectionEnabled) var adrDetectionEnabled
    @Default(.detectHiddenText) var detectHiddenText
    @Default(.adrDetectionConsentedAt) var adrDetectionConsentedAt
    @Default(.adrDetectionCheckout) var adrDetectionCheckout
    @Default(.adrDetectionConfirmEachRun) var adrDetectionConfirmEachRun
    @Default(.adrDetectionTriageEnabled) var adrDetectionTriageEnabled
    @Default(.adrDetectionTriageModel) var adrDetectionTriageModel
    @Default(.adrDetectionReasoningModel) var adrDetectionReasoningModel
    @Default(.adrDetectionUseAnthropicAPIKey) var adrDetectionUseAnthropicAPIKey
    @Default(.adrDetectionContextThreatIntelligence) var adrDetectionContextThreatIntelligence
    @Default(.adrDetectionContextSourceCode) var adrDetectionContextSourceCode
    @Default(.adrDetectionContextPolicy) var adrDetectionContextPolicy
    @Default(.adrDetectionTimeoutSeconds) var adrDetectionTimeoutSeconds
    @Default(.adrDetectionMaxMessages) var adrDetectionMaxMessages
    @Default(.enableAgentStatusFeature) var enableAgentStatusFeature
    @State private var adrOpenAIKeyText = ""
    @State private var adrAnthropicKeyText = ""
    @State private var showDetectionConsent = false
    @State private var showPolicyRules = false
    /// Which ADR Detection keys the keychain holds; see `adrSecretRow`.
    @State private var storedADRSecrets: Set<SecureSecretKey> = []

    /// The literal form: `SettingsTab` is private to SettingsView.swift, and the highlight
    /// inventory test accepts exactly this shape (the UsageSettings precedent).
    private func highlightID(_ title: String) -> String {
        "agentSecurity-\(title)"
    }

    var body: some View {
        Form {
            if enableAgentStatusFeature {
                securityFindingsSection
                adrDiscoverySection
                kannuChecksSection
                agentPolicySection
                sessionAnalysisSections
            } else {
                Section {
                    SettingsFooter("Agent monitoring is off. Turn on Enable Agent Status in the Agents tab and the security checks, findings and scans appear here.")
                } header: {
                    SettingsSectionHeader("Agent Security")
                }
            }
        }
        .onAppear {
            refreshStoredADRSecrets()
        }
        .navigationTitle("Agent Security")
    }

    // MARK: - Security

    private var securityFindingsSection: some View {
        Section {
            if let error = findingsStore.snapshotError {
                SettingsErrorText(error)
            }

            let ranking = findingsStore.ranking
            if ranking.visible.isEmpty {
                Text(findingsStore.lastScan == nil
                     ? String(localized: "No findings yet.")
                     : String(localized: "No open findings."))
                    .settingsDescriptionStyle()
            } else {
                ForEach(ranking.visible) { finding in
                    SecurityFindingRow(
                        finding: finding,
                        copyForAgent: { findingsStore.copyAgentPrompt(for: finding) },
                        acknowledge: { findingsStore.acknowledge(finding.id) },
                        snooze: { findingsStore.snooze(finding.id, for: 24 * 3600) },
                        openChat: findingsStore.hasChat(for: finding)
                            ? { if !findingsStore.openChat(for: finding) { NSSound.beep() } }
                            : nil
                    )
                }
            }
            if !findingsStore.reviewQueue.isEmpty {
                Text("Needs review: \(findingsStore.reviewQueue.count) uncatalogued AI tool(s) — see the snapshot for paths.")
                    .settingsDescriptionStyle()
            }

            SettingsRow("High-severity alerts in the notch", description: adrHighAlertMode.description) {
                Picker("High-severity alerts in the notch", selection: $adrHighAlertMode) {
                    ForEach(ADRHighAlertMode.allCases) { mode in
                        Text(mode.localizedName).tag(mode)
                    }
                }
            }
            .settingsHighlight(id: highlightID("High-severity alerts in the notch"))

            if !findingsStore.acknowledgedIDs.isEmpty || !findingsStore.snoozes.isEmpty {
                SettingsActionRow {
                    Button("Show acknowledged and snoozed again") { findingsStore.clearAcknowledgements() }
                }
            }
        } header: {
            SettingsSectionHeader("Security findings")
                .settingsHighlight(id: highlightID("Security findings"))
        } footer: {
            SettingsFooter("Kannu never changes your agent or MCP settings. Nothing leaves this Mac unless you turn on push notifications or session analysis. Details: docs/ADR.md in the Kannu repository.")
        }
        .onAppear {
            if adr.discovery.state == .unchecked { adr.checkAgain() }
            if adrDetectionEnabled, adr.detection.state == .unchecked { adr.checkDetection() }
        }
    }

    /// The ADR area, glance-first: the scanner's status, the scan controls, the newest result —
    /// then everything a first-time user does not need (folders, the scan policy, the optional
    /// Sensor) behind one Advanced disclosure. Search entries for the tucked-away rows land on
    /// the disclosure itself, so search never points at a hidden row.
    private var adrDiscoverySection: some View {
        Section {
            adrToolRow(.discovery)
                .settingsHighlight(id: highlightID("Connect ADR"))
            if !adr.discovery.isFound && adr.discovery.state != .unchecked {
                adrInstallGuidance(.discovery)
            }

            if adr.discovery.isFound {
                SettingsRow("Let Kannu run scans", description: "Kannu runs a scan once a day, and again whenever an AI tool's MCP servers change. With this off, it shows only the scans something else runs.") {
                    Defaults.Toggle(key: .adrRunScansEnabled) {
                        Text("Let Kannu run scans")
                    }
                }
                .settingsHighlight(id: highlightID("Let Kannu run scans"))

                LabeledContent {
                    Button(findingsStore.isScanning ? "Scanning…" : "Scan now") {
                        findingsStore.runScanNow(reason: "manual")
                    }
                    .disabled(findingsStore.isScanning)
                } label: {
                    VStack(alignment: .leading, spacing: SettingsMetrics.labelStack) {
                        Text("Scan this Mac")
                        Group {
                            if let at = findingsStore.lastKannuScanAt {
                                Text("Last run by Kannu \(at.formatted(date: .abbreviated, time: .shortened))")
                            } else {
                                Text("Not run by Kannu yet")
                            }
                        }
                        .settingsDescriptionStyle()
                        if adrRunScansEnabled, findingsStore.automaticScansActive, !findingsStore.isScanning {
                            Text(verbatim: nextAutomaticScanText)
                                .settingsDescriptionStyle()
                        }
                    }
                }
                .settingsHighlight(id: highlightID("Scan now"))
                if let error = findingsStore.lastScanError {
                    SettingsErrorText(error)
                }
            }

            adrLastScanRow

            // Folders, ADR's own scan policy and the optional Sensor: needed rarely, and the
            // reason this section used to read as a wall. Entries in the search index for these
            // rows point at this disclosure's id (docs/SETTINGS.md).
            DisclosureGroup {
                LabeledContent {
                    HStack(spacing: SettingsMetrics.rowContent) {
                        SettingsValueText(adrToolDirectory.isEmpty
                                          ? String(localized: "Standard places")
                                          : adrToolDirectory.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        Button("Choose…") { chooseToolDirectory() }
                        if !adrToolDirectory.isEmpty {
                            Button("Clear") {
                                adrToolDirectory = ""
                                adr.checkAgain()
                                adr.checkDetection()
                            }
                        }
                    }
                } label: {
                    SettingsRowLabel("ADR tools folder", description: "Only if the tools are somewhere else: Kannu already looks in ~/.local/bin, uv's tool folders, /opt/homebrew/bin and /usr/local/bin.")
                }
                if let protected = ADRToolFolder.protectedFolderName(for: adrToolDirectory, home: NSHomeDirectory()) {
                    SettingsErrorText(String(localized: "This folder is in \(protected). macOS asks for permission whenever Kannu looks for the tools there; a folder outside it avoids the prompt."))
                }

                LabeledContent {
                    HStack(spacing: SettingsMetrics.rowContent) {
                        SettingsValueText(SecurityFindingsStore.snapshotDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        Button("Choose…") { chooseSnapshotDirectory() }
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([SecurityFindingsStore.snapshotDirectory])
                        }
                    }
                } label: {
                    SettingsRowLabel("Snapshot folder", description: "Where scan results land. Kannu also reads snapshots something else drops here, like a fleet scheduler's.")
                }

                if adr.discovery.isFound {
                    LabeledContent {
                        HStack(spacing: SettingsMetrics.rowContent) {
                            SettingsValueText(adrPolicyFile.isEmpty ? String(localized: "none") : adrPolicyFile.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            Button("Choose…") { choosePolicyFile() }
                            if !adrPolicyFile.isEmpty {
                                Button("Clear") { adrPolicyFile = "" }
                            }
                        }
                    } label: {
                        SettingsRowLabel("ADR scan policy", description: "ADR's own policy file — approved, forbidden and tenant_domains lists for the MCP servers on this Mac. Not the agent policy below; that one names commands and tools to block.")
                    }
                    if SecurityFindingsStore.policyFileIsMissing {
                        SettingsErrorText(String(localized: "That policy file is not there any more, so scans run without it. Choose it again, or clear it."))
                    }
                }

                adrToolRow(.sensor)
            } label: {
                SettingsRowLabel("Advanced", description: "Folders, ADR's scan policy, and the optional Sensor.")
            }
            .settingsHighlight(id: highlightID("ADR advanced"))
        } header: {
            SettingsSectionHeader("ADR scans")
        } footer: {
            SettingsFooter("Scans this Mac's AI tools and MCP servers for risky setups — unpinned or plain-HTTP servers, servers nothing declares. From ADR, Uber's open-source toolkit (Apache-2.0): you install it once, Kannu runs it and reads the results.")
        }
    }

    private var kannuChecksSection: some View {
        Section {
            SettingsRow("Look for hidden text in what agents read", description: "Some characters are invisible to you but readable by the AI, and can hide instructions. Kannu checks prompts and tool results on this Mac. No AI model is used and nothing is sent anywhere.") {
                Defaults.Toggle(key: .detectHiddenText) {
                    Text("Look for hidden text in what agents read")
                }
            }
            .settingsHighlight(id: highlightID("Look for hidden text in what agents read"))

            SettingsRow("Tell the agent when hidden text is found", description: "Off by default. Adds one short, factual note to the agent's context saying hidden text was found and where — never the hidden text. Claude Code also shows you a one-line notice.") {
                Defaults.Toggle(key: .warnAgentAboutHiddenText) {
                    Text("Tell the agent when hidden text is found")
                }
            }
            .disabled(!detectHiddenText)
            .settingsHighlight(id: highlightID("Tell the agent when hidden text is found"))

            SettingsRow("Look for secrets in prompts and tool calls", description: "Flags API keys and private keys in what you send an agent and in what an agent hands a tool. Kannu keeps only the kind of key, its first few letters, its length and a fingerprint — never the key itself.") {
                Defaults.Toggle(key: .detectSecrets) {
                    Text("Look for secrets in prompts and tool calls")
                }
            }
            .settingsHighlight(id: highlightID("Look for secrets in prompts and tool calls"))

            SettingsRow("Watch for agents touching sensitive files", description: "Flags when an agent reads keys, passwords, cloud or browser data, or changes files that run programs on their own or set what agents may do. Checked on this Mac. Nothing is sent anywhere.") {
                Defaults.Toggle(key: .detectSensitivePaths) {
                    Text("Watch for agents touching sensitive files")
                }
            }
            .settingsHighlight(id: highlightID("Watch for agents touching sensitive files"))

            SettingsRow("Notice new MCP servers", description: "Tells you when an MCP server is added to Claude Code, Claude Desktop, Cursor, VS Code, Codex, Gemini CLI, Qwen Code or opencode. The first look only learns what is already there. Project folders inside Desktop, Documents and Downloads are skipped, so macOS never asks for access.") {
                Defaults.Toggle(key: .watchMCPServers) {
                    Text("Notice new MCP servers")
                }
            }
            .settingsHighlight(id: highlightID("Notice new MCP servers"))
        } header: {
            SettingsSectionHeader("Kannu's own checks")
        } footer: {
            SettingsFooter("Kannu also flags sessions started with permission checks turned off; that check has no setting.")
        }
    }

    /// The user's own block list, enforced where a host's hook can refuse a call.
    private var agentPolicySection: some View {
        Section {
            // A raw LabeledContent, NOT SettingsRow: the row component applies `.labelsHidden()`
            // to its whole control slot (meant for the Toggle/Picker case), and a Menu in that
            // slot inherits it — the ellipsis collapsed and the "…" menu was dead. Same shape as
            // `analysisRow`, the working SettingsMoreMenu site. See docs/SETTINGS.md.
            LabeledContent {
                HStack(spacing: SettingsMetrics.rowContent) {
                    SettingsStatusText(agentPolicyStatusText, isReady: agentPolicyIsReady)
                    if case .success(let policy) = findingsStore.agentPolicyStatus {
                        Button(String(localized: "View rules")) { showPolicyRules = true }
                        .popover(isPresented: $showPolicyRules, arrowEdge: .bottom) {
                            PolicyRulesView(policy: policy)
                        }
                    }
                    // Offered for a broken file too: that is exactly when it needs fixing.
                    if agentPolicyExists {
                        Button(String(localized: "Open in Editor")) { openAgentPolicyInEditor() }
                    }
                    SettingsMoreMenu {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([AgentPolicy.fileURL])
                        }
                        .disabled(!agentPolicyExists)
                        Button("Check again") { findingsStore.checkAgentPolicy() }
                    }
                }
            } label: {
                SettingsRowLabel("Policy rules", description: "A JSON file — ~/.kannu/agent-policy.json — naming commands and tools an agent may not use. Kannu never writes rules of its own; Import below copies a file you chose, byte for byte, after checking it. Open in Editor to change it; Kannu re-checks it every time it is saved. Every match is reported as a finding; whether it is also blocked is the switch below.")
            }
            .settingsHighlight(id: highlightID("Policy rules"))
            if case .failure(let error) = findingsStore.agentPolicyStatus, agentPolicyExists, error.hookIgnoresFile {
                // The hook ignores a malformed file whole (docs/REGRESSIONS.md entry 1: it never
                // fails closed), so say what that costs rather than only what is wrong.
                SettingsErrorText(String(localized: "Until this is fixed, Kannu ignores the whole file: no rule is reported or blocked."))
            }
            SettingsActionRow("Get a policy", description: "Have your agent draft one, or import a JSON file you already have. Kannu checks the file before it counts; a broken import never replaces a working policy.") {
                Button("Import…") { importAgentPolicy() }
                Button("Copy a prompt that drafts a policy") { findingsStore.copyPolicyDraftingPrompt() }
            }
            .settingsHighlight(id: highlightID("Get a policy"))
            if let importError = findingsStore.agentPolicyImportError {
                SettingsErrorText(String(localized: "Not imported — \(importError)"))
            }
            SettingsRow("Block matching tool calls", description: "Off: every match is reported and the call runs. On: Claude Code and Cursor refuse the call and tell the agent why — their hooks can say no. Every other agent still only gets the finding.") {
                Defaults.Toggle(key: .enforceAgentPolicy) {
                    Text("Block matching tool calls")
                }
            }
            .settingsHighlight(id: highlightID("Block matching tool calls"))
        } header: {
            SettingsSectionHeader("Agent policy")
        } footer: {
            SettingsFooter("A command rule matches a command's first word (or its basename) in any segment joined by ;, &&, || or |, after sudo, env and nohup; a multi-word rule matches a segment that starts with it; a tool rule matches the tool's exact name. No regex. Not the ADR policy file above — that one is about MCP servers.")
        }
        .onAppear {
            findingsStore.agentPolicyImportError = nil
            findingsStore.checkAgentPolicy()
        }
    }

    /// The "Import…" button: pick a JSON file, validate it with the same parser the status row
    /// uses, and only then copy it into place — with a confirm when a policy already exists.
    private func importAgentPolicy() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose the agent policy JSON to copy to ~/.kannu/agent-policy.json")
        ModalPresenter.present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            let proceed = { findingsStore.importPolicyFile(from: url) }
            if agentPolicyExists {
                let alert = NSAlert()
                alert.messageText = String(localized: "Replace the current policy?")
                alert.informativeText = String(localized: "~/.kannu/agent-policy.json already exists. Importing replaces it with the chosen file.")
                alert.addButton(withTitle: String(localized: "Replace"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                ModalPresenter.present(alert) { answer in
                    if answer == .alertFirstButtonReturn { proceed() }
                }
            } else {
                proceed()
            }
        }
    }

    private var agentPolicyStatusText: String {
        switch findingsStore.agentPolicyStatus {
        case .success(let policy):
            return String(localized: "\(policy.rules.count) rules · ~/.kannu/agent-policy.json")
        case .failure(let error):
            return error.message
        }
    }

    private var agentPolicyIsReady: Bool {
        if case .success = findingsStore.agentPolicyStatus { return true }
        return false
    }

    private var agentPolicyExists: Bool {
        if case .failure(.notFound) = findingsStore.agentPolicyStatus { return false }
        return true
    }

    /// "Open in Editor": the user's own default app for JSON does the writing, so Kannu still
    /// never writes rules of its own. The store's watcher re-checks on every save. If no app
    /// claims JSON, show the file in Finder instead of doing nothing.
    private func openAgentPolicyInEditor() {
        if !NSWorkspace.shared.open(AgentPolicy.fileURL) {
            NSWorkspace.shared.activateFileViewerSelecting([AgentPolicy.fileURL])
        }
    }

    /// ADR Detection — off by default, behind a consent alert, and every run is the user's click.
    @ViewBuilder
    private var sessionAnalysisSections: some View {
        Section {
            // Consent is asked through a SwiftUI alert, not a modal inside the binding setter: a
            // nested run loop there fought the toggle's own state update and the switch fell back.
            SettingsRow("Analyze chats with ADR Detection", description: "Opt-in, per chat. Right-click a finished Claude Code chat in the notch and choose \"Analyze with ADR Detection\". The transcript is sent to the model providers below under your own keys — nothing is ever sent automatically.") {
                Toggle(isOn: Binding(
                    get: { adrDetectionEnabled },
                    set: { newValue in
                        guard newValue else { adrDetectionEnabled = false; return }
                        if adrDetectionConsentedAt == nil {
                            showDetectionConsent = true
                            return
                        }
                        adrDetectionEnabled = true
                        adr.checkDetection()
                    }
                )) {
                    Text("Analyze chats with ADR Detection")
                }
            }
            .settingsHighlight(id: highlightID("Analyze chats with ADR Detection"))
            .alert("Turn on ADR Detection session analysis?", isPresented: $showDetectionConsent) {
                Button("Turn on") {
                    adrDetectionConsentedAt = Date()
                    adrDetectionEnabled = true
                    adr.checkDetection()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(detectionConsentText)
            }

            if adrDetectionEnabled {
                detectionCheckoutRows
            }
        } header: {
            SettingsSectionHeader("Session analysis")
        }

        if adrDetectionEnabled {
            detectionSetupSections
        }
    }

    /// Where ADR Detection lives and whether it is ready; shown once analysis is on.
    @ViewBuilder
    private var detectionCheckoutRows: some View {
        LabeledContent {
            HStack(spacing: SettingsMetrics.rowContent) {
                SettingsValueText(adrDetectionCheckout.isEmpty ? String(localized: "none") : adrDetectionCheckout.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                Button("Choose…") { chooseDetectionCheckout() }
                Button("Check") { adr.checkDetection() }
            }
        } label: {
            VStack(alignment: .leading, spacing: SettingsMetrics.labelStack) {
                Text("Detection checkout")
                SettingsStatusText(adr.detection.caption, isReady: adr.detection.isReady)
            }
        }
        .settingsHighlight(id: highlightID("Detection checkout"))

        LabeledContent {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ADRConnection.detectionCloneCommand, forType: .string)
            }
        } label: {
            VStack(alignment: .leading, spacing: SettingsMetrics.labelStack) {
                Text(verbatim: ADRConnection.detectionCloneCommand)
                    .settingsDescriptionStyle()
                    .monospaced()
                Text("Needs uv and Python 3.10–3.12 (uv fetches one). ADR Detection is Uber's research tool (Apache-2.0); it runs an unattended Claude session on this Mac to reason about the chat, with file edits disallowed.")
                    .settingsDescriptionStyle()
            }
        }
    }

    /// Models, keys, context and limits for ADR Detection, and the recent analyses.
    @ViewBuilder
    private var detectionSetupSections: some View {
        Section {
            TextField("Reasoning model (Claude)", text: $adrDetectionReasoningModel)
                .settingsHighlight(id: highlightID("Reasoning model"))
            SettingsRow("Use an Anthropic API key instead of your Claude Code login",
                        description: adrDetectionUseAnthropicAPIKey
                            ? String(localized: "Analyses are billed to the API key below.")
                            : String(localized: "Analyses count against your Claude subscription's 5-hour and weekly limits.")) {
                Toggle("Use an Anthropic API key instead of your Claude Code login", isOn: $adrDetectionUseAnthropicAPIKey)
            }
            .settingsHighlight(id: highlightID("Use an Anthropic API key"))
            if adrDetectionUseAnthropicAPIKey {
                adrSecretRow(title: "Anthropic API key", key: .claudeAPIKey, text: $adrAnthropicKeyText)
            }

            SettingsRow("Triage with OpenAI first", description: "Upstream's pipeline: a cheap gpt-4o pass decides whether the Claude reasoning agent runs at all. Off means Claude only — no OpenAI account needed.") {
                Toggle("Triage with OpenAI first", isOn: $adrDetectionTriageEnabled)
            }
            .settingsHighlight(id: highlightID("Triage with OpenAI first"))
            if adrDetectionTriageEnabled {
                TextField("Triage model (OpenAI)", text: $adrDetectionTriageModel)
                adrSecretRow(title: "OpenAI API key", key: .openaiAPIKey, text: $adrOpenAIKeyText)
            }
        } header: {
            SettingsSectionHeader("Analysis models")
        }

        Section {
            Toggle("Context: threat intelligence", isOn: $adrDetectionContextThreatIntelligence)
            Toggle("Context: source code analyzer", isOn: $adrDetectionContextSourceCode)
            Toggle("Context: policy store", isOn: $adrDetectionContextPolicy)
            Picker("Reasoning timeout", selection: $adrDetectionTimeoutSeconds) {
                Text("2 minutes").tag(120)
                Text("5 minutes").tag(300)
                Text("10 minutes").tag(600)
            }
            Picker("Messages sent (newest)", selection: $adrDetectionMaxMessages) {
                Text("100").tag(100)
                Text("200").tag(200)
                Text("400").tag(400)
                Text("800").tag(800)
            }
            .settingsHighlight(id: highlightID("Messages sent"))
            Toggle("Confirm before every analysis", isOn: $adrDetectionConfirmEachRun)
                .settingsHighlight(id: highlightID("Confirm before every analysis"))
        } header: {
            SettingsSectionHeader("Analysis context and limits")
        } footer: {
            SettingsFooter("The three context options are ADR's local MCP context servers; they read bundled data and this Mac only.")
        }

        if findingsStore.lastAnalysisError != nil || !findingsStore.analyses.isEmpty {
            Section {
                if let error = findingsStore.lastAnalysisError {
                    SettingsErrorText(error)
                }
                ForEach(findingsStore.analyses.prefix(5)) { analysis in
                    analysisRow(analysis)
                }
            } header: {
                SettingsSectionHeader("Recent analyses")
            }
        }
    }

    private func analysisRow(_ analysis: ADRSessionAnalysis) -> some View {
        let cost = analysis.costUSD.map { String(format: " · $%.3f", $0) } ?? ""
        return LabeledContent {
            HStack(spacing: SettingsMetrics.rowContent) {
                if analysis.isMalicious {
                    CopyForAgentButton {
                        if let finding = analysis.finding() { findingsStore.copyAgentPrompt(for: finding) }
                    }
                }
                SettingsMoreMenu {
                    if let path = analysis.reportPath {
                        Button("Reveal Report in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                    Button("Forget") { findingsStore.forgetAnalysis(for: analysis.conversationID) }
                }
            }
        } label: {
            SettingsRowLabel(
                verbatim: analysis.chatName ?? analysis.conversationID,
                description: "\(analysis.date.formatted(date: .abbreviated, time: .shortened)) · \(analysis.shortLabel)\(cost)"
            )
            .lineLimit(2)
        }
    }

    /// `stored` comes from `storedADRSecrets`, read when the tab appears and updated by Save and
    /// Remove — never a keychain read per render (the tab re-renders on every monitor publish).
    @ViewBuilder
    private func adrSecretRow(title: String, key: SecureSecretKey, text: Binding<String>) -> some View {
        HStack(spacing: SettingsMetrics.rowContent) {
            SecureField(title, text: text)
            Button("Save") {
                SecureSecretsStore.set(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines), for: key)
                text.wrappedValue = ""
                refreshStoredADRSecrets()
            }
            .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if storedADRSecrets.contains(key) {
                Text("stored")
                    .settingsDescriptionStyle()
                Button("Remove") {
                    SecureSecretsStore.removeValue(for: key)
                    refreshStoredADRSecrets()
                }
            }
        }
    }

    private func refreshStoredADRSecrets() {
        storedADRSecrets = Set([SecureSecretKey.claudeAPIKey, .openaiAPIKey].filter { !SecureSecretsStore.value(for: $0).isEmpty })
    }

    /// The one-time consent, in plain words: what leaves the Mac, where, and when.
    private var detectionConsentText: String {
        String(localized: """
        Nothing is analysed automatically. When you right-click a finished chat and choose "Analyze with ADR Detection", that one chat's transcript is sent out:

        • to Anthropic, through your Claude Code login (uses your Claude quota) or an API key you store;
        • to OpenAI, only if you turn triage on.

        By default Kannu asks before every run. ADR Detection is a research tool from Uber (Apache-2.0); it runs an unattended Claude session on this Mac with file edits disallowed.
        """)
    }

    private func chooseDetectionCheckout() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Use checkout")
        panel.message = String(localized: "Choose the ADR/Detection folder you cloned and synced with uv")
        ModalPresenter.present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            adrDetectionCheckout = url.path
            adr.checkDetection()
        }
    }

    /// An ADR tool: its name, and a status line with a dot (green when installed); Discovery also
    /// gets "Check again".
    private func adrToolRow(_ tool: ADRConnection.Tool) -> some View {
        let status = tool == .discovery ? adr.discovery : adr.sensor
        return LabeledContent {
            HStack(spacing: SettingsMetrics.rowContent) {
                // Kannu never installs software: the command is copied for the user to run.
                if tool == .sensor, status.state == .notFound {
                    Button("Copy install command") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(tool.installCommand, forType: .string)
                    }
                }
                Button(adr.isChecking ? "Checking…" : "Check again") { adr.checkAgain() }
                    .disabled(adr.isChecking)
            }
        } label: {
            VStack(alignment: .leading, spacing: SettingsMetrics.labelStack) {
                if tool == .sensor {
                    (Text("ADR Sensor") + Text(verbatim: " · ") + Text("Optional").foregroundStyle(.secondary))
                        .textSelection(.enabled)
                } else {
                    Text(tool.displayName)
                }
                SettingsStatusText(adrStatusCaption(status, optional: tool == .sensor), isReady: status.isFound)
                if tool == .sensor {
                    Text("Not needed for findings, and Kannu does not use it yet. It exports agent sessions for a security team's SIEM.")
                        .settingsDescriptionStyle()
                }
            }
        }
    }

    private func chooseToolDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Use folder")
        ModalPresenter.present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            adrToolDirectory = url.path
            adr.checkAgain()
            adr.checkDetection()
        }
    }

    private func adrStatusCaption(_ status: ADRConnection.Status, optional: Bool = false) -> String {
        switch status.state {
        case .unchecked: return String(localized: "Not checked yet")
        case .notFound: return optional ? String(localized: "Not installed — optional") : String(localized: "Not installed")
        case .found(let executable, let version):
            let shortPath = executable.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            return version.map { "\($0) · \(shortPath)" } ?? shortPath
        }
    }

    @ViewBuilder
    private func adrInstallGuidance(_ tool: ADRConnection.Tool) -> some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.footerStack) {
            SettingsPermissionCallout(
                title: String(localized: "Connect ADR"),
                message: String(localized: "Install ADR Discovery once with uv (or pipx), then press Check again. Requires Python 3.11 or newer; uv brings its own."),
                icon: "shield.lefthalf.filled",
                iconColor: .blue,
                requestButtonTitle: String(localized: "Copy install command"),
                openSettingsButtonTitle: String(localized: "Open ADR on GitHub"),
                requestAction: {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(tool.installCommand, forType: .string)
                },
                openSettingsAction: { NSWorkspace.shared.open(ADRConnection.projectURL) }
            )
            Text(verbatim: tool.installCommand)
                .settingsDescriptionStyle()
                .monospaced()
        }
    }

    /// "Next automatic scan Sep 12, 5:54 AM · the last scan failed" — the sooner-than-daily time
    /// is the retry, so the line says why rather than naming the mechanism.
    private var nextAutomaticScanText: String {
        let when: String
        if let next = findingsStore.nextAutomaticScanAt, next > Date().addingTimeInterval(60) {
            when = String(localized: "Next automatic scan \(next.formatted(date: .abbreviated, time: .shortened))")
        } else {
            when = String(localized: "Next automatic scan within a minute")
        }
        guard findingsStore.consecutiveScanFailures > 0 else { return when }
        return when + " · " + String(localized: "the last scan failed")
    }

    @ViewBuilder
    private var adrLastScanRow: some View {
        if let scan = findingsStore.lastScan {
            let coverage = scan.coverageComplete
                ? String(localized: "full coverage")
                : String(localized: "partial coverage (\(scan.coverageGaps) gaps)")
            SettingsNoteRow(
                "Newest scan result",
                description: String(localized: "\(scan.date.formatted(date: .abbreviated, time: .shortened)) · \(scan.assetCount) assets · \(scan.findingCount) findings · \(coverage) · catalog \(scan.catalogVersion)"),
                tint: scan.coverageComplete ? nil : .orange)
        } else {
            SettingsNoteRow("Newest scan result", description: String(localized: "No scans yet"))
        }
    }

    private func choosePolicyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = String(localized: "Use policy")
        ModalPresenter.present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            adrPolicyFile = url.path
        }
    }

    private func chooseSnapshotDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = SecurityFindingsStore.snapshotDirectory
        panel.prompt = String(localized: "Use folder")
        ModalPresenter.present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            adrSnapshotDirectory = url.path
            findingsStore.directoryChanged()
        }
    }
}

#if DEBUG
extension AgentSecuritySettings {
    /// DEBUG snapshot harness: the ADR Detection rows that only show once analysis is on, without
    /// turning it on (the harness shares the user's Defaults).
    static func snapshotDetectionRows() -> AnyView {
        let settings = AgentSecuritySettings()
        return AnyView(Form {
            Section { settings.detectionCheckoutRows } header: { SettingsSectionHeader("Session analysis") }
            settings.detectionSetupSections
        })
    }

    /// DEBUG snapshot harness: the findings rows as the Security findings section draws them.
    static func snapshotFindingRows(_ findings: [AgentSecurityFinding]) -> AnyView {
        AnyView(Form {
            Section {
                ForEach(findings) { finding in
                    SecurityFindingRow(finding: finding, copyForAgent: {}, acknowledge: {}, snooze: {},
                                       openChat: finding.sessionID == nil ? nil : {})
                }
            } header: {
                SettingsSectionHeader("Security findings")
            }
        })
    }
}
#endif
