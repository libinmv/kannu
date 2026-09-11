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

import Defaults
import Foundation
import os

/// The connection to Uber's ADR (github.com/uber/ADR, Apache-2.0) — a **separate** install.
///
/// Kannu ships no Python and no wheels, runs no package manager, and writes nothing into the
/// user's tool directories. What it does: look for the `adr-discovery` and `adr-sensor`
/// executables where uv, pipx and Homebrew put them (plus one user-set directory), read their
/// versions, and hand Settings the exact install commands when they are missing. Detection is
/// on demand ("Check again"); nothing polls for binaries.
@MainActor
final class ADRConnection: ObservableObject {
    static let shared = ADRConnection()

    enum Tool: String, CaseIterable, Identifiable {
        case discovery = "adr-discovery"
        case sensor = "adr-sensor"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .discovery: return "ADR Discovery"
            case .sensor: return "ADR Sensor"
            }
        }

        /// The upstream package is not on PyPI for Discovery, so the install line is a git URL;
        /// Sensor is on PyPI. Both use `uv tool install`, which keeps each tool in its own
        /// environment and links the executable into `~/.local/bin`.
        var installCommand: String {
            switch self {
            case .discovery:
                return #"uv tool install "adr-discovery @ git+https://github.com/uber/ADR#subdirectory=Discovery""#
            case .sensor:
                return "uv tool install adr-sensor"
            }
        }

        var pipxCommand: String {
            switch self {
            case .discovery:
                return #"pipx install "git+https://github.com/uber/ADR#subdirectory=Discovery""#
            case .sensor:
                return "pipx install adr-sensor"
            }
        }
    }

    struct Status: Equatable {
        enum State: Equatable {
            case unchecked
            case notFound
            case found(executable: URL, version: String?)
        }

        var state: State = .unchecked

        var isFound: Bool {
            if case .found = state { return true }
            return false
        }

        var version: String? {
            if case .found(_, let version) = state { return version }
            return nil
        }

        var executable: URL? {
            if case .found(let url, _) = state { return url }
            return nil
        }
    }

    @Published private(set) var discovery = Status()
    @Published private(set) var sensor = Status()
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckedAt: Date?

    /// ADR Detection is a checkout the user prepares (`git clone`, `uv sync`), not a tool binary.
    struct DetectionStatus: Equatable {
        enum State: Equatable {
            case unchecked
            case notConfigured
            case invalid(reason: String)
            case ready(uv: URL)
        }
        var state: State = .unchecked
        var isReady: Bool { if case .ready = state { return true }; return false }
        var uv: URL? { if case .ready(let uv) = state { return uv }; return nil }
        var caption: String {
            switch state {
            case .unchecked: return String(localized: "Not checked yet")
            case .notConfigured: return String(localized: "No checkout chosen")
            case .invalid(let reason): return reason
            case .ready(let uv): return String(localized: "Ready — uv at \(uv.path)")
            }
        }
    }
    @Published private(set) var detection = DetectionStatus()

    static let detectionCloneCommand = "git clone https://github.com/uber/ADR && cd ADR/Detection && uv sync"

    /// `uv` where Homebrew, the uv installer or a user path put it.
    static func uvExecutable(userDirectory: String = Defaults[.adrToolDirectory]) -> URL? {
        candidateDirectories(userDirectory: userDirectory)
            .map { $0.appendingPathComponent("uv") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Pure: what a usable Detection checkout must contain, and why it is not usable otherwise.
    static func validateDetectionCheckout(_ path: String, uv: URL?, fileManager: FileManager = .default) -> DetectionStatus.State {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notConfigured }
        let root = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
        guard fileManager.fileExists(atPath: root.appendingPathComponent("pyproject.toml").path) else {
            return .invalid(reason: String(localized: "No pyproject.toml here — choose the ADR/Detection folder"))
        }
        guard fileManager.fileExists(atPath: root.appendingPathComponent("guardrail/adr_agent/adr_baseline.py").path) else {
            return .invalid(reason: String(localized: "This is not ADR's Detection folder (guardrail/adr_agent missing)"))
        }
        guard fileManager.fileExists(atPath: root.appendingPathComponent(".venv").path) else {
            return .invalid(reason: String(localized: "Not synced yet — run `uv sync` in this folder"))
        }
        guard let uv else { return .invalid(reason: String(localized: "uv not found (brew install uv)")) }
        return .ready(uv: uv)
    }

    /// Re-validates the configured checkout off the main actor (a few stats and one lookup).
    func checkDetection() {
        let path = Defaults[.adrDetectionCheckout]
        let userDirectory = Defaults[.adrToolDirectory]
        DispatchQueue.global(qos: .utility).async {
            let state = Self.validateDetectionCheckout(path, uv: Self.uvExecutable(userDirectory: userDirectory))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.detection.state != state { self.detection = DetectionStatus(state: state) }
                }
            }
        }
    }

    static let projectURL = URL(string: "https://github.com/uber/ADR")!
    static let versionArguments = ["--version"]

    private static let logger = os.Logger(subsystem: "com.kannu.app", category: "ADRConnection")

    private init() {}

    var isConnected: Bool { discovery.isFound }

    /// Directories searched, in order. The user-set one first so it can override a stale
    /// system copy; then uv's and pipx's bin dir; then Homebrew and the classic prefix.
    static func candidateDirectories(userDirectory: String) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs: [URL] = []
        let trimmed = userDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            dirs.append(URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true))
        }
        dirs.append(home.appendingPathComponent(".local/bin", isDirectory: true))
        // `uv tool install` links into ~/.local/bin, but a user who skipped the link still has
        // the tool's own environment here.
        let uvTools = home.appendingPathComponent(".local/share/uv/tools", isDirectory: true)
        for tool in Tool.allCases {
            dirs.append(uvTools.appendingPathComponent("\(tool.rawValue)/bin", isDirectory: true))
        }
        dirs.append(URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true))
        dirs.append(URL(fileURLWithPath: "/usr/local/bin", isDirectory: true))
        return dirs
    }

    /// Pure: the first executable named after the tool in the candidate directories.
    static func locate(_ tool: Tool, in directories: [URL], fileManager: FileManager = .default) -> URL? {
        for directory in directories {
            let candidate = directory.appendingPathComponent(tool.rawValue)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// A check asked for while one runs (the tools folder changed): run again when it ends,
    /// rather than drop it.
    private var recheckQueued = false

    /// Re-runs detection. Version reads happen off the main actor; results are published back.
    func checkAgain() {
        guard !isChecking else {
            recheckQueued = true
            return
        }
        isChecking = true
        let directories = Self.candidateDirectories(userDirectory: Defaults[.adrToolDirectory])
        DispatchQueue.global(qos: .utility).async {
            var results: [Tool: Status] = [:]
            for tool in Tool.allCases {
                guard let executable = Self.locate(tool, in: directories) else {
                    results[tool] = Status(state: .notFound)
                    continue
                }
                let version = Self.readVersion(of: executable) ?? Self.readVersionFromUVToolList(tool)
                results[tool] = Status(state: .found(executable: executable, version: version))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.discovery = results[.discovery] ?? Status(state: .notFound)
                    self.sensor = results[.sensor] ?? Status(state: .notFound)
                    self.lastCheckedAt = Date()
                    self.isChecking = false
                    Self.logger.info("ADR check: discovery=\(self.discovery.isFound, privacy: .public) sensor=\(self.sensor.isFound, privacy: .public)")
                    if self.recheckQueued {
                        self.recheckQueued = false
                        self.checkAgain()
                    }
                }
            }
        }
    }

    /// `<tool> --version`, bounded. A tool that hangs or prints nothing is still "found";
    /// the version is decoration. `adr-discovery` 0.2.0 has no such flag (argparse prints usage
    /// to stderr and exits 2), so stdout is empty and the uv fallback below answers instead.
    private nonisolated static func readVersion(of executable: URL) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = versionArguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // `adr-sensor --version` prints the bare number; be tolerant of "name 1.2.3" too.
        let last = text.split(separator: " ").last.map(String.init) ?? text
        return last.isEmpty ? nil : String(last.prefix(32))
    }

    static let uvToolListArguments = ["tool", "list"]

    /// `uv tool list` prints one `name vX.Y.Z` line per installed tool. Read-only, bounded,
    /// and only consulted when the tool itself would not say.
    private nonisolated static func readVersionFromUVToolList(_ tool: Tool) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/uv"),
            URL(fileURLWithPath: "/opt/homebrew/bin/uv"),
            URL(fileURLWithPath: "/usr/local/bin/uv")
        ]
        guard let uv = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return nil }
        let process = Process()
        process.executableURL = uv
        process.arguments = uvToolListArguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate() }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0] == Substring(tool.rawValue) else { continue }
            let version = parts[1].hasPrefix("v") ? String(parts[1].dropFirst()) : String(parts[1])
            return String(version.prefix(32))
        }
        return nil
    }
}
