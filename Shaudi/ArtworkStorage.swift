//
//  ArtworkStorage.swift
//  Shaudi
//

import Foundation
import UIKit

enum ArtworkStorage {
    static let bannerAspectRatio: CGFloat = 360 / 148
    static let bannerOutputSize = CGSize(width: 1_080, height: 444)
    static let playlistOutputSize = CGSize(width: 900, height: 900)

    private static let bannerFilename = "library-banner.jpg"

    static func bannerImage() -> UIImage? {
        image(filename: bannerFilename)
    }

    static func saveBannerImage(_ image: UIImage) throws {
        try save(image, filename: bannerFilename)
    }

    static func resetBannerImage() {
        let url = directoryURL.appendingPathComponent(bannerFilename)
        try? FileManager.default.removeItem(at: url)
        clearLegacyBannerStorage()
    }

    static func migratedLegacyBannerImage() -> UIImage? {
        let defaults = UserDefaults.standard
        guard
            let imageData = defaults.string(forKey: "shaudi.library.heroImage"),
            let data = Data(base64Encoded: imageData),
            let image = UIImage(data: data)
        else {
            return nil
        }

        return migratedBannerImage(
            image,
            scale: defaults.double(forKey: "shaudi.library.heroScale"),
            normalizedOffset: CGSize(
                width: defaults.double(forKey: "shaudi.library.heroOffsetX"),
                height: defaults.double(forKey: "shaudi.library.heroOffsetY")
            )
        )
    }

    static func clearLegacyBannerStorage() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "shaudi.library.heroImage")
        defaults.removeObject(forKey: "shaudi.library.heroOffsetX")
        defaults.removeObject(forKey: "shaudi.library.heroOffsetY")
        defaults.removeObject(forKey: "shaudi.library.heroScale")
    }

    static func migratedBannerImage(
        _ image: UIImage,
        scale: CGFloat,
        normalizedOffset: CGSize
    ) -> UIImage {
        let imageAspectRatio = image.size.width / max(1, image.size.height)
        let baseImageSize: CGSize

        if imageAspectRatio > bannerAspectRatio {
            baseImageSize = CGSize(
                width: bannerOutputSize.height * imageAspectRatio,
                height: bannerOutputSize.height
            )
        } else {
            baseImageSize = CGSize(
                width: bannerOutputSize.width,
                height: bannerOutputSize.width / max(imageAspectRatio, 0.001)
            )
        }

        let appliedScale = max(1, scale)
        let renderedSize = CGSize(
            width: baseImageSize.width * appliedScale,
            height: baseImageSize.height * appliedScale
        )
        let drawRect = CGRect(
            x: (bannerOutputSize.width - renderedSize.width) / 2
                + normalizedOffset.width * bannerOutputSize.width,
            y: (bannerOutputSize.height - renderedSize.height) / 2
                + normalizedOffset.height * bannerOutputSize.height,
            width: renderedSize.width,
            height: renderedSize.height
        )

        return render(image, in: drawRect, outputSize: bannerOutputSize)
    }

    static func playlistImage(for artworkID: UUID) -> UIImage? {
        image(filename: playlistFilename(for: artworkID))
    }

    static func savePlaylistImage(_ image: UIImage, for artworkID: UUID) throws {
        try save(image, filename: playlistFilename(for: artworkID))
    }

    static func deletePlaylistImage(for artworkID: UUID) {
        let url = directoryURL.appendingPathComponent(playlistFilename(for: artworkID))
        try? FileManager.default.removeItem(at: url)
    }

    private static func image(filename: String) -> UIImage? {
        UIImage(contentsOfFile: directoryURL.appendingPathComponent(filename).path)
    }

    private static func save(_ image: UIImage, filename: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        guard let data = image.jpegData(compressionQuality: 0.88) else {
            throw CocoaError(.fileWriteUnknown)
        }

        try data.write(
            to: directoryURL.appendingPathComponent(filename),
            options: .atomic
        )
    }

    private static func render(
        _ image: UIImage,
        in drawRect: CGRect,
        outputSize: CGSize
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: outputSize))
            image.draw(in: drawRect)
        }
    }

    private static func playlistFilename(for artworkID: UUID) -> String {
        "playlist-\(artworkID.uuidString.lowercased()).jpg"
    }

    private static var directoryURL: URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return baseURL.appendingPathComponent("Artwork", isDirectory: true)
    }
}
