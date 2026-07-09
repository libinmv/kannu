/*
 * Kannu (കണ്ണ്)
 * Copyright (C) 2024-2026 Kannu Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Foundation

@MainActor
final class IdleAnimationPreviewManager: ObservableObject {
    static let shared = IdleAnimationPreviewManager()

    static let previewDuration: TimeInterval = 5

    @Published private(set) var isActive = false
    @Published private(set) var animation: CustomIdleAnimation?

    private var stopTask: Task<Void, Never>?

    private init() {}

    func startPreview(with animation: CustomIdleAnimation) {
        stopTask?.cancel()
        self.animation = animation
        isActive = true

        stopTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.previewDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            stopPreview()
        }
    }

    func stopPreview() {
        stopTask?.cancel()
        stopTask = nil
        isActive = false
        animation = nil
    }
}
