/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
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
import AppKit
import os

class SystemOSDManager {
    private init() {}

    // Tracks the PID we most recently suspended. macOS jetsam-exits OSDUIHelper
    // when idle and launchd respawns it on the next media-key press as a fresh
    // process, so we need to re-SIGSTOP every new incarnation.
    private struct SuppressionState {
        var task: Task<Void, Never>?
        var lastSuspendedPID: Int32 = -1
        // True while suppressing the native OSD (between disable/enableSystemHUD).
        var active = false
        // True while the Mac is asleep — watcher pauses, not cancelled.
        var systemSleeping = false
    }
    private static let suppressionState = OSAllocatedUnfairLock(initialState: SuppressionState())

    /// Call once at startup to register sleep/wake observers.
    /// Safe to call multiple times — observers are registered only once.
    private static let sleepWakeSetupOnce: Void = {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            handleSystemSleep()
        }
        nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            handleSystemWake()
        }
    }()

    // MARK: - Sleep / Wake

    private static func handleSystemSleep() {
        // Mark as sleeping so the watcher loop exits its current poll immediately.
        suppressionState.withLock { $0.systemSleeping = true }
        // Stop the watcher task — no more pgrep spawns while sleeping.
        stopSuppressionWatcher()
    }

    private static func handleSystemWake() {
        suppressionState.withLock { $0.systemSleeping = false }
        // If suppression was still active when we went to sleep, restart the watcher.
        let active = suppressionState.withLock { $0.active }
        if active {
            // Reset the last-suspended PID so the watcher immediately re-suspends
            // the fresh OSDUIHelper that launchd may have spawned during wake.
            suppressionState.withLock { $0.lastSuspendedPID = -1 }
            startSuppressionWatcher()
        }
    }

    // MARK: - Public API

    /// Re-enables the system HUD by restarting OSDUIHelper
    public static func enableSystemHUD() {
        suppressionState.withLock { $0.active = false }
        stopSuppressionWatcher()
        Task.detached(priority: .background) {
            await enableSystemHUDAsync()
        }
    }
    
    private static func enableSystemHUDAsync() async {
        do {
            // First, stop any existing OSDUIHelper process
            let stopTask = Process()
            stopTask.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            stopTask.arguments = ["-9", "OSDUIHelper"]
            stopTask.standardError = Pipe() // silence "no such process" stderr
            try stopTask.run()
            stopTask.waitUntilExit()
            
            // Small delay to ensure process is fully stopped
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms
            
            // Then kickstart it again to ensure it's running properly
            let kickstart = Process()
            kickstart.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            kickstart.arguments = ["kickstart", "gui/\(getuid())/com.apple.OSDUIHelper"]
            try kickstart.run()
            kickstart.waitUntilExit()
            
            // Additional delay to ensure service is fully started
            try await Task.sleep(nanoseconds: 300_000_000) // 300ms
            
            await MainActor.run {
                print("✅ System HUD re-enabled")
            }
        } catch {
            await MainActor.run {
                NSLog("❌ Error while trying to re-enable OSDUIHelper: \(error)")
            }
            
            // Fallback: Try to restart the service using launchctl load
            do {
                let fallbackTask = Process()
                fallbackTask.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                fallbackTask.arguments = ["load", "-w", "/System/Library/LaunchAgents/com.apple.OSDUIHelper.plist"]
                try fallbackTask.run()
                fallbackTask.waitUntilExit()
                
                await MainActor.run {
                    print("✅ System HUD re-enabled via fallback method")
                }
            } catch {
                await MainActor.run {
                    NSLog("❌ Fallback method also failed: \(error)")
                }
            }
        }
    }

    /// Disables the system HUD by stopping OSDUIHelper, and starts a
    /// background watcher that re-suspends any future incarnation launchd
    /// spawns (macOS auto-exits OSDUIHelper on idle).
    public static func disableSystemHUD() {
        // Ensure sleep/wake observers are registered.
        _ = sleepWakeSetupOnce
        suppressionState.withLock { $0.active = true }
        Task.detached(priority: .background) {
            await disableSystemHUDAsync()
        }
        startSuppressionWatcher()
    }

    /// Immediately SIGSTOPs OSDUIHelper, bypassing the 150ms watcher poll. The
    /// CoreAudio volume write wakes/respawns the helper to draw the native OSD
    /// (brightness's private APIs never do), and the watcher can lose that race.
    /// No-op unless suppression is active.
    public static func suppressNativeOSDNow() {
        let active = suppressionState.withLock { $0.active }
        guard active else { return }
        Task.detached(priority: .userInitiated) {
            suspendOSDUIHelper()
            if let pid = osduiHelperPID() {
                suppressionState.withLock { $0.lastSuspendedPID = pid }
            }
        }
    }
    
    private static func disableSystemHUDAsync() async {
        do {
            let kickstart = Process()
            kickstart.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            // When macOS boots, OSDUIHelper does not start until a volume button is pressed. We can workaround this by kickstarting it.
            kickstart.arguments = ["kickstart", "gui/\(getuid())/com.apple.OSDUIHelper"]
            try kickstart.run()
            kickstart.waitUntilExit()

            // launchctl kickstart returns once the request is queued, not after
            // OSDUIHelper has actually forked. At cold boot the helper can take
            // a while to appear — a fixed sleep races and the SIGSTOP misses,
            // letting the native OSD render on the first volume/brightness key.
            // Poll for the PID up to ~5s, then suspend, and retry if launchd
            // respawned a fresh copy between kickstart and SIGSTOP.
            var attempts = 0
            while attempts < 3 {
                let appeared = await waitForOSDUIHelper(timeoutMillis: 5000)
                if !appeared {
                    await MainActor.run {
                        NSLog("⚠️ OSDUIHelper did not appear within timeout; retrying SIGSTOP anyway")
                    }
                }

                suspendOSDUIHelper()

                // Settle, then confirm a process is actually present (and thus
                // suspended). If none is running, launchd hasn't spawned it yet
                // or the prior STOP raced — loop and try again.
                try await Task.sleep(nanoseconds: 250_000_000) // 250ms
                if let pid = osduiHelperPID() {
                    suppressionState.withLock { $0.lastSuspendedPID = pid }
                    break
                }
                attempts += 1
            }

            await MainActor.run {
                print("✅ System HUD disabled")
            }
        } catch {
            await MainActor.run {
                NSLog("❌ Error while trying to hide OSDUIHelper: \(error)")
            }
        }
    }

    /// Polls for an OSDUIHelper process, returning true as soon as one appears
    /// or false if `timeoutMillis` elapses with no match.
    private static func waitForOSDUIHelper(timeoutMillis: Int) async -> Bool {
        let pollIntervalNanos: UInt64 = 200_000_000 // 200ms
        let maxAttempts = max(1, timeoutMillis / 200)
        for _ in 0..<maxAttempts {
            if isOSDUIHelperRunning() {
                return true
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanos)
        }
        return isOSDUIHelperRunning()
    }

    /// Background loop that catches OSDUIHelper respawns. macOS exits the
    /// helper after a short idle period (JETSAM_REASON_MEMORY_IDLE_EXIT) and
    /// launchd spins up a brand-new process on the next volume/brightness
    /// keypress — that fresh PID renders the native OSD before any one-shot
    /// SIGSTOP can hit it. Polling every 150ms is cheap (a single pgrep per
    /// tick when nothing changed) and shrinks the visible-OSD window enough
    /// to feel instant.
    ///
    /// The loop exits immediately when the Mac sleeps (systemSleeping == true)
    /// and is restarted by handleSystemWake() when the machine wakes up again.
    /// This prevents the ~192,000 pgrep subprocess spawns that would otherwise
    /// accumulate over an 8-hour sleep and exhaust the process table / fd limits.
    private static func startSuppressionWatcher() {
        let newTask = Task.detached(priority: .background) {
            while !Task.isCancelled {
                // Pause the watcher entirely while the system is asleep.
                // handleSystemWake() will cancel this task and spawn a fresh one.
                let sleeping = suppressionState.withLock { $0.systemSleeping }
                if sleeping {
                    // Sleep in larger chunks so we respond to cancellation promptly.
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                    continue
                }

                let currentPID = osduiHelperPID()
                let lastPID = suppressionState.withLock { $0.lastSuspendedPID }

                if let pid = currentPID, pid != lastPID {
                    suspendOSDUIHelper()
                    suppressionState.withLock { $0.lastSuspendedPID = pid }
                }
                try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
            }
        }

        let previous = suppressionState.withLock { state -> Task<Void, Never>? in
            let prior = state.task
            state.task = newTask
            return prior
        }
        previous?.cancel()
    }

    private static func stopSuppressionWatcher() {
        let previous = suppressionState.withLock { state -> Task<Void, Never>? in
            let prior = state.task
            state.task = nil
            state.lastSuspendedPID = -1
            return prior
        }
        previous?.cancel()
    }

    /// Returns the newest OSDUIHelper PID, or nil if none.
    private static func osduiHelperPID() -> Int32? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-n", "OSDUIHelper"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe() // silence "No matching processes..." stderr
        do {
            try task.run()
            task.waitUntilExit()
            // pgrep exits 1 when no process found — check status to avoid
            // parsing an empty string as a valid PID.
            guard task.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let trimmed = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Int32(trimmed)
        } catch {
            return nil
        }
    }

    /// Sends SIGSTOP to all OSDUIHelper processes. Idempotent.
    private static func suspendOSDUIHelper() {
        let stop = Process()
        stop.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        stop.arguments = ["-STOP", "OSDUIHelper"]
        stop.standardError = Pipe() // silence "no such process" stderr
        do {
            try stop.run()
            stop.waitUntilExit()
        } catch {
            NSLog("Suppression watcher: failed to SIGSTOP OSDUIHelper: \(error)")
        }
    }

    /// Check if OSDUIHelper is currently running
    public static func isOSDUIHelperRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["OSDUIHelper"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe() // silence "No matching processes..." stderr
        
        do {
            try task.run()
            task.waitUntilExit()
            
            guard task.terminationStatus == 0 else { return false }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !output.isEmpty
        } catch {
            return false
        }
    }
    
    /// Async version of status checking to avoid main thread blocking
    public static func isOSDUIHelperRunningAsync() async -> Bool {
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .background) {
                let result = isOSDUIHelperRunning()
                continuation.resume(returning: result)
            }
        }
    }
}