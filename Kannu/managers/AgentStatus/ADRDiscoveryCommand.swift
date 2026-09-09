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

/// How Kannu invokes the user's `adr-discovery` — held as data so tests can pin it, the same
/// discipline `ClaudeUsageFetchCommand` earned the hard way (docs/REGRESSIONS.md entry 8):
/// every argument is verified against what the tool actually accepts (0.2.0's `cli.py`).
///
/// - `--json` so the snapshot is machine-readable.
/// - `--output-dir <snapshot folder>` so the file lands where the store already watches; the
///   tool names it `snapshot-<timestamp>.json` and writes it `0600` with `O_EXCL`.
/// - `--policy <file>` only when the user configured one (tenant domains, approved, forbidden).
/// - Never `--dry-run` (nothing would be written), never `--root` (that scans a fixture tree,
///   not this Mac), never `--diff` (Kannu de-duplicates by finding id itself).
///
/// Exit codes: 0 complete, 2 partial coverage (still a valid snapshot), 1 error.
enum ADRDiscoveryCommand {
    static let exitOK: Int32 = 0
    static let exitError: Int32 = 1
    static let exitPartial: Int32 = 2

    /// A scan on this Mac took 17 s; the sweep is budgeted upstream (200 k entries). Generous
    /// but bounded: a hung scan must not pin a worker forever.
    static let timeout: TimeInterval = 180

    /// Arguments that would make the run useless or scan the wrong thing.
    static let forbiddenArguments: Set<String> = ["--dry-run", "--root", "--diff", "--explain"]

    static func arguments(outputDirectory: URL, policyFile: URL?) -> [String] {
        var args = ["--json", "--output-dir", outputDirectory.path]
        if let policyFile {
            args += ["--policy", policyFile.path]
        }
        return args
    }

    /// True when the argument list writes a real snapshot of this machine.
    static func isValidScan(arguments: [String]) -> Bool {
        guard arguments.contains("--json"),
              let index = arguments.firstIndex(of: "--output-dir"), index + 1 < arguments.count else { return false }
        return !arguments.contains { forbiddenArguments.contains($0) }
    }

    /// Whether an exit status yielded a snapshot worth reading.
    static func producedSnapshot(exitStatus: Int32) -> Bool {
        exitStatus == exitOK || exitStatus == exitPartial
    }
}
