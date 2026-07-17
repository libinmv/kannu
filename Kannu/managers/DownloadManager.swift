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
import SwiftUI
import Observation
import Defaults
import Combine

struct ActiveDownloadProgress: Equatable {
    var fileName: String = ""
    var bytesDownloaded: Int64 = 0
    var bytesTotal: Int64?

    var fraction: Double {
        guard let total = bytesTotal, total > 0 else { return 0 }
        return min(max(Double(bytesDownloaded) / Double(total), 0), 1)
    }

    var hasKnownTotal: Bool {
        guard let total = bytesTotal else { return false }
        return total > 0
    }
}

private enum DownloadProgressReader {
    static func progress(forPartialFile url: URL) -> ActiveDownloadProgress? {
        let ext = url.pathExtension.lowercased()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }

        if ext == "download", isDirectory.boolValue {
            return safariProgress(at: url)
        }

        if ext == "crdownload" || (ext == "download" && !isDirectory.boolValue) {
            return chromiumProgress(at: url)
        }

        return nil
    }

    private static func safariProgress(at url: URL) -> ActiveDownloadProgress? {
        let plistURL = url.appendingPathComponent("Info.plist")
        guard let dict = NSDictionary(contentsOf: plistURL) as? [String: Any] else { return nil }
        let received = int64(dict["DownloadEntryProgressBytesReceived"])
        let total = int64(dict["DownloadEntryProgressTotalBytes"])
        let displayName = (dict["DownloadEntryPathExtension"] as? String).flatMap { ext in
            let base = url.deletingPathExtension().lastPathComponent
            return base.isEmpty ? nil : "\(base).\(ext)"
        } ?? url.deletingPathExtension().lastPathComponent
        return ActiveDownloadProgress(
            fileName: displayName,
            bytesDownloaded: received,
            bytesTotal: total > 0 ? total : nil
        )
    }

    private static func chromiumProgress(at url: URL) -> ActiveDownloadProgress? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let baseName = url.deletingPathExtension().lastPathComponent
        let displayName = baseName.hasPrefix("Unconfirmed ") ? String(baseName.dropFirst("Unconfirmed ".count)) : baseName
        return ActiveDownloadProgress(
            fileName: displayName,
            bytesDownloaded: size,
            bytesTotal: nil
        )
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let n = value as? Int64 { return n }
        if let n = value as? Int { return Int64(n) }
        if let n = value as? NSNumber { return n.int64Value }
        return 0
    }
}

@Observable
@MainActor
class DownloadManager {
    static let shared = DownloadManager()

    private var defaultsCancellable: AnyCancellable?

    private(set) var isDownloading: Bool = false
    private(set) var isDownloadCompleted: Bool = false
    private(set) var activeProgress = ActiveDownloadProgress()

    private let coordinator = KannuViewCoordinator.shared
    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.dynamicisland.downloads.monitor", qos: .utility)
    private var completionTimer: Timer?
    private var progressTimer: Timer?
    private var hasPerformedInitialScan: Bool = false
    private var initialCrDownloadFiles: Set<String> = []
    private var previousAllFiles: Set<String> = []
    private var ignoredFiles: Set<String> = []
    private var trackedActiveFiles: Set<String> = []

    private var downloadsDirectory: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    init() {
        requestDownloadsPermissionIfNeeded()
        startMonitoringIfNeeded()

        defaultsCancellable = Defaults.publisher(.enableDownloadListener)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.startMonitoringIfNeeded()
                }
            }
    }

    private func startMonitoringIfNeeded() {
        if Defaults[.enableDownloadListener] {
            startMonitoring()
        } else {
            stopMonitoring()
            updateDownloadingState(isActive: false)
        }
    }

    private func startMonitoring() {
        guard source == nil, let downloadsDirectory else { return }

        hasPerformedInitialScan = false
        initialCrDownloadFiles.removeAll()
        previousAllFiles.removeAll()
        ignoredFiles.removeAll()
        trackedActiveFiles.removeAll()
        isDownloading = false
        activeProgress = ActiveDownloadProgress()

        let path = downloadsDirectory.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: queue
        )

        src.setEventHandler { [weak self] in
            self?.scanDownloadsDirectory()
        }

        src.setCancelHandler {
            close(fd)
        }

        source = src
        src.resume()

        scanDownloadsDirectory()
    }

    private func stopMonitoring() {
        source?.cancel()
        source = nil
        progressTimer?.invalidate()
        progressTimer = nil

        hasPerformedInitialScan = false
        initialCrDownloadFiles.removeAll()
        ignoredFiles.removeAll()
        trackedActiveFiles.removeAll()
        isDownloading = false
        activeProgress = ActiveDownloadProgress()
    }

    private func scanDownloadsDirectory() {
        guard let downloadsDirectory else { return }

        let crDownloadFiles: Set<String>
        let allFiles: Set<String>

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: downloadsDirectory,
                includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey]
            )

            crDownloadFiles = Set(contents
                .filter {
                    let ext = $0.pathExtension.lowercased()
                    return ext == "crdownload" || ext == "download"
                }
                .map { $0.lastPathComponent }
            )

            allFiles = Set(contents.map { $0.lastPathComponent })

        } catch {
            return
        }

        Task { @MainActor in
            self.processDownloadFiles(crDownloadFiles, allFiles: allFiles)
        }
    }

    private func processDownloadFiles(_ crDownloadFiles: Set<String>, allFiles: Set<String>) {

        if !hasPerformedInitialScan {
            hasPerformedInitialScan = true
            initialCrDownloadFiles = crDownloadFiles
            previousAllFiles = allFiles
            ignoredFiles = crDownloadFiles
            isDownloading = false
            return
        }

        let newFiles = crDownloadFiles.subtracting(initialCrDownloadFiles)
        let disappearedFiles = initialCrDownloadFiles.subtracting(crDownloadFiles)
        let newRegularFiles = allFiles.subtracting(previousAllFiles).subtracting(crDownloadFiles)

        initialCrDownloadFiles = crDownloadFiles
        previousAllFiles = allFiles

        let activeFiles = crDownloadFiles.subtracting(ignoredFiles)
        trackedActiveFiles = activeFiles
        let hasActiveDownloads = !activeFiles.isEmpty

        if !newFiles.isEmpty {
            let newActiveFiles = newFiles.subtracting(ignoredFiles)
            if !newActiveFiles.isEmpty {
                if !isDownloading {
                    updateDownloadingState(isActive: true)
                }
            }
        }

        if isDownloading {
            if hasActiveDownloads {
                refreshActiveProgress()
            } else if !newRegularFiles.isEmpty || disappearedFiles.isEmpty {
                if !isDownloadCompleted {
                    updateDownloadingState(isActive: false)
                }
            } else {
                closeDownloadViewImmediately()
            }
        } else if hasActiveDownloads {
            updateDownloadingState(isActive: true)
        }
    }

    private func refreshActiveProgress() {
        guard let downloadsDirectory else { return }
        var best: ActiveDownloadProgress?
        for name in trackedActiveFiles {
            let url = downloadsDirectory.appendingPathComponent(name)
            guard let progress = DownloadProgressReader.progress(forPartialFile: url) else { continue }
            if best == nil || progress.bytesDownloaded > (best?.bytesDownloaded ?? 0) {
                best = progress
            }
        }
        if let best {
            activeProgress = best
            coordinator.toggleExpandingView(
                status: true,
                type: .download,
                value: CGFloat(best.fraction),
                browser: .chromium
            )
        }
    }

    private func startProgressPolling() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshActiveProgress()
            }
        }
    }

    private func stopProgressPolling() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func requestDownloadsPermissionIfNeeded() {
        guard let downloadsDirectory else { return }
        _ = try? FileManager.default.contentsOfDirectory(at: downloadsDirectory, includingPropertiesForKeys: nil)
    }

    private func updateDownloadingState(isActive: Bool) {
        completionTimer?.invalidate()
        completionTimer = nil

        if isActive {
            isDownloadCompleted = false
            startProgressPolling()
            refreshActiveProgress()

            if !isDownloading {
                withAnimation(.smooth) {
                    isDownloading = true
                }
                coordinator.toggleExpandingView(
                    status: true,
                    type: .download,
                    value: CGFloat(activeProgress.fraction),
                    browser: .chromium
                )
            }

        } else {
            stopProgressPolling()
            if isDownloading {
                withAnimation(.smooth) {
                    isDownloadCompleted = true
                }

                completionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.closeDownloadView()
                    }
                }
            }
        }
    }

    private func closeDownloadView() {
        stopProgressPolling()
        withAnimation(.smooth) {
            isDownloading = false
            isDownloadCompleted = false
            activeProgress = ActiveDownloadProgress()
        }

        coordinator.toggleExpandingView(
            status: false,
            type: .download,
            value: 0,
            browser: .chromium
        )
    }

    private func closeDownloadViewImmediately() {
        completionTimer?.invalidate()
        completionTimer = nil
        closeDownloadView()
    }
}
