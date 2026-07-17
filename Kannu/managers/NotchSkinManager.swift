import AppKit
import Combine
import Defaults
import Foundation
import SwiftUI

@MainActor
final class NotchSkinManager: ObservableObject {
    static let shared = NotchSkinManager()

    @Published private(set) var selectedSkinImage: NSImage?
    @Published var importError: String?

    private var cancellables = Set<AnyCancellable>()

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
        guard let selectedID = Defaults[.selectedNotchSkinID],
              let skin = Defaults[.customNotchSkins].first(where: { $0.id.uuidString == selectedID }),
              FileManager.default.fileExists(atPath: skin.fileURL.path)
        else {
            selectedSkinImage = nil
            return
        }
        selectedSkinImage = NSImage(contentsOf: skin.fileURL)
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
}
