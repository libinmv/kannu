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

/// Calls `onChange` whenever `~/.kannu/agent-policy.json` is saved, created, replaced or removed,
/// so Settings re-checks the file the moment it changes instead of on the next visit.
///
/// Why it exists: the hook re-reads the policy on every tool call and treats a malformed file as
/// no policy at all (docs/REGRESSIONS.md entry 1 — it never fails closed). Settings used to cache
/// the last check, so a hand edit that broke the JSON switched blocking off while the row still
/// showed the old rule count. Watching the file keeps the row honest.
///
/// Two sources, because editors save two ways. An atomic save (write a temp file, rename it over
/// the target) replaces the inode, which only the *directory* sees; an in-place write changes the
/// file's contents, which only the *file* sees. The directory source re-arms the file source
/// whenever the inode behind the path changes. Neither mask includes `.attrib`: reading the file
/// can bump its access time, and a re-check reacting to its own read would loop.
///
/// All state lives on one private serial queue. `onChange` is called on that queue, debounced, so
/// a save that fires several events produces one call; callers hop to their own actor. Never call
/// `start()` or `stop()` synchronously from `onChange`: both `sync` onto that same queue.
///
/// `@unchecked Sendable` because every mutable property is touched only on `queue`: `start()` and
/// `stop()` sync onto it, and both dispatch sources deliver their events on it.
final class AgentPolicyWatcher: @unchecked Sendable {
    private let fileURL: URL
    private let debounce: DispatchTimeInterval
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.kannu.agent-policy-watcher", qos: .utility)

    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var watchedInode: ino_t?
    private var pendingChange: DispatchWorkItem?

    init(fileURL: URL = AgentPolicy.fileURL,
         debounce: DispatchTimeInterval = .milliseconds(250),
         onChange: @escaping () -> Void) {
        self.fileURL = fileURL
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit {
        directorySource?.cancel()
        fileSource?.cancel()
        pendingChange?.cancel()
    }

    /// Starts watching, or re-arms whatever is missing. Safe to call repeatedly: the store calls it
    /// on every check, which is how a `~/.kannu` created after launch gets picked up. Returns
    /// whether the directory is being watched.
    @discardableResult
    func start() -> Bool {
        queue.sync {
            if directorySource == nil { armDirectory() }
            armFile()
            return directorySource != nil
        }
    }

    func stop() {
        queue.sync {
            pendingChange?.cancel()
            pendingChange = nil
            directorySource?.cancel()
            directorySource = nil
            disarmFile()
        }
    }

    // MARK: - On `queue` only

    private func armDirectory() {
        let directory = fileURL.deletingLastPathComponent()
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self, unowned source] in
            guard let self else { return }
            if !source.data.isDisjoint(with: [.rename, .delete]) {
                // The directory itself moved or went away; this fd is stale. The next start()
                // re-arms it if it comes back.
                self.directorySource?.cancel()
                self.directorySource = nil
            }
            self.armFile()
            self.scheduleChange()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directorySource = source
    }

    /// Points the file source at whatever inode is at the path now: none if the file is gone, a
    /// new one if a save replaced it, and leaves it alone if nothing changed.
    private func armFile() {
        var info = stat()
        guard stat(fileURL.path, &info) == 0 else {
            disarmFile()
            return
        }
        guard info.st_ino != watchedInode || fileSource == nil else { return }
        disarmFile()
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // After a rename or delete the path may hold a different inode, or none.
            self.armFile()
            self.scheduleChange()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
        watchedInode = info.st_ino
    }

    private func disarmFile() {
        fileSource?.cancel()
        fileSource = nil
        watchedInode = nil
    }

    private func scheduleChange() {
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingChange = nil
            self.onChange()
        }
        pendingChange = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
