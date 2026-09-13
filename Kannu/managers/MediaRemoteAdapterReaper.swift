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

import Darwin
import Foundation

/// Clears `mediaremote-adapter.pl` helpers this build left behind.
///
/// `NowPlayingController.stop()` is what stops the leak. This is the other half: Kannu gets force-quit
/// and it does crash, and neither path runs a teardown, so a helper from a previous run can still be
/// streaming when the next one starts. The ownership rule lives in `MediaRemoteAdapterOwnership`,
/// which is where the reasoning and the tests are — this file is only the process walk and the signal.
///
/// Runs once, off the main thread, and signals nothing it cannot prove is its own.
enum MediaRemoteAdapterReaper {
    /// This bundle's own adapter script, or nil when it is not in the bundle (so nothing is reapable).
    private static var ownScriptPath: String? {
        Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl")?.path
    }

    /// Terminates orphaned helpers belonging to this bundle. Returns how many were signalled.
    @discardableResult
    static func reapOrphanedHelpers() -> Int {
        guard let ownScriptPath else { return 0 }

        var reaped = 0
        for candidate in userProcesses() {
            guard MediaRemoteAdapterOwnership.isReapable(
                command: candidate.command,
                parentPID: candidate.parentPID,
                ownScriptPath: ownScriptPath
            ) else { continue }

            if kill(candidate.pid, SIGTERM) == 0 {
                reaped += 1
                Logger.log(
                    "Reaped an orphaned now-playing helper (pid \(candidate.pid))",
                    category: .lifecycle
                )
            }
        }
        return reaped
    }

    private struct Candidate {
        let pid: Int32
        let parentPID: Int32
        let command: String
    }

    /// Every process this user owns whose executable name is `perl`, with its argv.
    ///
    /// Filtering on `p_comm` first matters: reading argv costs a `sysctl` per process, and on a busy
    /// Mac that is several hundred calls for the handful that could possibly match.
    private static func userProcesses() -> [Candidate] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // Headroom for processes spawned between the two calls.
        size += MemoryLayout<kinfo_proc>.stride * 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }

        let uid = getuid()
        var candidates: [Candidate] = []
        for index in 0..<(size / MemoryLayout<kinfo_proc>.stride) {
            var proc = procs[index]
            guard proc.kp_eproc.e_ucred.cr_uid == uid else { continue }
            let name = withUnsafeBytes(of: &proc.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            guard name == "perl" else { continue }

            let pid = proc.kp_proc.p_pid
            guard pid != getpid(), let command = commandLine(of: pid) else { continue }
            candidates.append(
                Candidate(pid: pid, parentPID: proc.kp_eproc.e_ppid, command: command)
            )
        }
        return candidates
    }

    /// A process's argv, space-joined. `KERN_PROCARGS2` lays out an `Int32` argc, then the executable
    /// path, then NUL-padding, then argc NUL-terminated arguments.
    private static func commandLine(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { destination in
            buffer.withUnsafeBytes { source in
                destination.copyBytes(from: source.prefix(MemoryLayout<Int32>.size))
            }
        }
        guard argc > 0 else { return nil }

        // Split the payload on NUL, drop the leading executable path and the padding after it, then
        // take argc arguments — argv[0] included, since the adapter is identified by argv[1].
        //
        // Decoded from the bytes rather than through `String(validatingUTF8:)`: a split slice is not
        // NUL-terminated, and handing a C-string initialiser a pointer to one only works because the
        // separator happens to sit in the parent buffer just past it. That is a read past the slice's
        // own bounds, and it stops being true the moment the slicing changes.
        let payload = buffer[MemoryLayout<Int32>.size..<size]
        let tokens = payload
            .split(separator: 0, omittingEmptySubsequences: true)
            .map { slice in
                String(decoding: slice.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        guard tokens.count > 1 else { return nil }
        return tokens.dropFirst().prefix(Int(argc)).joined(separator: " ")
    }
}
