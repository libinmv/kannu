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

import XCTest

/// A beta tester: "the music and presentation happened when I was showered with a lot of permission
/// request." Accepting the Terms started the welcome music, the notch's hello, the onboarding window
/// with a Focus pop-up over it, and four macOS permission dialogs, all in the same second. These pin
/// the fix: onboarding is silent and asks for each permission on its own step, nothing touches a
/// permission before that, and the music waits for Finish. The code is AppKit and SwiftUI, so its
/// text is read.
final class FirstLaunchRulesTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private static let watched = [
        "Kannu/KannuApp.swift",
        "Kannu/components/Onboarding/OnboardingView.swift",
        "Kannu/components/Onboarding/MusicControllerSelectionView.swift",
        "Kannu/managers/MediaKeyInterceptor.swift",
        "Kannu/managers/LockScreenWeatherManager.swift",
        "Kannu/managers/BluetoothAudioManager.swift",
        "Kannu/managers/DownloadManager.swift",
        "Kannu/managers/AgentStatus/CursorAgentStatusMonitor.swift",
        "Kannu/managers/AnimatedArtworkManager.swift",
        "Kannu/managers/ClipboardManager.swift",
        "Kannu/components/AgentStatus/NotchAgentStatusView.swift",
        "Kannu/components/Settings/SettingsView.swift",
        "Kannu/managers/AppleNotesSyncManager.swift",
        "Kannu/components/Onboarding/NotesSelectionView.swift",
    ]

    func testTheFirstRunFollowsTheRules() throws {
        XCTAssertEqual(Self.problems(in: try Self.sources()), [])
    }

    /// The prompt-raising calls live only where a gate or a user's press guards them.
    func testPromptRaisingCallsLiveOnlyBehindAGateOrAButton() throws {
        let files = try Self.appFiles()
        XCTAssertEqual(Self.files(in: files, containing: "kAXTrustedCheckOptionPrompt"),
                       ["AccessibilityPermissionStore.swift", "MediaKeyInterceptor.swift"])
        XCTAssertEqual(Self.files(in: files, containing: "requestWhenInUseAuthorization"),
                       ["LaunchPermissionManager.swift", "LockScreenWeatherManager.swift"])
        XCTAssertEqual(Self.files(in: files, containing: "CBCentralManager("),
                       ["BluetoothAudioManager.swift", "LaunchPermissionManager.swift"])
        XCTAssertEqual(Self.files(in: files, containing: "MusicAuthorization.request()"),
                       ["AnimatedArtworkManager.swift", "LaunchPermissionManager.swift"])
        XCTAssertEqual(Self.files(in: files, containing: "AEDeterminePermissionToAutomateTarget("),
                       ["LaunchPermissionManager.swift"])
    }

    func testTheScannerCatchesTheOldFirstRun() throws {
        let sources = try Self.sources()
        func planted(_ path: String, _ old: String, _ new: String) -> [String: String] {
            var copy = sources
            copy[path] = copy[path]?.replacingOccurrences(of: old, with: new)
            XCTAssertNotEqual(copy[path], sources[path], "the plant did not take in \(path): \(old)")
            return copy
        }

        XCTAssertEqual(Self.problems(in: planted(
            "Kannu/KannuApp.swift",
            "        if !LaunchPermissionManager.isOnboardingComplete && !AppRuntimeEnvironment.isUITesting {\n            DispatchQueue.main.async {\n                self.showOnboardingWindow()\n            }\n",
            "        if !LaunchPermissionManager.isOnboardingComplete && !AppRuntimeEnvironment.isUITesting {\n            DispatchQueue.main.async {\n                self.showOnboardingWindow()\n            }\n            playWelcomeSound()\n"
        )), ["the welcome music plays outside startHello()", "continueLaunch() plays the welcome music"])

        XCTAssertEqual(Self.problems(in: planted(
            "Kannu/KannuApp.swift",
            "        if LaunchPermissionManager.isOnboardingComplete {\n            autoEnableLaunchAtLoginIfNeeded()\n        }\n",
            "        autoEnableLaunchAtLoginIfNeeded()\n"
        )), ["continueLaunch() registers the login item on a fresh install"])

        XCTAssertEqual(Self.problems(in: planted(
            "Kannu/components/Onboarding/OnboardingView.swift",
            "    case permissions\n    case finished\n",
            "    case finished\n    case permissions\n"
        )), ["onboarding does not end on .permissions then .finished"])

        XCTAssertEqual(Self.problems(in: planted(
            "Kannu/components/Onboarding/OnboardingView.swift",
            "        .frame(width: 400, height: 600)\n",
            "        .frame(width: 400, height: 600)\n        .confirmationDialog(\"Focus detection mode\", isPresented: .constant(true)) {}\n"
        )), ["onboarding pops a dialog over its own steps"])

        XCTAssertEqual(Self.problems(in: planted(
            "Kannu/components/Onboarding/MusicControllerSelectionView.swift",
            "                onContinue(selectedMediaController)\n",
            "                NotificationCenter.default.post(name: Notification.Name.mediaControllerChanged, object: nil)\n                onContinue(selectedMediaController)\n"
        )), ["the music source step switches the source (Automation dialog) before the Permissions step"])

        XCTAssertEqual(Self.problems(in: planted(
            "Kannu/managers/MediaKeyInterceptor.swift",
            "LaunchPermissionManager.mayTouch(.accessibility)", "true"
        )), ["MediaKeyInterceptor asks for Accessibility without the gate"])

        XCTAssertEqual(Self.problems(in: planted(
            "Kannu/managers/LockScreenWeatherManager.swift",
            "LaunchPermissionManager.mayTouch(.location)", "true"
        )), ["the weather asks for Location without the gate"])

        XCTAssertEqual(Self.problems(in: planted(
            "Kannu/managers/BluetoothAudioManager.swift",
            "        startIfPermitted()\n        launchPermissionObserver",
            "        setupBluetoothObservers()\n        startIfPermitted()\n        launchPermissionObserver"
        )), ["BluetoothAudioManager touches Bluetooth before the gate"])

        XCTAssertEqual(Self.problems(in: planted(
            "Kannu/managers/BluetoothAudioManager.swift",
            "private lazy var batteryReader = BluetoothLEBatteryReader()",
            "private let batteryReader = BluetoothLEBatteryReader()"
        )), ["BluetoothAudioManager builds its CBCentralManager at init"])

        XCTAssertEqual(Self.problems(in: planted(
            "Kannu/managers/DownloadManager.swift",
            "LaunchPermissionManager.mayTouch(.downloads)", "true"
        )), ["DownloadManager reads ~/Downloads without the gate"])

        XCTAssertEqual(Self.problems(in: planted(
            "Kannu/managers/AgentStatus/CursorAgentStatusMonitor.swift",
            "        guard LaunchPermissionManager.mayTouch(.warp) else { return }\n", ""
        )), ["agent status reads Warp's container without the gate", "something looks up Warp's database without the gate"])

        XCTAssertEqual(Self.problems(in: planted(
            "Kannu/managers/AgentStatus/CursorAgentStatusMonitor.swift",
            "if LaunchPermissionManager.mayTouch(.warp), let warpDB = WarpAgentStore.databaseURL {",
            "if let warpDB = WarpAgentStore.databaseURL {"
        )), ["something looks up Warp's database without the gate"])

        XCTAssertEqual(Self.problems(in: planted(
            "Kannu/components/AgentStatus/NotchAgentStatusView.swift",
            "detected: LaunchPermissionManager.isWarpInstalled",
            "detected: WarpAgentStore.databaseURL != nil"
        )), ["something looks up Warp's database without the gate"])

        XCTAssertEqual(Self.problems(in: planted(
            "Kannu/managers/AnimatedArtworkManager.swift",
            "LaunchPermissionManager.mayTouch(.musicAutomation)", "true"
        )), ["Apple Music artwork asks for MusicKit without the gate"])

        XCTAssertEqual(Self.problems(in: planted(
            "Kannu/managers/AppleNotesSyncManager.swift",
            "        guard !isSyncing, mayTouchNotes else { return nil }\n",
            "        guard !isSyncing else { return nil }\n"
        )), ["Apple Notes sync runs AppleScript without the Notes gate"])

        XCTAssertEqual(Self.problems(in: planted(
            "Kannu/managers/AppleNotesSyncManager.swift",
            "guard LaunchPermissionManager.mayTouch(.notesAutomation) else {",
            "guard true else {"
        )), ["Apple Notes sync runs AppleScript without the Notes gate"])

        XCTAssertEqual(Self.problems(in: planted(
            "Kannu/components/Onboarding/NotesSelectionView.swift",
            "                onContinue(selection)\n",
            "                Defaults[.enableAppleNotesSync] = true\n                onContinue(selection)\n"
        )), ["the Notes step turns sync on (Automation dialog) before the Permissions step"])

        XCTAssertEqual(Self.problems(in: planted(
            "Kannu/managers/ClipboardManager.swift",
            "static let clipboardDataDirectory: URL = AppSupportPaths.child(\"ClipboardData\")",
            "static let clipboardDataDirectory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]"
        )), ["clipboard history touches ~/Documents outside the upgrade move"])
    }

    // MARK: - Rules

    static func problems(in sources: [String: String]) -> [String] {
        var problems: [String] = []
        let app = sources["Kannu/KannuApp.swift"] ?? ""

        let startHello = body(after: "func startHello() {", in: app) ?? ""
        let musicCalls = app.components(separatedBy: "playWelcomeSound()").count - 1
        let musicDefinitions = app.components(separatedBy: "func playWelcomeSound()").count - 1
        if !startHello.contains("playWelcomeSound()") || musicCalls - musicDefinitions != 1 {
            problems.append("the welcome music plays outside startHello()")
        }
        let continueLaunch = body(after: "private func continueLaunch() {", in: app) ?? ""
        if continueLaunch.contains("playWelcomeSound()") || continueLaunch.contains("startHello()") {
            problems.append("continueLaunch() plays the welcome music")
        }
        if continueLaunch.contains("autoEnableLaunchAtLoginIfNeeded()"),
           !continueLaunch.contains("if LaunchPermissionManager.isOnboardingComplete {\n            autoEnableLaunchAtLoginIfNeeded()") {
            problems.append("continueLaunch() registers the login item on a fresh install")
        }

        let onboarding = sources["Kannu/components/Onboarding/OnboardingView.swift"] ?? ""
        let steps = (body(after: "enum OnboardingStep: CaseIterable {", in: onboarding) ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("case ") }
        if steps.suffix(2) != ["case permissions", "case finished"] {
            problems.append("onboarding does not end on .permissions then .finished")
        }
        if onboarding.contains(".confirmationDialog") || onboarding.contains(".alert(") {
            problems.append("onboarding pops a dialog over its own steps")
        }
        if (sources["Kannu/components/Onboarding/MusicControllerSelectionView.swift"] ?? "").contains("mediaControllerChanged") {
            problems.append("the music source step switches the source (Automation dialog) before the Permissions step")
        }

        let gates: [(path: String, marker: String, gate: String, problem: String)] = [
            ("Kannu/managers/MediaKeyInterceptor.swift", "kAXTrustedCheckOptionPrompt",
             "LaunchPermissionManager.mayTouch(.accessibility)", "MediaKeyInterceptor asks for Accessibility without the gate"),
            ("Kannu/managers/LockScreenWeatherManager.swift", "requestWhenInUseAuthorization",
             "LaunchPermissionManager.mayTouch(.location)", "the weather asks for Location without the gate"),
            ("Kannu/managers/DownloadManager.swift", "let readable = downloadsDirectory.map",
             "LaunchPermissionManager.mayTouch(.downloads)", "DownloadManager reads ~/Downloads without the gate"),
            ("Kannu/managers/AgentStatus/CursorAgentStatusMonitor.swift", "WarpAgentStore.loadRecentExchanges",
             "LaunchPermissionManager.mayTouch(.warp)", "agent status reads Warp's container without the gate"),
            ("Kannu/managers/AnimatedArtworkManager.swift", "MusicAuthorization.request()",
             "LaunchPermissionManager.mayTouch(.musicAutomation)", "Apple Music artwork asks for MusicKit without the gate"),
        ]
        for gate in gates {
            let source = sources[gate.path] ?? ""
            if !(enclosingFunction(of: gate.marker, in: source)?.contains(gate.gate) ?? false) {
                problems.append(gate.problem)
            }
        }

        // Every AppleScript Notes sync runs raises Notes' Automation dialog the first time: each entry
        // point checks the gate, and the gate is `mayTouch(.notesAutomation)`.
        let notesSync = sources["Kannu/managers/AppleNotesSyncManager.swift"] ?? ""
        let gate = body(after: "private var mayTouchNotes: Bool {", in: notesSync) ?? ""
        let entryPoints = ["func sync(localNotes:", "func pushNote(", "func deleteRemoteNote(noteId:", "func openInNotes("]
        let ungated = entryPoints.filter { !(body(after: $0, in: notesSync)?.contains("mayTouchNotes") ?? false) }
        if !gate.contains("guard LaunchPermissionManager.mayTouch(.notesAutomation) else {") || !ungated.isEmpty {
            problems.append("Apple Notes sync runs AppleScript without the Notes gate")
        }
        // The Notes step only chooses; `OnboardingView` applies the choice at Finish.
        let notesStep = sources["Kannu/components/Onboarding/NotesSelectionView.swift"] ?? ""
        let notesView = notesStep.range(of: "struct NotesSelectionView").map { String(notesStep[$0.lowerBound...]) } ?? ""
        if ["Defaults[", "NotesManager", "AppleNotesSyncManager"].contains(where: notesView.contains) {
            problems.append("the Notes step turns sync on (Automation dialog) before the Permissions step")
        }

        // Finding Warp's database stats its container, which raises the same dialog as reading it.
        let monitor = sources["Kannu/managers/AgentStatus/CursorAgentStatusMonitor.swift"] ?? ""
        let ungatedWarpLookups = monitor.components(separatedBy: "func ").dropFirst()
            .filter { $0.contains("WarpAgentStore.databaseURL") && !$0.contains("LaunchPermissionManager.mayTouch(.warp)") }
        let viewsStatWarp = ["Kannu/components/AgentStatus/NotchAgentStatusView.swift", "Kannu/components/Settings/SettingsView.swift"]
            .contains { (sources[$0] ?? "").contains("WarpAgentStore.databaseURL") }
        if !ungatedWarpLookups.isEmpty || viewsStatWarp {
            problems.append("something looks up Warp's database without the gate")
        }

        let bluetooth = sources["Kannu/managers/BluetoothAudioManager.swift"] ?? ""
        let bluetoothInit = body(after: "    private init() {", in: bluetooth) ?? ""
        let bluetoothStart = body(after: "private func startIfPermitted() {", in: bluetooth) ?? ""
        if ["setupBluetoothObservers", "checkInitialDevices", "batteryReader", "IOBluetooth"].contains(where: bluetoothInit.contains)
            || !bluetoothStart.contains("LaunchPermissionManager.mayTouch(.bluetooth)") {
            problems.append("BluetoothAudioManager touches Bluetooth before the gate")
        }
        if !bluetooth.contains("private lazy var batteryReader = BluetoothLEBatteryReader()") {
            problems.append("BluetoothAudioManager builds its CBCentralManager at init")
        }

        let clipboard = sources["Kannu/managers/ClipboardManager.swift"] ?? ""
        let migration = body(after: "static func migrateLegacyDataIfNeeded(isUpgrade: Bool) {", in: clipboard) ?? ""
        let documentUses = clipboard.components(separatedBy: ".documentDirectory").count - 1
        let migrationUses = migration.components(separatedBy: ".documentDirectory").count - 1
        if documentUses != migrationUses || !migration.contains("guard isUpgrade") {
            problems.append("clipboard history touches ~/Documents outside the upgrade move")
        }
        return problems
    }

    // MARK: - Reading the code

    /// From the `{` that ends `header` to its matching `}`.
    static func body(after header: String, in source: String) -> String? {
        guard let start = source.range(of: header) else { return nil }
        return matchedBraces(from: source.index(before: start.upperBound), in: source)
    }

    /// The function around the first `marker`: from the nearest `func ` above it to its closing brace.
    static func enclosingFunction(of marker: String, in source: String) -> String? {
        guard let markerRange = source.range(of: marker),
              let funcRange = source.range(of: "func ", options: .backwards, range: source.startIndex..<markerRange.lowerBound),
              let open = source[funcRange.upperBound...].firstIndex(of: "{")
        else { return nil }
        return matchedBraces(from: open, in: source).map { String(source[funcRange.lowerBound..<funcRange.upperBound]) + $0 }
    }

    private static func matchedBraces(from open: String.Index, in source: String) -> String? {
        var depth = 0
        var index = open
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func sources() throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: watched.map { path in
            (path, try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))
        })
    }

    private static func appFiles() throws -> [URL: String] {
        let folder = root.appendingPathComponent("Kannu")
        let urls = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return try Dictionary(uniqueKeysWithValues: urls.map { ($0, try String(contentsOf: $0, encoding: .utf8)) })
    }

    private static func files(in files: [URL: String], containing text: String) -> [String] {
        files.filter { $0.value.contains(text) }.map(\.key.lastPathComponent).sorted()
    }
}
