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

/// A snapshot written by ADR Discovery (`adr-discovery --json`, github.com/uber/ADR).
///
/// Discovery is a separate, user-installed program; Kannu only reads what it writes. The shape
/// is the tool's schema 1.0 — one JSON object with `assets`, `findings`, `review_queue` and a
/// `coverage` block that says what the scan could *not* see. That last part matters: upstream
/// exits 2 for a partial scan on purpose, and the UI must never turn "could not tell" into
/// "clean". Decoding is deliberately strict on the schema major and lenient on everything else
/// (unknown keys are ignored), so a newer minor release keeps working and a new major fails
/// with a message instead of a crash.
struct ADRSnapshot: Codable, Equatable {
    struct Evidence: Codable, Equatable {
        let stage: String
        let channel: String
        let path: String
        let proof: String
        let confidence: Double
        let rung: String?
    }

    struct Band: Codable, Equatable {
        let label: String
        let channels: [String]
    }

    struct Risk: Codable, Equatable {
        let pinned: Bool?
        let factors: [String]
        let credentialKinds: [String]
        let envNames: [String]
        let transport: String?
        let destinations: [String]
        let unattended: Bool
    }

    struct Asset: Codable, Equatable, Identifiable {
        let assetId: String
        let kind: String
        let name: String
        let identity: String
        let catalogId: String?
        let vendor: String?
        let version: String?
        let installPath: String?
        let installRoot: String?
        let installMethod: String?
        let liveness: String
        let confidence: Band?
        let risk: Risk?
        let sanction: String?
        let flags: [String]

        var id: String { assetId }
    }

    struct Finding: Codable, Equatable {
        let rule: String
        let severity: String
        let assetId: String
        let summary: String
        let evidence: [Evidence]
    }

    struct ReviewItem: Codable, Equatable {
        let path: String
        let score: Double
        let signals: [String]
    }

    struct Coverage: Codable, Equatable {
        struct RootSwept: Codable, Equatable { let path: String; let depthReached: Int; let entries: Int }
        struct BoundaryHit: Codable, Equatable { let path: String; let boundary: String; let detail: String }
        struct Denied: Codable, Equatable { let path: String; let reason: String }
        struct Unavailable: Codable, Equatable { let provider: String; let reason: String }
        struct Truncated: Codable, Equatable { let path: String; let kept: Int; let trueCount: Int }
        struct ProbeRun: Codable, Equatable { let name: String; let status: String; let detail: String }

        let rootsSwept: [RootSwept]
        let boundariesHit: [BoundaryHit]
        let denied: [Denied]
        let unavailable: [Unavailable]
        let truncated: [Truncated]
        let probes: [ProbeRun]
        let outOfScope: [String]

        /// Upstream's own definition: nothing went unread. Never a claim that the inventory is
        /// complete, only that nothing is known to be missing.
        var isComplete: Bool {
            boundariesHit.isEmpty && denied.isEmpty && unavailable.isEmpty && truncated.isEmpty
        }

        var gapCount: Int {
            boundariesHit.count + denied.count + unavailable.count + truncated.count
        }
    }

    let schemaVersion: String
    let catalogVersion: String
    let hostname: String
    let username: String
    let platform: String
    let timestamp: String
    let assets: [Asset]
    let findings: [Finding]
    let reviewQueue: [ReviewItem]
    let coverage: Coverage

    /// The schema major this decoder was written against.
    static let supportedSchemaMajor = 1

    enum DecodeError: Error, Equatable, LocalizedError {
        case notASnapshot
        case unsupportedSchema(String)

        var errorDescription: String? {
            switch self {
            case .notASnapshot:
                return String(localized: "The file is not an ADR Discovery snapshot.")
            case .unsupportedSchema(let version):
                return String(localized: "Snapshot schema \(version) is newer than this Kannu understands (1.x). Update Kannu.")
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, catalogVersion, hostname, username, platform, timestamp
        case assets, findings, reviewQueue, coverage
    }

    /// One pass over the document. The schema major is checked before any nested type is
    /// touched, so a future major fails with a message rather than a key-not-found deep
    /// inside a nested type — and a real snapshot (7 MB, most of it coverage entries) is not
    /// parsed twice. Missing lists decode as empty; `schema_version` defaults to 1.0.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(String.self, forKey: .schemaVersion) ?? "1.0"
        guard let major = version.split(separator: ".").first.flatMap({ Int($0) }),
              major == Self.supportedSchemaMajor else {
            throw DecodeError.unsupportedSchema(version)
        }
        schemaVersion = version
        catalogVersion = try container.decodeIfPresent(String.self, forKey: .catalogVersion) ?? "unknown"
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        platform = try container.decodeIfPresent(String.self, forKey: .platform) ?? ""
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp) ?? ""
        assets = try container.decodeIfPresent([Asset].self, forKey: .assets) ?? []
        findings = try container.decodeIfPresent([Finding].self, forKey: .findings) ?? []
        reviewQueue = try container.decodeIfPresent([ReviewItem].self, forKey: .reviewQueue) ?? []
        coverage = try container.decodeIfPresent(Coverage.self, forKey: .coverage)
            ?? Coverage(rootsSwept: [], boundariesHit: [], denied: [], unavailable: [], truncated: [], probes: [], outOfScope: [])
        // A JSON object with none of the snapshot's keys is some other file, not an old snapshot.
        if container.allKeys.isEmpty
            || !(container.contains(.assets) || container.contains(.findings) || container.contains(.schemaVersion)) {
            throw DecodeError.notASnapshot
        }
    }

    static func decode(_ data: Data) throws -> ADRSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(ADRSnapshot.self, from: data)
        } catch let error as DecodeError {
            throw error
        } catch {
            // Not JSON, or JSON of some other shape.
            throw DecodeError.notASnapshot
        }
    }

    static func load(from url: URL) throws -> ADRSnapshot {
        try decode(try Data(contentsOf: url))
    }

    /// The newest `snapshot-*.json` in a directory, by modification time — the file
    /// `adr-discovery --output-dir` writes. Nil when the directory has none.
    static func newestSnapshotURL(in directory: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return files
            .filter { $0.lastPathComponent.hasPrefix("snapshot-") && $0.pathExtension == "json" }
            .max { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l < r
            }
    }

    func asset(id: String) -> Asset? {
        assets.first { $0.assetId == id }
    }
}
