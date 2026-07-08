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
import Defaults
import AppKit

class IdleAnimationManager {
    static let shared = IdleAnimationManager()
    
    // Storage directory for user-imported animations
    private let storageDirectory: URL
    
    private init() {
        storageDirectory = AppSupportPaths.child("IdleAnimations")
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
    }
    
    // MARK: - Initialization
    
    /// Seeds built-in Shimmer and Eyes animations and migrates legacy bundled entries.
    func initializeDefaultAnimations() {
        var animations = Defaults[.customIdleAnimations].filter { !$0.isBuiltIn }

        let builtIns: [CustomIdleAnimation] = [BuiltInIdleAnimation.shimmer, BuiltInIdleAnimation.eyes]
        animations.insert(contentsOf: builtIns, at: 0)
        Defaults[.customIdleAnimations] = animations

        let selected = Defaults[.selectedIdleAnimation]
        if selected == nil {
            Defaults[.selectedIdleAnimation] = BuiltInIdleAnimation.shimmer
        } else if let selected, let refreshed = animations.first(where: { $0.id == selected.id }) {
            Defaults[.selectedIdleAnimation] = refreshed
        } else {
            Defaults[.selectedIdleAnimation] = BuiltInIdleAnimation.shimmer
        }
    }
    
    // MARK: - User Animations
    
    /// Load user-imported animations from storage directory
    private func loadStoredUserAnimations() -> [CustomIdleAnimation]? {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil)
            let jsonFiles = files.filter { $0.pathExtension.lowercased() == "json" }
            
            let animations = jsonFiles.map { url -> CustomIdleAnimation in
                let name = url.deletingPathExtension().lastPathComponent
                return CustomIdleAnimation(
                    name: name,
                    source: .lottieFile(url),
                    speed: 1.0,
                    isBuiltIn: false
                )
            }
            
            if !animations.isEmpty {
                print("💾 [IdleAnimationManager] Loaded \(animations.count) stored user animations")
            }
            return animations.isEmpty ? nil : animations
            
        } catch {
            print("❌ [IdleAnimationManager] Error loading stored animations: \(error)")
            return nil
        }
    }
    
    // MARK: - Import & Export
    
    /// Import a Lottie JSON file from URL (either local file or download from remote)
    func importLottieFile(from url: URL, name: String? = nil, speed: CGFloat = 1.0) -> Result<CustomIdleAnimation, Error> {
        let fileName = name ?? url.deletingPathExtension().lastPathComponent

        // If it's a remote URL, download it first
        if url.scheme == "http" || url.scheme == "https" {
            return importRemoteAnimation(from: url, name: fileName, speed: speed)
        }

        // Local file import
        return importLocalFile(from: url, name: fileName, speed: speed)
    }

    /// Import a local MP4/MOV video for idle animation.
    func importVideoFile(from sourceURL: URL, name: String? = nil) -> Result<CustomIdleAnimation, Error> {
        let fileName = name ?? sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension.lowercased()
        guard ext == "mp4" || ext == "mov" else {
            return .failure(AnimationImportError.invalidVideoType)
        }

        do {
            let uniqueFileName = "\(UUID().uuidString).\(ext)"
            let destinationURL = storageDirectory.appendingPathComponent(uniqueFileName)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            let animation = CustomIdleAnimation(
                name: fileName,
                source: .videoFile(destinationURL),
                speed: 1.0,
                isBuiltIn: false
            )

            var animations = Defaults[.customIdleAnimations]
            animations.append(animation)
            Defaults[.customIdleAnimations] = animations

            return .success(animation)
        } catch {
            return .failure(error)
        }
    }
    
    /// Import a local Lottie JSON file
    private func importLocalFile(from sourceURL: URL, name: String, speed: CGFloat) -> Result<CustomIdleAnimation, Error> {
        do {
            // Validate it's a JSON file
            guard sourceURL.pathExtension.lowercased() == "json" else {
                return .failure(AnimationImportError.invalidFileType)
            }
            
            // Validate JSON content (basic check)
            let data = try Data(contentsOf: sourceURL)
            guard let _ = try? JSONSerialization.jsonObject(with: data) else {
                return .failure(AnimationImportError.invalidJSON)
            }
            
            // Generate unique filename
            let uniqueFileName = "\(UUID().uuidString).json"
            let destinationURL = storageDirectory.appendingPathComponent(uniqueFileName)
            
            // Copy file to storage
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            
            // Create animation object (transforms will be stored separately)
            let animation = CustomIdleAnimation(
                name: name,
                source: .lottieFile(destinationURL),
                speed: speed,
                isBuiltIn: false
            )
            
            // Add to defaults
            var animations = Defaults[.customIdleAnimations]
            animations.append(animation)
            Defaults[.customIdleAnimations] = animations
            
            print("✅ [IdleAnimationManager] Imported local file: \(name)")
            return .success(animation)
            
        } catch {
            print("❌ [IdleAnimationManager] Import failed: \(error)")
            return .failure(error)
        }
    }
    
    /// Import animation from remote URL
    private func importRemoteAnimation(from url: URL, name: String, speed: CGFloat) -> Result<CustomIdleAnimation, Error> {
        // For remote URLs, we store the URL directly (no download)
        // The LottieView will handle downloading when needed
        
        let animation = CustomIdleAnimation(
            name: name,
            source: .lottieURL(url),
            speed: speed,
            isBuiltIn: false
        )
        
        // Add to defaults
        var animations = Defaults[.customIdleAnimations]
        animations.append(animation)
        Defaults[.customIdleAnimations] = animations
        
        print("✅ [IdleAnimationManager] Added remote animation: \(name)")
        return .success(animation)
    }
    
    // MARK: - Management
    
    /// Delete an animation (only user-added ones, not built-in)
    func deleteAnimation(_ animation: CustomIdleAnimation) -> Bool {
        guard !animation.isBuiltIn else {
            print("⚠️ [IdleAnimationManager] Cannot delete built-in animation")
            return false
        }
        
        // Remove from defaults
        var animations = Defaults[.customIdleAnimations]
        guard let index = animations.firstIndex(of: animation) else {
            return false
        }
        animations.remove(at: index)
        Defaults[.customIdleAnimations] = animations
        
        // If it's a local file, delete it from storage
        switch animation.source {
        case .shimmer, .neonEyes:
            break
        case .lottieFile(let url), .videoFile(let url):
            if url.path.contains(storageDirectory.path) {
                try? FileManager.default.removeItem(at: url)
                print("🗑️ [IdleAnimationManager] Deleted file: \(url.lastPathComponent)")
            }
        case .lottieURL:
            break
        }
        
        // If deleted animation was selected, select the first one
        if Defaults[.selectedIdleAnimation] == animation {
            Defaults[.selectedIdleAnimation] = animations.first
        }
        
        print("✅ [IdleAnimationManager] Deleted animation: \(animation.name)")
        return true
    }
    
    /// Update animation properties
    func updateAnimation(_ animation: CustomIdleAnimation, name: String? = nil, speed: CGFloat? = nil) {
        var animations = Defaults[.customIdleAnimations]
        guard let index = animations.firstIndex(where: { $0.id == animation.id }) else {
            return
        }
        
        if let name = name {
            animations[index].name = name
        }
        if let speed = speed {
            animations[index].speed = speed
        }
        
        Defaults[.customIdleAnimations] = animations
        
        // Update selected animation if it's the same one
        if Defaults[.selectedIdleAnimation]?.id == animation.id {
            Defaults[.selectedIdleAnimation] = animations[index]
        }
        
        print("✅ [IdleAnimationManager] Updated animation: \(animation.name)")
    }
}

// MARK: - Error Types
enum AnimationImportError: LocalizedError {
    case invalidFileType
    case invalidVideoType
    case invalidJSON
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .invalidFileType:
            return "Only .json files are supported for Lottie imports"
        case .invalidVideoType:
            return "Only .mp4 and .mov files are supported for video imports"
        case .invalidJSON:
            return "Invalid Lottie JSON format"
        case .downloadFailed:
            return "Failed to download animation"
        }
    }
}
