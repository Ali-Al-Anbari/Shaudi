//
//  ArtworkStorage.swift
//  Shaudi
//

import CoreTransferable
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

struct ArtworkCrop: Codable, Equatable {
    var scale: Double
    var normalizedOffsetX: Double
    var normalizedOffsetY: Double

    static let `default` = ArtworkCrop(scale: 1, normalizedOffsetX: 0, normalizedOffsetY: 0)

    static func baseImageSize(
        for imageSize: CGSize,
        in viewportSize: CGSize
    ) -> CGSize {
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            return .zero
        }
        let imageAspectRatio = imageSize.width / max(1, imageSize.height)
        let viewportAspectRatio = viewportSize.width / max(1, viewportSize.height)

        if imageAspectRatio > viewportAspectRatio {
            return CGSize(
                width: viewportSize.height * imageAspectRatio,
                height: viewportSize.height
            )
        } else {
            return CGSize(
                width: viewportSize.width,
                height: viewportSize.width / max(imageAspectRatio, 0.001)
            )
        }
    }

    func clampedOffset(
        scaledSize: CGSize,
        viewportSize: CGSize
    ) -> CGSize {
        let proposedOffset = CGSize(
            width: normalizedOffsetX * viewportSize.width,
            height: normalizedOffsetY * viewportSize.height
        )
        let maximumX = max(0, (scaledSize.width - viewportSize.width) / 2)
        let maximumY = max(0, (scaledSize.height - viewportSize.height) / 2)

        return CGSize(
            width: min(max(proposedOffset.width, -maximumX), maximumX),
            height: min(max(proposedOffset.height, -maximumY), maximumY)
        )
    }
}

struct GIFDataTransferable: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .gif) { data in
            GIFDataTransferable(data: data)
        }
    }
}

enum PlaylistCoverMedia {
    case image(UIImage)
    case animatedGIF(UIImage, crop: ArtworkCrop)

    var image: UIImage {
        switch self {
        case .image(let image), .animatedGIF(let image, _):
            return image
        }
    }
}

enum BannerMedia {
    case image(UIImage)
    case animatedGIF(UIImage, crop: ArtworkCrop)

    var image: UIImage {
        switch self {
        case .image(let image), .animatedGIF(let image, _):
            return image
        }
    }
}

enum ArtworkStorageError: LocalizedError {
    case invalidGIF
    case gifTooLarge(maximumMegabytes: Int)

    var errorDescription: String? {
        switch self {
        case .invalidGIF:
            return "That GIF could not be read. Please choose a different file."
        case .gifTooLarge(let maximumMegabytes):
            return "That GIF is too large. Choose one smaller than \(maximumMegabytes) MB."
        }
    }
}

enum TrackCoverMedia {
    case image(UIImage)
    case animatedGIF(UIImage)
}

enum ArtworkStorage {
    static let bannerAspectRatio: CGFloat = 360 / 148
    static let bannerOutputSize = CGSize(width: 1_080, height: 444)
    static let playlistOutputSize = CGSize(width: 900, height: 900)
    static let maximumPlaylistGIFSize = 25 * 1_024 * 1_024
    static let maximumDecodedGIFBytes = 24 * 1_024 * 1_024
    static let maximumDecodedGIFFrames = 120
    static let maximumSourceGIFFrames = 2_000

    private final class PlaylistCoverCacheEntry {
        let media: PlaylistCoverMedia

        init(_ media: PlaylistCoverMedia) {
            self.media = media
        }
    }

    private static let playlistCoverCache: NSCache<NSString, PlaylistCoverCacheEntry> = {
        let cache = NSCache<NSString, PlaylistCoverCacheEntry>()
        cache.totalCostLimit = 96 * 1_024 * 1_024
        return cache
    }()

    private final class TrackCoverCacheEntry {
        let media: TrackCoverMedia

        init(_ media: TrackCoverMedia) {
            self.media = media
        }
    }

    private static let trackCoverCache: NSCache<NSString, TrackCoverCacheEntry> = {
        let cache = NSCache<NSString, TrackCoverCacheEntry>()
        cache.totalCostLimit = 96 * 1_024 * 1_024
        return cache
    }()

    static let maximumBannerGIFSize = 25 * 1_024 * 1_024
    private static let bannerFilename = "library-banner.jpg"
    private static let bannerGIFFilename = "library-banner.gif"
    private static let bannerCropFilename = "library-banner.crop.json"

    private final class BannerCacheEntry {
        let media: BannerMedia

        init(_ media: BannerMedia) {
            self.media = media
        }
    }

    private static let bannerCache: NSCache<NSString, BannerCacheEntry> = {
        let cache = NSCache<NSString, BannerCacheEntry>()
        cache.totalCostLimit = 48 * 1_024 * 1_024
        return cache
    }()

    static func bannerMedia() -> BannerMedia? {
        if let cached = bannerCache.object(forKey: "banner") {
            return cached.media
        }

        if
            let data = bannerGIFData(),
            let image = animatedGIFImage(from: data)
        {
            let crop = bannerCrop() ?? .default
            let media = BannerMedia.animatedGIF(image, crop: crop)
            cacheBanner(media)
            return media
        }

        guard let image = image(filename: bannerFilename) else {
            return nil
        }

        let media = BannerMedia.image(image)
        cacheBanner(media)
        return media
    }

    static func bannerImage() -> UIImage? {
        bannerMedia()?.image
    }

    static func bannerGIFData() -> Data? {
        try? Data(
            contentsOf: directoryURL.appendingPathComponent(bannerGIFFilename)
        )
    }

    static func bannerCrop() -> ArtworkCrop? {
        let url = directoryURL.appendingPathComponent(bannerCropFilename)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(ArtworkCrop.self, from: data)
    }

    static func saveBannerCrop(_ crop: ArtworkCrop) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(crop)
        try data.write(
            to: directoryURL.appendingPathComponent(bannerCropFilename),
            options: .atomic
        )
    }

    static func deleteBannerCrop() {
        let url = directoryURL.appendingPathComponent(bannerCropFilename)
        try? FileManager.default.removeItem(at: url)
    }

    static func saveBannerImage(_ image: UIImage) throws {
        try save(image, filename: bannerFilename)
        try removeObsoleteArtwork(
            afterWriting: bannerFilename,
            obsoleteFilename: bannerGIFFilename
        )
        deleteBannerCrop()
        cacheBanner(.image(image))
    }

    static func saveBannerGIF(
        _ data: Data,
        crop: ArtworkCrop = .default
    ) throws {
        guard data.count <= maximumBannerGIFSize else {
            throw ArtworkStorageError.gifTooLarge(
                maximumMegabytes: maximumBannerGIFSize / 1_024 / 1_024
            )
        }
        guard isGIFData(data), let image = animatedGIFImage(from: data) else {
            throw ArtworkStorageError.invalidGIF
        }

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try data.write(
            to: directoryURL.appendingPathComponent(bannerGIFFilename),
            options: .atomic
        )
        try saveBannerCrop(crop)
        try removeObsoleteArtwork(
            afterWriting: bannerGIFFilename,
            obsoleteFilename: bannerFilename
        )
        cacheBanner(.animatedGIF(image, crop: crop))
    }

    static func resetBannerImage() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directoryURL.appendingPathComponent(bannerFilename))
        try? fileManager.removeItem(at: directoryURL.appendingPathComponent(bannerGIFFilename))
        deleteBannerCrop()
        clearBannerCache()
        clearLegacyBannerStorage()
    }

    static func clearBannerCache() {
        bannerCache.removeAllObjects()
    }

    private static func cacheBanner(_ media: BannerMedia) {
        let image = media.image
        bannerCache.setObject(
            BannerCacheEntry(media),
            forKey: "banner",
            cost: decodedImageCost(image)
        )
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

    static func playlistCrop(for artworkID: UUID) -> ArtworkCrop? {
        let url = directoryURL.appendingPathComponent(playlistCropFilename(for: artworkID))
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(ArtworkCrop.self, from: data)
    }

    static func savePlaylistCrop(_ crop: ArtworkCrop, for artworkID: UUID) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(crop)
        try data.write(
            to: directoryURL.appendingPathComponent(playlistCropFilename(for: artworkID)),
            options: .atomic
        )
    }

    static func deletePlaylistCrop(for artworkID: UUID) {
        let url = directoryURL.appendingPathComponent(playlistCropFilename(for: artworkID))
        try? FileManager.default.removeItem(at: url)
    }

    static func playlistCover(for artworkID: UUID) -> PlaylistCoverMedia? {
        let cacheKey = artworkID.uuidString.lowercased() as NSString
        if let cached = playlistCoverCache.object(forKey: cacheKey) {
            return cached.media
        }

        if
            let data = playlistGIFData(for: artworkID),
            let image = animatedGIFImage(from: data)
        {
            let crop = playlistCrop(for: artworkID) ?? .default
            let media = PlaylistCoverMedia.animatedGIF(image, crop: crop)
            cachePlaylistCover(media, for: artworkID)
            return media
        }

        guard let image = playlistImage(for: artworkID) else {
            return nil
        }

        let media = PlaylistCoverMedia.image(image)
        cachePlaylistCover(media, for: artworkID)
        return media
    }

    static func savePlaylistImage(_ image: UIImage, for artworkID: UUID) throws {
        let filename = playlistFilename(for: artworkID)
        try save(image, filename: filename)
        try removeObsoleteArtwork(
            afterWriting: filename,
            obsoleteFilename: playlistGIFFilename(for: artworkID)
        )
        deletePlaylistCrop(for: artworkID)
        cachePlaylistCover(.image(image), for: artworkID)
    }

    static func savePlaylistGIF(
        _ data: Data,
        crop: ArtworkCrop = .default,
        for artworkID: UUID
    ) throws {
        guard data.count <= maximumPlaylistGIFSize else {
            throw ArtworkStorageError.gifTooLarge(
                maximumMegabytes: maximumPlaylistGIFSize / 1_024 / 1_024
            )
        }
        guard isGIFData(data), let image = animatedGIFImage(from: data) else {
            throw ArtworkStorageError.invalidGIF
        }

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try data.write(
            to: directoryURL.appendingPathComponent(playlistGIFFilename(for: artworkID)),
            options: .atomic
        )
        try savePlaylistCrop(crop, for: artworkID)
        try removeObsoleteArtwork(
            afterWriting: playlistGIFFilename(for: artworkID),
            obsoleteFilename: playlistFilename(for: artworkID)
        )
        cachePlaylistCover(.animatedGIF(image, crop: crop), for: artworkID)
    }

    static func playlistGIFData(for artworkID: UUID) -> Data? {
        try? Data(
            contentsOf: directoryURL.appendingPathComponent(playlistGIFFilename(for: artworkID))
        )
    }

    static func deletePlaylistImage(for artworkID: UUID) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(
            at: directoryURL.appendingPathComponent(playlistFilename(for: artworkID))
        )
        try? fileManager.removeItem(
            at: directoryURL.appendingPathComponent(playlistGIFFilename(for: artworkID))
        )
        deletePlaylistCrop(for: artworkID)
        playlistCoverCache.removeObject(forKey: artworkID.uuidString.lowercased() as NSString)
    }

    static func clearPlaylistCoverCache() {
        playlistCoverCache.removeAllObjects()
    }

    static func isGIFData(_ data: Data) -> Bool {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let typeIdentifier = CGImageSourceGetType(source),
            let type = UTType(typeIdentifier as String)
        else {
            return false
        }

        return type.conforms(to: .gif)
    }

    static func trackCover(for coverID: UUID) -> TrackCoverMedia? {
        let cacheKey = coverID.uuidString.lowercased() as NSString
        if let cached = trackCoverCache.object(forKey: cacheKey) {
            return cached.media
        }

        let gifURL = directoryURL.appendingPathComponent(trackCoverGIFFilename(for: coverID))
        if
            let data = try? Data(contentsOf: gifURL),
            let image = animatedGIFImage(from: data)
        {
            let media = TrackCoverMedia.animatedGIF(image)
            cacheTrackCover(media, for: coverID)
            return media
        }

        guard let image = image(filename: trackCoverImageFilename(for: coverID)) else {
            return nil
        }

        let media = TrackCoverMedia.image(image)
        cacheTrackCover(media, for: coverID)
        return media
    }

    static func saveTrackCover(data: Data, for coverID: UUID) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        if isGIF(data) {
            guard data.count <= maximumPlaylistGIFSize else {
                throw ArtworkStorageError.gifTooLarge(
                    maximumMegabytes: maximumPlaylistGIFSize / 1_024 / 1_024
                )
            }
            guard let image = animatedGIFImage(from: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }

            try data.write(
                to: directoryURL.appendingPathComponent(trackCoverGIFFilename(for: coverID)),
                options: .atomic
            )
            try removeObsoleteArtwork(
                afterWriting: trackCoverGIFFilename(for: coverID),
                obsoleteFilename: trackCoverImageFilename(for: coverID)
            )
            cacheTrackCover(.animatedGIF(image), for: coverID)
            return
        }

        guard let image = UIImage(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try save(image, filename: trackCoverImageFilename(for: coverID))
        try removeObsoleteArtwork(
            afterWriting: trackCoverImageFilename(for: coverID),
            obsoleteFilename: trackCoverGIFFilename(for: coverID)
        )
        cacheTrackCover(.image(image), for: coverID)
    }

    static func deleteTrackCover(for coverID: UUID) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(
            at: directoryURL.appendingPathComponent(trackCoverImageFilename(for: coverID))
        )
        try? fileManager.removeItem(
            at: directoryURL.appendingPathComponent(trackCoverGIFFilename(for: coverID))
        )
        trackCoverCache.removeObject(forKey: coverID.uuidString.lowercased() as NSString)
    }

    static func clearTrackCoverCache() {
        trackCoverCache.removeAllObjects()
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

    private static func removeObsoleteArtwork(
        afterWriting newFilename: String,
        obsoleteFilename: String
    ) throws {
        let obsoleteURL = directoryURL.appendingPathComponent(obsoleteFilename)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: obsoleteURL.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: obsoleteURL)
        } catch {
            try? fileManager.removeItem(at: directoryURL.appendingPathComponent(newFilename))
            throw error
        }
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

    private static func playlistGIFFilename(for artworkID: UUID) -> String {
        "playlist-\(artworkID.uuidString.lowercased()).gif"
    }

    private static func playlistCropFilename(for artworkID: UUID) -> String {
        "playlist-\(artworkID.uuidString.lowercased()).crop.json"
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

    static func animatedGIFImage(from data: Data) -> UIImage? {
        guard
            data.count <= maximumPlaylistGIFSize,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let typeIdentifier = CGImageSourceGetType(source),
            let type = UTType(typeIdentifier as String),
            type.conforms(to: .gif)
        else {
            return nil
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0, frameCount <= maximumSourceGIFFrames else {
            return nil
        }

        let retainedFrameCount = min(frameCount, maximumDecodedGIFFrames)
        let maximumPixelSize = min(
            Int(max(playlistOutputSize.width, bannerOutputSize.width)),
            Int(sqrt(Double(maximumDecodedGIFBytes) / (Double(retainedFrameCount) * 4)))
        )
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]

        var frames: [UIImage] = []
        var duration: TimeInterval = 0
        var decodedBytes = 0
        for index in 0..<frameCount {
            duration += gifFrameDuration(
                CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            )
        }
        for retainedIndex in 0..<retainedFrameCount {
            let index = retainedIndex * frameCount / retainedFrameCount
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                index,
                options as CFDictionary
            ) else {
                return nil
            }

            decodedBytes += image.width * image.height * 4
            guard decodedBytes <= maximumDecodedGIFBytes else {
                return nil
            }
            frames.append(UIImage(cgImage: image))
        }

        guard let firstFrame = frames.first else {
            return nil
        }
        guard frames.count > 1 else {
            return firstFrame
        }

        return UIImage.animatedImage(
            with: frames,
            duration: max(duration, 0.1 * Double(frames.count))
        )
    }

    private static func cachePlaylistCover(_ media: PlaylistCoverMedia, for artworkID: UUID) {
        let image: UIImage
        switch media {
        case .image(let value):
            image = value
        case .animatedGIF(let value, _):
            image = value
        }

        playlistCoverCache.setObject(
            PlaylistCoverCacheEntry(media),
            forKey: artworkID.uuidString.lowercased() as NSString,
            cost: decodedImageCost(image)
        )
    }

    private static func decodedImageCost(_ image: UIImage) -> Int {
        (image.images ?? [image]).reduce(0) { cost, frame in
            cost + (frame.cgImage?.width ?? Int(frame.size.width * frame.scale))
                * (frame.cgImage?.height ?? Int(frame.size.height * frame.scale)) * 4
        }
    }

    private static func cacheTrackCover(_ media: TrackCoverMedia, for coverID: UUID) {
        let image: UIImage
        switch media {
        case .image(let value), .animatedGIF(let value):
            image = value
        }
        trackCoverCache.setObject(
            TrackCoverCacheEntry(media),
            forKey: coverID.uuidString.lowercased() as NSString,
            cost: decodedImageCost(image)
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
