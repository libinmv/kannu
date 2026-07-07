/*
 * Kannu (കണ്ണ്)
 * Copyright (C) 2024-2026 Kannu Contributors
 *
 * Schedules brief idle animation playback at :15 and :45 each hour.
 */

import Combine
import Defaults
import Foundation

@MainActor
final class IdleAnimationScheduleManager: ObservableObject {
    static let shared = IdleAnimationScheduleManager()

    static let scheduledMinutes: Set<Int> = [15, 45]

    @Published private(set) var isActive = false

    private var clockTimer: Timer?
    private var stopTask: Task<Void, Never>?
    private var playedMinutesThisHour: Set<Int> = []
    private var trackedHour: Int?

    private init() {
        startClock()
    }

    func startClock() {
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateSchedule()
            }
        }
        evaluateSchedule()
    }

    func endPlayback() {
        stopTask?.cancel()
        stopTask = nil
        isActive = false
    }

    /// Safety timeout if the view never calls `endPlayback()` (e.g. animation failed to mount).
    func scheduleSafetyTimeout(for animation: CustomIdleAnimation?) {
        stopTask?.cancel()
        let duration = playbackDuration(for: animation) + 0.5
        stopTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            endPlayback()
        }
    }

    func playbackDuration(for animation: CustomIdleAnimation?) -> TimeInterval {
        switch animation?.source {
        case .neonEyes:
            return BuiltInIdleAnimation.eyesOneShotDuration
        case .shimmer:
            return 3.4
        case .lottieFile, .lottieURL, .videoFile:
            return 4.5
        case .none:
            return 3.4
        }
    }

    private func evaluateSchedule() {
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)

        if trackedHour != hour {
            playedMinutesThisHour.removeAll()
            trackedHour = hour
        }

        guard !isActive else { return }
        guard Self.scheduledMinutes.contains(minute) else { return }
        guard !playedMinutesThisHour.contains(minute) else { return }
        guard isEligibleForScheduledPlayback() else { return }

        playedMinutesThisHour.insert(minute)
        beginPlayback()
    }

    private func isEligibleForScheduledPlayback() -> Bool {
        guard Defaults[.showNotHumanFace] else { return false }
        guard Defaults[.selectedIdleAnimation] != nil else { return false }

        let musicManager = MusicManager.shared
        guard !musicManager.isPlaying, musicManager.isPlayerIdle else { return false }
        return true
    }

    private func beginPlayback() {
        isActive = true
        scheduleSafetyTimeout(for: Defaults[.selectedIdleAnimation])
    }
}
