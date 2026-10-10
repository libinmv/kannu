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
/// - `TaskReminderCenter.install()` runs in `continueLaunch()`, after the Terms of Use: it sets the
///   delegate and the Start category, which asks nothing and reads no file.
/// - What to add or take back is worked out by the pure `TaskReminderPlan`.
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

    /// Takes back every task reminder, waiting or on screen: tasks were turned off. Reads no file
    /// and does not build `TasksManager`.
    static func withdrawAll() {
        Task {
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
/// Task list. Installed in `continueLaunch()`, after the Terms of Use.
final class TaskReminderCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TaskReminderCenter()

    private override init() {
        super.init()
    }

    /// Sets the delegate and the Start category. Asks nothing and reads no file.
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

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let taskID = TaskReminderPlan.taskID(fromIdentifier: response.notification.request.identifier)
        let action = response.actionIdentifier
        completionHandler()
        guard let taskID else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // With tasks turned off since, a reminder does nothing.
                guard Defaults[.enableTasks] else { return }
                if action == TaskReminders.startActionID {
                    // When the task cannot start (timer off, task gone, file unreadable), the click
                    // opens the Task list instead of doing nothing.
                    TasksManager.shared.startFromReminder(taskID) { TasksBrainDestination.taskList.open() }
                } else if action == UNNotificationDefaultActionIdentifier {
                    TasksBrainDestination.taskList.open()
                }
            }
        }
    }
}
