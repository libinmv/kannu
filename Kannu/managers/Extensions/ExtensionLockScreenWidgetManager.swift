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

import Foundation
import Defaults
import AtollExtensionKit

@MainActor
final class ExtensionLockScreenWidgetManager: ObservableObject {
    static let shared = ExtensionLockScreenWidgetManager()

    @Published private(set) var activeWidgets: [ExtensionLockScreenWidgetPayload] = []

    private let authorizationManager = ExtensionAuthorizationManager.shared
    private let maxCapacityKey = Defaults.Keys.extensionLockScreenWidgetCapacity
    private var presentationController: ExtensionLockScreenWidgetPresentationController!
    private let eventBridge = ExtensionEventBridge.shared
    private var widgetObserver: NSObjectProtocol?
    private var suppressBroadcast = false
    private let currentProcessID = ProcessInfo.processInfo.processIdentifier

    private init() {
        activeWidgets = eventBridge.loadPersistedLockScreenWidgets()
        sortWidgets()
        presentationController = ExtensionLockScreenWidgetPresentationController(manager: self)
        presentationController.activate()
        widgetObserver = eventBridge.observeLockScreenWidgetSnapshots { [weak self] payloads, sourcePID in
            self?.applySnapshot(payloads, sourcePID: sourcePID)
        }
    }

    deinit {
        if let token = widgetObserver {
            eventBridge.removeObserver(token)
        }
    }

    func present(descriptor: AtollLockScreenWidgetDescriptor, bundleIdentifier: String) throws {
        guard authorizationManager.canProcessLockScreenRequest(from: bundleIdentifier) else {
            logDiagnostics("Rejected lock screen widget \(descriptor.id) from \(bundleIdentifier): scope disabled or bundle unauthorized")
            throw ExtensionValidationError.unauthorized
        }
        guard descriptor.isValid else {
            logDiagnostics("Rejected lock screen widget \(descriptor.id) from \(bundleIdentifier): descriptor validation failed")
            throw ExtensionValidationError.invalidDescriptor("Structure validation failed")
        }

        if let index = activeWidgets.firstIndex(where: { $0.descriptor.id == descriptor.id && $0.bundleIdentifier == bundleIdentifier }) {
            let payload = ExtensionLockScreenWidgetPayload(
                bundleIdentifier: bundleIdentifier,
                descriptor: descriptor,
                receivedAt: activeWidgets[index].receivedAt
            )
            activeWidgets[index] = payload
            sortWidgets()
            authorizationManager.recordActivity(for: bundleIdentifier, scope: .lockScreenWidgets)
            Logger.log("Replaced extension widget \(descriptor.id) for \(bundleIdentifier)", category: .extensions)
            broadcastSnapshot()
            return
        }

        guard activeWidgets.count < Defaults[maxCapacityKey] else {
            logDiagnostics("Rejected lock screen widget \(descriptor.id) from \(bundleIdentifier): capacity limit \(Defaults[maxCapacityKey]) reached")
            throw ExtensionValidationError.exceedsCapacity
        }

        let payload = ExtensionLockScreenWidgetPayload(
            bundleIdentifier: bundleIdentifier,
            descriptor: descriptor,
            receivedAt: .now
        )
        activeWidgets.append(payload)
        sortWidgets()
        authorizationManager.recordActivity(for: bundleIdentifier, scope: .lockScreenWidgets)
        logDiagnostics("Queued lock screen widget \(descriptor.id) for \(bundleIdentifier); total widgets: \(activeWidgets.count)")
        broadcastSnapshot()
    }

    func update(descriptor: AtollLockScreenWidgetDescriptor, bundleIdentifier: String) throws {
        guard descriptor.isValid else {
            logDiagnostics("Rejected lock screen widget update \(descriptor.id) from \(bundleIdentifier): descriptor validation failed")
            throw ExtensionValidationError.invalidDescriptor("Structure validation failed")
        }
        guard let index = activeWidgets.firstIndex(where: { $0.descriptor.id == descriptor.id && $0.bundleIdentifier == bundleIdentifier }) else {
            throw ExtensionValidationError.invalidDescriptor("Missing existing widget")
        }

        let payload = ExtensionLockScreenWidgetPayload(
            bundleIdentifier: bundleIdentifier,
            descriptor: descriptor,
            receivedAt: activeWidgets[index].receivedAt
        )
        activeWidgets[index] = payload
        sortWidgets()
        authorizationManager.recordActivity(for: bundleIdentifier, scope: .lockScreenWidgets)
        logDiagnostics("Updated lock screen widget \(descriptor.id) for \(bundleIdentifier)")
        broadcastSnapshot()
    }

    func dismiss(widgetID: String, bundleIdentifier: String) {
        let previousCount = activeWidgets.count
        activeWidgets.removeAll { $0.descriptor.id == widgetID && $0.bundleIdentifier == bundleIdentifier }
        if previousCount != activeWidgets.count {
            Logger.log("Dismissed extension widget \(widgetID) from \(bundleIdentifier)", category: .extensions)
            ExtensionXPCServiceHost.shared.notifyWidgetDismiss(bundleIdentifier: bundleIdentifier, widgetID: widgetID)
            ExtensionRPCServer.shared.notifyWidgetDismiss(bundleIdentifier: bundleIdentifier, widgetID: widgetID)
            logDiagnostics("Removed lock screen widget \(widgetID) for \(bundleIdentifier); remaining: \(activeWidgets.count)")
            broadcastSnapshot()
        }
    }

    func dismissAll(for bundleIdentifier: String) {
        let ids = activeWidgets
            .filter { $0.bundleIdentifier == bundleIdentifier }
            .map { $0.descriptor.id }
        activeWidgets.removeAll { $0.bundleIdentifier == bundleIdentifier }
        ids.forEach {
            ExtensionXPCServiceHost.shared.notifyWidgetDismiss(bundleIdentifier: bundleIdentifier, widgetID: $0)
            ExtensionRPCServer.shared.notifyWidgetDismiss(bundleIdentifier: bundleIdentifier, widgetID: $0)
        }
        if !ids.isEmpty {
            logDiagnostics("Removed all lock screen widgets for \(bundleIdentifier); ids: \(ids.joined(separator: ", "))")
            broadcastSnapshot()
        }
    }

    private func sortWidgets() {
        activeWidgets.sort { lhs, rhs in
            if lhs.priority == rhs.priority {
                return lhs.receivedAt < rhs.receivedAt
            }
            return lhs.priority > rhs.priority
        }
    }

    private func broadcastSnapshot() {
        guard !suppressBroadcast else { return }
        eventBridge.broadcastLockScreenWidgetSnapshot(activeWidgets)
        logDiagnostics("Broadcasted lock screen widget snapshot (count: \(activeWidgets.count))")
    }

    private func applySnapshot(_ payloads: [ExtensionLockScreenWidgetPayload], sourcePID: Int32) {
        guard sourcePID != currentProcessID else { return }
        suppressBroadcast = true
        activeWidgets = payloads.sorted { lhs, rhs in
            if lhs.priority == rhs.priority {
                return lhs.receivedAt < rhs.receivedAt
            }
            return lhs.priority > rhs.priority
        }
        suppressBroadcast = false
        logDiagnostics("Applied external lock screen widget snapshot from PID \(sourcePID) (count: \(payloads.count))")
    }

    private func logDiagnostics(_ message: String) {
        guard Defaults[.extensionDiagnosticsLoggingEnabled] else { return }
        Logger.log(message, category: .extensions)
    }
}
