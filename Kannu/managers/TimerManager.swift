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
import Combine
import SwiftUI
import AVFoundation
import AppKit
import Defaults

class TimerManager: ObservableObject {
    // MARK: - Properties
    static let shared = TimerManager()
    
    @Published var isTimerActive: Bool = false
    @Published var timerName: String = "Timer"
    @Published var totalDuration: TimeInterval = 0
    @Published var remainingTime: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var isPaused: Bool = false
    @Published var isFinished: Bool = false
    @Published var isOvertime: Bool = false // Timer has gone past 0 and is counting negative
    @Published var lastUpdated: Date = .distantPast
    @Published var activePresetId: UUID?
    @Published private(set) var activeSource: TimerSource = .none
    /// What a renamed session goes back to when its name is cleared: the preset's name, or
    /// "Custom Timer" (`TimerSessionName`).
    private(set) var sessionDefaultName: String = "Timer"
    /// New for every session, so a rename begun in one session never lands on the next.
    private(set) var sessionID = UUID()

    // Timer progress (0.0 to 1.0, or >1.0 for overtime)
    var progress: Double {
        guard totalDuration > 0 else { return 0.0 }
        if isOvertime {
            // For overtime, progress goes beyond 1.0
            return 1.0 + min(1.0, abs(remainingTime) / totalDuration)
        } else {
            return min(1.0, max(0.0, elapsedTime / totalDuration))
        }
    }
    
    // Color based on progress: green -> yellow -> red -> flashing red for overtime
    var timerColor: Color {
        if isOvertime {
            // Flashing red for overtime
            return .red
        }
        
        let p = progress
        if p < 0.6 {
            // Green phase (0-60%)
            return .green
        } else if p < 0.9 {
            // Yellow phase (60-90%)
            let yellowProgress = (p - 0.6) / 0.3
            return Color(
                red: 1.0 - (1.0 - yellowProgress) * 0.5, // Gradually more red
                green: 1.0,
                blue: 0.0
            )
        } else {
            // Red phase (90-100%)
            return .red
        }
    }
    
    // Computed properties for UI
    var isRunning: Bool {
        return isTimerActive && !isPaused
    }
    
    var currentColor: Color {
        return timerColor
    }
    
    var formattedTimeRemaining: String {
        return formattedRemainingTime()
    }
    
    var statusText: String {
        if isOvertime {
            return "Overtime"
        } else if isPaused {
            return "Paused"
        } else if isTimerActive {
            return "Running"
        } else {
            return "Ready"
        }
    }
    
    // NSColor version for compatibility
    var timerNSColor: NSColor {
        if isOvertime {
            return NSColor.systemRed
        }
        
        let p = progress
        if p < 0.6 {
            return NSColor.systemGreen
        } else if p < 0.9 {
            let yellowProgress = (p - 0.6) / 0.3
            return NSColor(
                red: 1.0 - (1.0 - yellowProgress) * 0.5,
                green: 1.0,
                blue: 0.0,
                alpha: 1.0
            )
        } else {
            return NSColor.systemRed
        }
    }
    
    private var timerInstance: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var soundPlayer: AVAudioPlayer?
    /// The delayed close armed by a stop or a finished Clock timer (`scheduleSmoothClose`), kept so
    /// a session started inside its 3 s can cancel it, and the session it was armed for, so a
    /// repeated completion report does not re-arm it.
    private var smoothCloseWork: DispatchWorkItem?
    private var smoothCloseSession: UUID?
    // MARK: - Initialization
    private init() {
        // Simple initialization
    }

    deinit {
        timerInstance?.invalidate()
        smoothCloseWork?.cancel()
        soundPlayer?.stop()
        cancellables.removeAll()
    }
    
    // MARK: - Timer Methods
    /// `name` is what the session shows; `fallbackName`, when given, is the default a cleared name
    /// returns to (the user may have typed `name` over it).
    func startTimer(duration: TimeInterval, name: String = "Timer", preset: TimerPreset? = nil, fallbackName: String? = nil) {
        if activeSource == .external {
            endExternalTimer(triggerSmoothClose: false)
        }

        // Stop the previous session's countdown, its finished alarm (which loops until stopped) and
        // the smooth close its stop armed, which would otherwise end this session 3 s in.
        timerInstance?.invalidate()
        timerInstance = nil
        soundPlayer?.stop()
        cancelSmoothClose()

        // Start new timer
        withAnimation(.smooth) {
            isTimerActive = true
        }
        activeSource = .manual
        isFinished = false
        isOvertime = false
        timerName = name
        sessionDefaultName = fallbackName ?? name
        sessionID = UUID()
        totalDuration = duration
        remainingTime = duration
        elapsedTime = 0
        isPaused = false
        lastUpdated = Date()

        activePresetId = preset?.id

        scheduleTicks()
    }

    /// The 1 s countdown. Each tick queues its work on the main actor, so a stop or a new session
    /// can land between the tick firing and the job running; the job belongs to the session that
    /// scheduled it and leaves any other alone (a stale job used to read the reset's
    /// `remainingTime == 0` as a finish and ring the alarm with no timer showing).
    private func scheduleTicks() {
        let session = sessionID
        timerInstance = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            Task { @MainActor in
                guard self.sessionID == session, !self.isPaused else { return }
                if self.remainingTime > 0 {
                    // Normal countdown
                    self.remainingTime -= 1
                    self.elapsedTime = self.totalDuration - self.remainingTime
                    self.lastUpdated = Date()
                } else if self.remainingTime == 0 {
                    // Timer just finished - play sound and start overtime
                    self.isFinished = true
                    self.isOvertime = true
                    self.playTimerSound()
                    self.remainingTime = -1
                    self.lastUpdated = Date()
                } else {
                    // Overtime - count negative
                    self.remainingTime -= 1
                    self.lastUpdated = Date()
                }
            }
        }
    }
    
    func startDemoTimer(duration: TimeInterval) {
        startTimer(duration: duration, name: "Demo Timer")
    }
    
    func stopTimer() {
        if activeSource == .external {
            endExternalTimer(triggerSmoothClose: true)
            return
        }

        timerInstance?.invalidate()
        timerInstance = nil
        soundPlayer?.stop()

        // Smooth close animation for live activity, armed after the reset so it belongs to the
        // idle session the reset begins (the reset gives the session a new id).
        let wasActive = isTimerActive
        resetTimer()
        if wasActive {
            scheduleSmoothClose()
        }
    }
    
    func forceStopTimer() {
        if activeSource == .external {
            endExternalTimer(triggerSmoothClose: false)
            return
        }

        // Immediate stop for user action (stop button)
        timerInstance?.invalidate()
        timerInstance = nil
        soundPlayer?.stop()
        withAnimation(.smooth) {
            isTimerActive = false
        }
        resetTimer()
    }
    
    func pauseTimer() {
        guard activeSource == .manual else { return }
        guard isTimerActive && !isPaused else { return }
        isPaused = true
        timerInstance?.invalidate()
        timerInstance = nil
    }
    
    func resumeTimer() {
        guard activeSource == .manual else { return }
        guard isTimerActive && isPaused else { return }
        isPaused = false
        lastUpdated = Date()

        scheduleTicks()
    }

    func adoptExternalTimer(name: String, totalDuration: TimeInterval, remaining: TimeInterval, isPaused: Bool) {
        guard activeSource != .manual else { return }

        timerInstance?.invalidate()
        timerInstance = nil
        soundPlayer?.stop()
        cancelSmoothClose()

        activeSource = .external
        sessionID = UUID()

        let clampedTotal = totalDuration > 0 ? totalDuration : max(totalDuration, remaining)

        withAnimation(.smooth) {
            isTimerActive = true
        }

        timerName = name.isEmpty ? "Clock Timer" : name
        self.totalDuration = clampedTotal
        remainingTime = remaining
        elapsedTime = max(0, clampedTotal - remaining)
        self.isPaused = isPaused
        isFinished = false
        isOvertime = remaining < 0
        activePresetId = nil
        lastUpdated = Date()
    }

    func updateExternalTimer(remaining: TimeInterval, totalDuration: TimeInterval?, isPaused paused: Bool, name: String? = nil) {
        guard activeSource == .external else { return }

        if let name, !name.isEmpty, name != timerName {
            timerName = name
        }

        if let totalDuration, totalDuration > 0 {
            self.totalDuration = max(totalDuration, self.totalDuration)
        } else if self.totalDuration <= 0 {
            self.totalDuration = max(self.totalDuration, remaining)
        }

        // A Clock timer restarted while its finished predecessor's close is still pending reaches
        // this update, not `adoptExternalTimer`: the close would end the running timer at 3 s.
        if remaining > 0 {
            cancelSmoothClose()
        }

        remainingTime = remaining
        elapsedTime = max(0, self.totalDuration - remaining)
        isOvertime = remaining < 0
        isPaused = paused
        isFinished = remaining <= 0 && !isOvertime
        lastUpdated = Date()
    }

    func completeExternalTimer() {
        guard activeSource == .external else { return }

        remainingTime = 0
        elapsedTime = totalDuration
        isOvertime = false
        isFinished = true
        lastUpdated = Date()
        scheduleSmoothClose()
    }

    func endExternalTimer(triggerSmoothClose: Bool) {
        guard activeSource == .external else { return }

        // The reset already closes with the `.smooth` animation; the smooth close is armed after it
        // for the same reason as in `stopTimer`.
        let closesSmoothly = triggerSmoothClose && isTimerActive
        resetTimer()
        if closesSmoothly {
            scheduleSmoothClose()
        }
    }
    
    private func resetTimer() {
        withAnimation(.smooth) {
            isTimerActive = false
        }
        timerName = "Timer"
        sessionDefaultName = "Timer"
        sessionID = UUID()
        totalDuration = 0
        remainingTime = 0
        elapsedTime = 0
        isPaused = false
        isFinished = false
        isOvertime = false
        activePresetId = nil
        activeSource = .none
    }

    /// Renames the running session. Only a timer started in Kannu: a Clock-app timer's name is the
    /// Clock app's (`SystemTimerBridge`). A cleared name goes back to the session's default.
    /// `session` is the `sessionID` the rename began in; a later session is left alone.
    func renameSession(to text: String, session: UUID) {
        guard activeSource == .manual, isTimerActive,
              let name = TimerSessionName.renamed(
                text,
                begunIn: session,
                current: sessionID,
                currentName: timerName,
                fallback: sessionDefaultName
              ) else { return }
        timerName = name
    }

    // MARK: - Derived State
    var activePreset: TimerPreset? {
        guard let presetId = activePresetId else { return nil }
        return Defaults[.timerPresets].first { $0.id == presetId }
    }

    var isExternalTimerActive: Bool {
        activeSource == .external && isTimerActive
    }

    var hasManualTimerRunning: Bool {
        activeSource == .manual && isTimerActive
    }

    var allowsManualInteraction: Bool {
        activeSource != .external
    }

    enum TimerSource: String {
        case none
        case manual
        case external
    }

    /// Waits 3 seconds, then smoothly closes the live activity. Armed for one session: a session
    /// started inside those 3 s cancels it (`startTimer`, `adoptExternalTimer`), and the block
    /// re-checks the session before touching `isTimerActive`, because every start rotates
    /// `sessionID`. A plain `asyncAfter` block used to end whichever session it found running.
    /// A close already pending for the session is left as armed: a finished Clock timer is reported
    /// again every second while it rings, and re-arming on each report would hold the live activity
    /// open until the Clock timer was dismissed.
    private func scheduleSmoothClose() {
        if smoothCloseWork != nil, smoothCloseSession == sessionID { return }
        cancelSmoothClose()
        let session = sessionID
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Only the armed item runs (a replaced one was cancelled), so the slot is this item's.
            self.smoothCloseWork = nil
            self.smoothCloseSession = nil
            guard self.sessionID == session else { return }
            withAnimation(.easeInOut(duration: 1.0)) {
                self.isTimerActive = false
            }
            if self.activeSource == .external {
                // A finished Clock timer: the close also ends its session, otherwise `activeSource`
                // stays `.external` and Start and pause stay disabled until the next Clock timer. The
                // close above already animated `isTimerActive`, so the reset's own close is a no-op.
                self.resetTimer()
            }
        }
        smoothCloseWork = work
        smoothCloseSession = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    private func cancelSmoothClose() {
        smoothCloseWork?.cancel()
        smoothCloseWork = nil
        smoothCloseSession = nil
    }
    
    private func playTimerSound() {
        var soundURL: URL?
        
        // Check for custom timer sound first
        let customTimerSoundPath = UserDefaults.standard.string(forKey: "customTimerSoundPath")
        if let customPath = customTimerSoundPath, !customPath.isEmpty {
            // Use custom sound file
            soundURL = URL(fileURLWithPath: customPath)
            
            // Verify the file exists
            if !FileManager.default.fileExists(atPath: customPath) {
                soundURL = nil
            }
        }
        
        // Fall back to default sound if no custom sound or custom sound doesn't exist
        if soundURL == nil {
            soundURL = Bundle.main.url(forResource: "timer", withExtension: "mp3")
                ?? Bundle.main.url(forResource: "dynamic", withExtension: "m4a")
        }
        
        guard let finalSoundURL = soundURL else {
            // Final fallback to system sound
            NSSound.beep()
            return
        }
        
        do {
            soundPlayer = try AVAudioPlayer(contentsOf: finalSoundURL)
            soundPlayer?.numberOfLoops = -1 // Loop indefinitely
            soundPlayer?.play()
        } catch {
            // Fallback to system sound if there's an error playing the custom sound
            NSSound.beep()
        }
    }
    
    // MARK: - Formatted Time Strings
    func formattedRemainingTime() -> String {
        if isOvertime && remainingTime < 0 {
            return "-" + timeString(from: abs(remainingTime))
        } else {
            return timeString(from: remainingTime)
        }
    }
    
    func formattedElapsedTime() -> String {
        return timeString(from: elapsedTime)
    }
    
    func formattedTotalDuration() -> String {
        return timeString(from: totalDuration)
    }
    
    private func timeString(from seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            return String(format: "%d:%02d", minutes, remainingSeconds)
        }
    }
}
