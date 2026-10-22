import AppKit
import Combine
import Defaults
import Foundation
import SwiftUI

@MainActor
final class NotchSkinManager: ObservableObject {
    static let shared = NotchSkinManager()

    @Published private(set) var selectedSkinImage: NSImage?
    /// The selected skin's mean colour, which the notch's text colour is chosen against. Nil while
    /// it is being computed (once per skin, off the main thread) and when no skin is selected.
    @Published private(set) var selectedSkinAverageRGB: NotchContrast.RGB?
    @Published var importError: String?

    private var cancellables = Set<AnyCancellable>()
    private var averagedSkinID: String?
    private var averageTask: Task<Void, Never>?

    private init() {
        reloadSelectedSkin()
        Defaults.publisher(.selectedNotchSkinID, options: [])
            .sink { [weak self] _ in
                self?.reloadSelectedSkin()
            }
            .store(in: &cancellables)
        Defaults.publisher(.customNotchSkins, options: [])
            .sink { [weak self] _ in
                self?.reloadSelectedSkin()
            }
            .store(in: &cancellables)
    }

    func reloadSelectedSkin() {
        if let builtIn = BuiltInNotchSkin.with(id: Defaults[.selectedNotchSkinID]) {
            let image = NSImage(named: builtIn.assetName)
            selectedSkinImage = image
            averageSelectedSkin(image, id: builtIn.id)
            return
        }
        guard let selectedID = Defaults[.selectedNotchSkinID],
              let skin = Defaults[.customNotchSkins].first(where: { $0.id.uuidString == selectedID }),
              FileManager.default.fileExists(atPath: skin.fileURL.path)
        else {
            selectedSkinImage = nil
            averageTask?.cancel()
            averagedSkinID = nil
            selectedSkinAverageRGB = nil
            return
        }
        let image = NSImage(contentsOf: skin.fileURL)
        selectedSkinImage = image
        averageSelectedSkin(image, id: skin.id.uuidString)
    }

    /// Skin images never change under an ID (a custom skin's UUID string, a built-in's
    /// `builtin.` ID), so the average is computed once per selected skin —
    /// `reloadSelectedSkin()` also runs whenever any skin is imported or removed.
    private func averageSelectedSkin(_ image: NSImage?, id: String) {
        guard id != averagedSkinID else { return }
        averageTask?.cancel()
        averagedSkinID = id
        selectedSkinAverageRGB = nil
        // The CGImage is taken here because NSImage is not safe to use across threads.
        guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        averageTask = Task { [weak self] in
            let average = await Task.detached(priority: .utility) { cgImage.averageSRGB() }.value
            guard !Task.isCancelled else { return }
            self?.selectedSkinAverageRGB = average
        }
    }

    func importSkin(from url: URL) {
        importError = nil
        guard let image = NSImage(contentsOf: url) else {
            importError = "That file could not be loaded as an image."
            return
        }

        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let allowedExtensions = ["png", "jpg", "jpeg", "webp", "heic", "gif", "svg"]
        guard allowedExtensions.contains(ext) else {
            importError = "Supported formats: PNG, JPG, WebP, HEIC, GIF, SVG."
            return
        }

        // SVGs are vector — skip pixel-size validation; raster formats must meet minimum dimensions.
        if ext != "svg" {
            let minWidth: CGFloat = 200
            let minHeight: CGFloat = 40
            let size = image.size
            guard size.width >= minWidth, size.height >= minHeight else {
                importError = "Image must be at least \(Int(minWidth))×\(Int(minHeight)) pixels."
                return
            }
        }

        let id = UUID()
        let fileName = "notch-skin-\(id.uuidString).\(ext)"
        let destination = CustomNotchSkin.skinDirectory.appendingPathComponent(fileName)

        do {
            let data = try Data(contentsOf: url)
            try data.write(to: destination, options: [.atomic])
        } catch {
            importError = "Unable to save the skin file."
            return
        }

        let newSkin = CustomNotchSkin(
            id: id,
            name: name.isEmpty ? "Custom Skin" : name,
            fileName: fileName
        )
        var skins = Defaults[.customNotchSkins]
        if !skins.contains(newSkin) {
            skins.append(newSkin)
            Defaults[.customNotchSkins] = skins
        }
        Defaults[.selectedNotchSkinID] = newSkin.id.uuidString
        reloadSelectedSkin()
    }

    func removeSkin(_ skin: CustomNotchSkin) {
        var skins = Defaults[.customNotchSkins]
        if let index = skins.firstIndex(of: skin) {
            skins.remove(at: index)
            Defaults[.customNotchSkins] = skins
        }
        try? FileManager.default.removeItem(at: skin.fileURL)
        if Defaults[.selectedNotchSkinID] == skin.id.uuidString {
            Defaults[.selectedNotchSkinID] = nil
        }
        reloadSelectedSkin()
    }

    func selectSkin(_ skin: CustomNotchSkin?) {
        Defaults[.selectedNotchSkinID] = skin?.id.uuidString
        reloadSelectedSkin()
    }

    func selectBuiltInSkin(_ skin: BuiltInNotchSkin) {
        Defaults[.selectedNotchSkinID] = skin.id
        reloadSelectedSkin()
    }
}
