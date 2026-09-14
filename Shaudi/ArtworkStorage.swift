//
//  ArtworkStorage.swift
//  Shaudi
//

import Foundation
import ImageIO
import UIKit

enum TrackCoverMedia {
    case image(UIImage)
    case animatedGIF(UIImage)
}

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

    static func trackCover(for coverID: UUID) -> TrackCoverMedia? {
        let gifURL = directoryURL.appendingPathComponent(trackCoverGIFFilename(for: coverID))
        if
            let data = try? Data(contentsOf: gifURL),
            let image = animatedGIFImage(from: data)
        {
            return .animatedGIF(image)
        }

        guard let image = image(filename: trackCoverImageFilename(for: coverID)) else {
            return nil
        }

        return .image(image)
    }

    static func saveTrackCover(data: Data, for coverID: UUID) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        if isGIF(data) {
            guard animatedGIFImage(from: data) != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }

            deleteTrackCover(for: coverID)
            try data.write(
                to: directoryURL.appendingPathComponent(trackCoverGIFFilename(for: coverID)),
                options: .atomic
            )
            return
        }

        guard let image = UIImage(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        deleteTrackCover(for: coverID)
        try save(image, filename: trackCoverImageFilename(for: coverID))
    }

    static func deleteTrackCover(for coverID: UUID) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(
            at: directoryURL.appendingPathComponent(trackCoverImageFilename(for: coverID))
        )
        try? fileManager.removeItem(
            at: directoryURL.appendingPathComponent(trackCoverGIFFilename(for: coverID))
        )
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

    private static func trackCoverImageFilename(for coverID: UUID) -> String {
        "track-cover-\(coverID.uuidString.lowercased()).jpg"
    }

    private static func trackCoverGIFFilename(for coverID: UUID) -> String {
        "track-cover-\(coverID.uuidString.lowercased()).gif"
    }

    private static func isGIF(_ data: Data) -> Bool {
        data.starts(with: Data("GIF".utf8))
    }

    private static func animatedGIFImage(from data: Data) -> UIImage? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let firstImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1 else {
            return UIImage(cgImage: firstImage)
        }

        var frames: [UIImage] = []
        var duration: TimeInterval = 0
        for index in 0..<frameCount {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                continue
            }

            let frameDuration = gifFrameDuration(
                CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            )
            duration += frameDuration
            frames.append(UIImage(cgImage: image))
        }

        return UIImage.animatedImage(
            with: frames,
            duration: max(duration, 0.1 * Double(frames.count))
        )
    }

    private static func gifFrameDuration(_ properties: [CFString: Any]?) -> TimeInterval {
        guard
            let properties,
            let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else {
            return 0.1
        }

        let unclampedDelay = gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let delay = unclampedDelay ?? (gifProperties[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        return max(delay, 0.02)
    }

    private static var directoryURL: URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return baseURL.appendingPathComponent("Artwork", isDirectory: true)
    }
}
