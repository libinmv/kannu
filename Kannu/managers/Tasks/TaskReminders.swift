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
import UserNotifications
import os

/// The reminder a scheduled local task raises: a macOS notification with a **Start** button.
/// Kannu never starts a timer on its own; Start is the user's click.
///
/// - Permission is asked only from `TasksManager.setSchedule`, the first time the user schedules a
///   task — never at launch (`TaskListRulesTests`).
/// - `TaskReminderCenter.install()` runs in `applicationDidFinishLaunching`, before the Terms of
///   Use gate: it sets the delegate and the Start category, which asks nothing and reads no file.
///   A response that arrives before `continueLaunch()` has run waits there (`LaunchGateRulesTests`).
/// - What to add or take back is worked out by the pure `TaskReminderPlan`.
/// - Whatever reads what macOS holds and then changes it runs on one chain (`serially`), in the
///   order asked for, so a removal computed from an earlier snapshot lands before the next read.
enum TaskReminders {
    static let categoryID = "kannu.task-reminder"
    static let startActionID = "kannu.task-reminder.start"

    private static let logger = os.Logger(subsystem: "com.kannu.app", category: "TaskReminders")

    /// What macOS says about Kannu's notifications.
    enum Permission: Equatable {
        case allowed
        case denied
        case notAsked
    }

    static func permission() async -> Permission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        case .notDetermined: return .notAsked
        @unknown default: return .denied
        }
    }

    /// Asks macOS once; afterwards it answers from the user's choice without a prompt.
    static func requestPermission() async -> Permission {
        let current = await permission()
        guard current == .notAsked else { return current }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            return granted ? .allowed : .denied
        } catch {
            logger.error("Notification permission request failed: \(error.localizedDescription, privacy: .public)")
            return .denied
        }
    }

    /// Applies a plan's changes. A request with the same identifier replaces the earlier one.
    static func apply(_ changes: TaskReminderPlan.Changes) {
        guard !changes.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        if !changes.remove.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: changes.remove)
            center.removeDeliveredNotifications(withIdentifiers: changes.remove)
        }
        for reminder in changes.add {
            let content = UNMutableNotificationContent()
            // The task's own title, verbatim; nothing else about it.
            content.title = reminder.title
            content.body = String(localized: "Scheduled task")
            content.sound = .default
            content.categoryIdentifier = categoryID
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.date)
            let request = UNNotificationRequest(
                identifier: TaskReminderPlan.identifier(for: reminder.taskID),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            center.add(request) { error in
                if let error {
                    logger.error("Scheduling a task reminder failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// The identifiers of the task reminders macOS holds: waiting, and already on screen. Asks nothing.
    static func held() async -> (pending: [String], delivered: [String]) {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let prefix = TaskReminderPlan.identifierPrefix
        return (pending.filter { $0.hasPrefix(prefix) }, delivered.filter { $0.hasPrefix(prefix) })
    }

    /// The operations that read what macOS holds and then change it, in the order they were asked
    /// for. Each one is a `held()` and then an `apply`, and a change computed from one snapshot
    /// must land before the next snapshot is read: Tasks turned off and on again within a moment
    /// would otherwise have the removal, computed first, take back the reminders the resend had
    /// just sent, and macOS would hold nothing with Tasks on (`TaskListRulesTests`).
    @MainActor private static var chain: Task<Void, Never>?

    /// Runs `operation` once every operation queued before it has finished.
    @MainActor
    static func serially(_ operation: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task {
            await previous?.value
            await operation()
        }
    }

    /// Takes back every task reminder, waiting or on screen: tasks were turned off. Reads no file
    /// and does not build `TasksManager`.
    @MainActor
    static func withdrawAll() {
        serially {
            let held = await held()
            apply(TaskReminderPlan.reconcile(pending: held.pending, delivered: held.delivered,
                                             wanted: [:], now: Date(), canAdd: false))
        }
    }

    /// macOS's Notifications pane, where the user turns Kannu's notifications back on.
    static func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }
}

/// Answers the reminders: Start times the task, a click on the notification opens Brain at the
/// Task list.
///
/// Installed in `applicationDidFinishLaunching`, before the Terms of Use gate: a click on a
/// reminder while Kannu is not running launches it, and macOS hands the response to whatever
/// delegate is set by the time that method returns — one set in `continueLaunch()` never sees it.
/// Installing only sets the delegate. The response itself waits here until `launchDidContinue()`,
/// which `continueLaunch()` calls last, so nothing acts before the terms are accepted and before
/// what the answer needs (the Settings window, `TasksManager`) may exist.
final class TaskReminderCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TaskReminderCenter()

    /// A click on a reminder, as `didReceive` hands it over.
    private struct Response {
        let taskID: UUID
        let action: String
        /// The notification's own completion: runs once the click has been answered.
        let completion: () -> Void
    }

    /// Responses arriving before the launch continued wait in `waiting`. Both are main-actor
    /// state: `didReceive` hops there before touching them, and the compiler holds the rest to it.
    @MainActor private var launchContinued = false
    @MainActor private var waiting: [Response] = []

    private override init() {
        super.init()
    }

    /// Sets the delegate and the Start category. Asks nothing, reads no file and builds nothing.
    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let start = UNNotificationAction(identifier: TaskReminders.startActionID, title: String(localized: "Start"), options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: TaskReminders.categoryID, actions: [start], intentIdentifiers: [], options: []),
        ])
    }

    /// Kannu is an accessory app, so it counts as frontmost often: show the banner anyway.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let isReminder = TaskReminderPlan.taskID(fromIdentifier: notification.request.identifier) != nil
        completionHandler(isReminder ? [.banner, .list, .sound] : [])
    }

    /// The launch ran (`continueLaunch()`): the responses held until now are answered, in order.
    @MainActor
    func launchDidContinue() {
        launchContinued = true
        let held = waiting
        waiting.removeAll()
        for response in held { answer(response) }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Another app's notification, or one of Kannu's that is not a reminder: nothing to answer.
        guard let taskID = TaskReminderPlan.taskID(fromIdentifier: response.notification.request.identifier) else {
            completionHandler()
            return
        }
        let reminder = Response(taskID: taskID, action: response.actionIdentifier, completion: completionHandler)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if self.launchContinued { self.answer(reminder) } else { self.waiting.append(reminder) }
            }
        }
    }

    /// Start times the task; a click on the banner opens the Task list; a dismissal does nothing.
    /// The completion runs after the answer, not before it: for Start, once the task started, the
    /// Task list opened instead, or the file turned out unreadable.
    @MainActor
    private func answer(_ response: Response) {
        // With tasks turned off since, a reminder does nothing.
        guard Defaults[.enableTasks] else { return response.completion() }
        if response.action == TaskReminders.startActionID {
            // When the task cannot start (timer off, task gone, file unreadable), the click opens
            // the Task list instead of doing nothing.
            TasksManager.shared.startFromReminder(
                response.taskID,
                otherwise: { TasksBrainDestination.taskList.open() },
                completion: response.completion
            )
        } else if response.action == UNNotificationDefaultActionIdentifier {
            TasksBrainDestination.taskList.open()
            response.completion()
        } else {
            response.completion()
        }
    }
}
