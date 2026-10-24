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
import ApplicationServices
import Combine
import CoreBluetooth
import CoreLocation
import Defaults
import MusicKit

/// What the Permissions step shows for one permission.
enum LaunchPermissionStatus: Equatable {
    case notAsked
    /// Its macOS dialog is up, or System Settings is open for it.
    case waiting
    case allowed
    case notAllowed
    /// Not now: its feature stays off until the user allows it.
    case deferred
    /// Allowed in Kannu, but macOS asks once the app it controls is open.
    case askedWhenAppOpens
}

/// Owns Kannu's launch permissions: whether a feature may make the first touch that raises a
/// permission's prompt (`mayTouch`), and the requests the onboarding's Permissions step and
/// Brain › General › Permissions make, one dialog at a time. Features never ask on their own
/// before onboarding is done, and never for a permission the user deferred.
@MainActor
final class LaunchPermissionManager: NSObject, ObservableObject {
    static let shared = LaunchPermissionManager()

    @Published private(set) var statuses: [LaunchPermission: LaunchPermissionStatus] = [:]
    /// The permission whose request is running; every other Allow waits for it.
    @Published private(set) var requestInFlight: LaunchPermission?

    private var bluetoothCentral: CBCentralManager?
    private let locationManager = CLLocationManager()
    private var downloadsReadable: Bool?
    private var warpReadable: Bool?
    /// Silent re-reads of a folder whose answer is known to macOS but not to this run (after a
    /// relaunch), so a denied one shows Not allowed rather than Allowed.
    private var probesInFlight: Set<LaunchPermission> = []
    private var automationStatus: OSStatus?
    private var notesAutomationStatus: OSStatus?
    private var cancellables = Set<AnyCancellable>()

    private override init() {
        super.init()
        locationManager.delegate = self
        AccessibilityPermissionStore.shared.$isAuthorized
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    // MARK: - The gate

    nonisolated static var isOnboardingComplete: Bool {
        OnboardingProgress.isComplete(completedVersion: Defaults[.onboardingCompletedVersion])
    }

    /// Whether a feature may touch `permission` now. Every automatic first touch checks this.
    nonisolated static func mayTouch(_ permission: LaunchPermission) -> Bool {
        LaunchPermissionPolicy.mayTouch(onboardingComplete: isOnboardingComplete, answer: answer(for: permission))
    }

    /// Read without raising a prompt: the system's own status where one can be read, else what the
    /// user pressed.
    nonisolated static func answer(for permission: LaunchPermission) -> PermissionAnswer {
        if systemHasAnswered(permission) || Defaults[.askedLaunchPermissions].contains(permission.rawValue) {
            return .asked
        }
        return Defaults[.deferredLaunchPermissions].contains(permission.rawValue) ? .deferred : .notAsked
    }

    nonisolated private static func systemHasAnswered(_ permission: LaunchPermission) -> Bool {
        switch permission {
        case .accessibility: return AXIsProcessTrusted()
        case .bluetooth: return CBManager.authorization != .notDetermined
        case .location: return CLLocationManager().authorizationStatus != .notDetermined
        case .downloads, .musicAutomation, .notesAutomation, .warp: return false
        }
    }

    // MARK: - Answers

    /// Not now: the feature stays off, and nothing asks for it until the user allows it.
    func postpone(_ permission: LaunchPermission) {
        guard Self.answer(for: permission) == .notAsked else { return }
        Defaults[.deferredLaunchPermissions] = Defaults[.deferredLaunchPermissions] + [permission.rawValue]
        NotificationCenter.default.post(name: .launchPermissionsChanged, object: permission.rawValue)
        refresh()
    }

    /// The request ran: features gated on it may start (no prompt can follow).
    private func markAsked(_ permission: LaunchPermission) {
        var asked = Defaults[.askedLaunchPermissions]
        if !asked.contains(permission.rawValue) { asked.append(permission.rawValue) }
        Defaults[.askedLaunchPermissions] = asked
        Defaults[.deferredLaunchPermissions] = Defaults[.deferredLaunchPermissions].filter { $0 != permission.rawValue }
        NotificationCenter.default.post(name: .launchPermissionsChanged, object: permission.rawValue)
    }

    private func finishRequest(_ permission: LaunchPermission) {
        markAsked(permission)
        if requestInFlight == permission { requestInFlight = nil }
        refresh()
    }

    // MARK: - Requests

    /// Raises `permission`'s macOS dialog, the only one on screen. `musicSource` names the app the
    /// music automation row is for.
    func request(_ permission: LaunchPermission, musicSource: MediaControllerType) {
        guard requestInFlight == nil else { return }
        requestInFlight = permission
        refresh()
        switch permission {
        case .accessibility:
            AccessibilityPermissionStore.shared.requestAuthorizationPrompt()
            // The system dialog only points at System Settings; the grant is the user's switch
            // there. The store polls for it, and `refresh` follows its `isAuthorized`.
            finishRequest(.accessibility)
        case .bluetooth:
            // The first CoreBluetooth manager raises the dialog; its state update is the answer.
            bluetoothCentral = CBCentralManager(delegate: self, queue: nil)
        case .location:
            if locationManager.authorizationStatus == .notDetermined {
                locationManager.requestWhenInUseAuthorization()
            } else {
                finishRequest(.location)
            }
        case .downloads:
            // The first read of ~/Downloads raises the dialog and blocks until it is answered, so
            // it runs off the main thread.
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            DispatchQueue.global(qos: .userInitiated).async {
                let readable = downloads.map { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) != nil } ?? false
                DispatchQueue.main.async {
                    self.downloadsReadable = readable
                    self.finishRequest(.downloads)
                }
            }
        case .musicAutomation:
            let bundleID = Self.automationBundleID(for: musicSource)
            DispatchQueue.global(qos: .userInitiated).async {
                let status = bundleID.map { Self.automationPermission(bundleID: $0, ask: true) } ?? OSStatus(procNotFound)
                DispatchQueue.main.async {
                    self.automationStatus = status
                    guard musicSource == .appleMusic else {
                        self.finishRequest(.musicAutomation)
                        return
                    }
                    // Apple Music's animated artwork reads the music catalog: asked here, next,
                    // rather than on the first track change.
                    Task { @MainActor in
                        if MusicAuthorization.currentStatus == .notDetermined {
                            _ = await MusicAuthorization.request()
                        }
                        self.finishRequest(.musicAutomation)
                    }
                }
            }
        case .notesAutomation:
            // `AEDeterminePermissionToAutomateTarget` answers procNotFound for an app that is not
            // running and asks nothing, so Notes is opened first, hidden and in the background.
            Self.openHidden(bundleID: Self.notesBundleID) {
                DispatchQueue.global(qos: .userInitiated).async {
                    let status = Self.automationPermission(bundleID: Self.notesBundleID, ask: true)
                    DispatchQueue.main.async {
                        self.notesAutomationStatus = status
                        self.finishRequest(.notesAutomation)
                    }
                }
            }
        case .warp:
            let database = WarpAgentStore.databaseURL
            DispatchQueue.global(qos: .userInitiated).async {
                // Opening Warp's database in its container raises "access data from other apps".
                let readable = database.flatMap { try? FileHandle(forReadingFrom: $0) }.map { handle -> Bool in
                    try? handle.close()
                    return true
                } ?? false
                DispatchQueue.main.async {
                    self.warpReadable = readable
                    self.finishRequest(.warp)
                }
            }
        }
    }

    func openSystemSettings(for permission: LaunchPermission) {
        let anchor: String
        switch permission {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .bluetooth: anchor = "Privacy_Bluetooth"
        case .downloads, .warp: anchor = "Privacy_FilesAndFolders"
        case .location: anchor = "Privacy_LocationServices"
        case .musicAutomation, .notesAutomation: anchor = "Privacy_Automation"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Status

    func refresh() {
        probeFolderAccessIfUnknown()
        var next: [LaunchPermission: LaunchPermissionStatus] = [:]
        for permission in LaunchPermission.allCases {
            next[permission] = status(of: permission)
        }
        if next != statuses { statuses = next }
    }

    /// Downloads and Warp have no status API: a read is the only answer. Once asked, macOS has
    /// answered, so reading again raises no dialog; it runs off the main thread, once at a time.
    private func probeFolderAccessIfUnknown() {
        let targets: [(LaunchPermission, URL?, Bool)] = [
            (.downloads, FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first, downloadsReadable == nil),
            (.warp, nil, warpReadable == nil),
        ]
        for (permission, folder, unknown) in targets
        where unknown && requestInFlight != permission && !probesInFlight.contains(permission)
            && Self.answer(for: permission) == .asked {
            probesInFlight.insert(permission)
            DispatchQueue.global(qos: .utility).async {
                let readable: Bool
                if permission == .warp {
                    readable = WarpAgentStore.databaseURL.flatMap { try? FileHandle(forReadingFrom: $0) }.map { handle in
                        try? handle.close()
                        return true
                    } ?? false
                } else {
                    readable = folder.map { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) != nil } ?? false
                }
                DispatchQueue.main.async {
                    self.probesInFlight.remove(permission)
                    if permission == .warp { self.warpReadable = readable } else { self.downloadsReadable = readable }
                    self.refresh()
                }
            }
        }
    }

    private func status(of permission: LaunchPermission) -> LaunchPermissionStatus {
        if requestInFlight == permission { return .waiting }
        let answer = Self.answer(for: permission)
        if answer == .deferred { return .deferred }
        switch permission {
        case .accessibility:
            if AccessibilityPermissionStore.shared.isAuthorized { return .allowed }
            return answer == .asked ? .notAllowed : .notAsked
        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: return .allowed
            case .denied, .restricted: return .notAllowed
            default: return .notAsked
            }
        case .location:
            switch locationManager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse: return .allowed
            case .denied, .restricted: return .notAllowed
            default: return .notAsked
            }
        case .downloads:
            guard answer == .asked else { return .notAsked }
            // Unknown until `probeFolderAccessIfUnknown` reads it, a moment after a relaunch.
            guard let downloadsReadable else { return .waiting }
            return downloadsReadable ? .allowed : .notAllowed
        case .warp:
            guard answer == .asked else { return .notAsked }
            guard let warpReadable else { return .waiting }
            return warpReadable ? .allowed : .notAllowed
        case .musicAutomation:
            guard answer == .asked else { return .notAsked }
            if automationStatus == OSStatus(errAEEventNotPermitted) { return .notAllowed }
            if automationStatus == OSStatus(procNotFound) { return .askedWhenAppOpens }
            return .allowed
        case .notesAutomation:
            guard answer == .asked else { return .notAsked }
            if notesAutomationStatus == OSStatus(errAEEventNotPermitted) { return .notAllowed }
            if notesAutomationStatus == OSStatus(procNotFound) { return .askedWhenAppOpens }
            return .allowed
        }
    }

    // MARK: - Rows

    /// The rows for this setup, from Brain's settings as they stand (after onboarding's profile
    /// choice has applied its own).
    static func rows(
        musicSource: MediaControllerType,
        appleNotesSync: Bool = Defaults[.enableNotes] && Defaults[.enableAppleNotesSync]
    ) -> [LaunchPermission] {
        LaunchPermissionPolicy.rows(for: LaunchPermissionPolicy.Features(
            systemHUD: Defaults[.enableSystemHUD] || Defaults[.enableCustomOSD]
                || Defaults[.enableVerticalHUD] || Defaults[.enableCircularHUD],
            downloads: Defaults[.enableDownloadListener],
            lockScreenWeather: Defaults[.enableLockScreenWeatherWidget],
            controlsMusicApp: automationBundleID(for: musicSource) != nil,
            warpInstalled: isWarpInstalled,
            appleNotesSync: appleNotesSync
        ))
    }

    /// Asked of Launch Services, so nothing touches Warp's container to find out: statting its
    /// database there raises "access data from other apps".
    nonisolated static var isWarpInstalled: Bool {
        WarpAgentStore.bundleIdentifiers.contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }

    // MARK: - Automation

    nonisolated static let notesBundleID = "com.apple.Notes"

    /// Opens the app without activating it or showing a window, then runs `completion` on the main
    /// queue (also when it cannot be opened, so the request still finishes).
    private static func openHidden(bundleID: String, completion: @escaping @MainActor () -> Void) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            completion()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { completion() }
        }
    }

    nonisolated static func automationBundleID(for source: MediaControllerType) -> String? {
        switch source {
        case .spotify: return "com.spotify.client"
        case .appleMusic: return "com.apple.Music"
        default: return nil
        }
    }

    /// `AEDeterminePermissionToAutomateTarget`: with `ask`, raises the Automation dialog when the
    /// app is running, and blocks until it is answered. `procNotFound` when the app is not running.
    nonisolated private static func automationPermission(bundleID: String, ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return withExtendedLifetime(target) {
            guard let address = target.aeDesc else { return OSStatus(procNotFound) }
            return AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, ask)
        }
    }
}

extension LaunchPermissionManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard CBManager.authorization != .notDetermined else { return }
        Task { @MainActor in
            self.bluetoothCentral = nil
            self.finishRequest(.bluetooth)
        }
    }
}

extension LaunchPermissionManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let determined = manager.authorizationStatus != .notDetermined
        Task { @MainActor in
            guard determined, self.requestInFlight == .location else {
                self.refresh()
                return
            }
            self.finishRequest(.location)
        }
    }
}
