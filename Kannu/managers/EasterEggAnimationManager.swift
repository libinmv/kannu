import Combine
import Foundation

enum EasterEggPlaybackMode {
    case none
    case neonEyes
}

@MainActor
final class EasterEggAnimationManager: ObservableObject {
    static let shared = EasterEggAnimationManager()

    @Published private(set) var isActive = false
    @Published private(set) var playbackMode: EasterEggPlaybackMode = .none

    private var clockTimer: Timer?
    private var playedToday = false
    private var lastPlayedDay: Int?

    private init() {
        startClock()
    }

    func startClock() {
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateSchedule()
            }
        }
        evaluateSchedule()
    }

    private func evaluateSchedule() {
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let day = calendar.ordinality(of: .day, in: .year, for: now) ?? 0

        if lastPlayedDay != day {
            playedToday = false
            lastPlayedDay = day
        }

        guard hour == 4, minute == 20, !playedToday, !isActive else { return }

        playedToday = true
        playBundledEyesOnce()
    }

    func playBundledEyesOnce() {
        stopPlayback(resetPlayedFlag: false)
        playbackMode = .neonEyes
        isActive = true
    }

    func stopPlayback(resetPlayedFlag: Bool) {
        playbackMode = .none
        isActive = false
        if resetPlayedFlag {
            playedToday = false
        }
    }
}
