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

/// One battery level a live Bluetooth LE read wrote, stamped with the order it was written in.
struct BluetoothLiveBatteryWrite: Equatable {
    let level: Int
    /// Monotonic counter, incremented once per accepted live write. Only ever compared, never
    /// interpreted as a time.
    let sequence: UInt64
}

/// Reconciles a forced battery scan's snapshot with the live Bluetooth LE reads that landed while
/// it was out fetching.
///
/// `BluetoothAudioManager.updateBatteryStatuses` replaces its published maps wholesale with what it
/// collected. That is safe when collection is synchronous — nothing can interleave — and it is the
/// behaviour a forced scan needs, because a scan must be able to *lower* a value as the battery
/// drains, so a plain "higher wins" merge would pin a stale peak forever.
///
/// It stops being safe once collection moves off the main thread, which is what
/// `system_profiler SPBluetoothDataType` requires: the collect-to-apply window grows from ~0 to
/// seconds, and a live BLE result that lands inside it is silently reverted by a snapshot that was
/// taken before it. Nothing recovers the value either, because the live reader only re-reads a
/// device whose level is `nil` and the reverted value is not nil.
///
/// So the scan stays authoritative for everything it can speak for, and yields only for the window
/// it cannot: a key whose live write happened *after* the scan started collecting.
enum BluetoothLiveBatteryWrites {
    /// Overlays live writes newer than `baseline` onto a scan's collected levels.
    ///
    /// - Parameters:
    ///   - collected: what the scan found.
    ///   - liveWrites: the newest live write per key, whatever its age.
    ///   - baseline: the write sequence as it stood when the scan began collecting. A write at or
    ///     below it predates the scan, so the scan's value is the newer fact and wins.
    static func overlaying(
        _ collected: [String: Int],
        with liveWrites: [String: BluetoothLiveBatteryWrite],
        newerThan baseline: UInt64
    ) -> [String: Int] {
        guard !liveWrites.isEmpty else { return collected }

        var merged = collected
        for (key, write) in liveWrites where write.sequence > baseline {
            guard !key.isEmpty else { continue }
            merged[key] = write.level
        }
        return merged
    }
}
