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

enum BuiltInIdleAnimation {
    static let eyesTransform = AnimationTransformConfig(
        scale: 1.0,
        offsetX: 0,
        offsetY: 0,
        cropWidth: 200,
        cropHeight: 36,
        rotation: 0,
        opacity: 1.0,
        paddingBottom: 0,
        expandWithAnimation: false,
        loopMode: .loop
    )

    static let shimmerID = UUID(uuidString: "A1B2C3D4-E5F6-4789-A012-3456789ABCDE")!
    static let eyesID = UUID(uuidString: "B2C3D4E5-F6A7-4890-B123-456789ABCDEF")!

    static let shimmer = CustomIdleAnimation(
        id: shimmerID,
        name: "Shimmer",
        source: .shimmer,
        isBuiltIn: true
    )

    static let eyes = CustomIdleAnimation(
        id: eyesID,
        name: "Eyes",
        source: .neonEyes,
        isBuiltIn: true
    )

    /// Duration of the one-shot easter egg eyes sequence.
    static let eyesOneShotDuration: TimeInterval = 3.2
}
