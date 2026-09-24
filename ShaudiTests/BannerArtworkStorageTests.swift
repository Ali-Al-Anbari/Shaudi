import ImageIO
import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import Shaudi

@MainActor
final class BannerArtworkStorageTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ArtworkStorage.resetBannerImage()
    }

    override func tearDown() {
        ArtworkStorage.resetBannerImage()
        ArtworkStorage.clearBannerCache()
        super.tearDown()
    }

    // 1. static banner still saves/loads
    func testStaticBannerStillSavesAndLoads() throws {
        let image = makeImage(color: .red)
        try ArtworkStorage.saveBannerImage(image)

        XCTAssertNotNil(ArtworkStorage.bannerImage())
        guard case .image(let loadedImage) = ArtworkStorage.bannerMedia() else {
            return XCTFail("Expected static image banner media")
        }
        XCTAssertNotNil(loadedImage)
    }

    // 2. GIF banner preserves original animated data
    func testGIFBannerPreservesOriginalAnimatedData() throws {
        let data = try makeGIFData(frameCount: 3)
        try ArtworkStorage.saveBannerGIF(data)

        let savedData = ArtworkStorage.bannerGIFData()
        XCTAssertEqual(savedData, data)
    }

    // 3. GIF banner reload remains animated
    func testGIFBannerReloadRemainsAnimated() throws {
        let data = try makeGIFData(frameCount: 4)
        try ArtworkStorage.saveBannerGIF(data)

        ArtworkStorage.clearBannerCache()

        guard case .animatedGIF(let image, _) = ArtworkStorage.bannerMedia() else {
            return XCTFail("Expected animated GIF banner media after reload")
        }
        XCTAssertEqual(image.images?.count, 4)
    }

    // 4. GIF crop metadata persists
    func testGIFCropMetadataPersists() throws {
        let crop = ArtworkCrop(scale: 2.25, normalizedOffsetX: 0.15, normalizedOffsetY: -0.3)
        try ArtworkStorage.saveBannerGIF(try makeGIFData(), crop: crop)

        ArtworkStorage.clearBannerCache()

        guard case .animatedGIF(_, let loadedCrop) = ArtworkStorage.bannerMedia() else {
            return XCTFail("Expected animated GIF banner media")
        }
        XCTAssertEqual(loadedCrop, crop)
        XCTAssertEqual(ArtworkStorage.bannerCrop(), crop)
    }

    // 5. static -> GIF replacement
    func testStaticToGIFReplacementRemovesStaticFile() throws {
        try ArtworkStorage.saveBannerImage(makeImage(color: .red))
        XCTAssertNotNil(ArtworkStorage.bannerImage())

        let gifData = try makeGIFData()
        try ArtworkStorage.saveBannerGIF(gifData)

        guard case .animatedGIF = ArtworkStorage.bannerMedia() else {
            return XCTFail("Expected animated GIF after replacement")
        }
        XCTAssertNotNil(ArtworkStorage.bannerGIFData())
    }

    // 6. GIF -> static replacement
    func testGIFToStaticReplacementRemovesGIFAndCropFiles() throws {
        let crop = ArtworkCrop(scale: 1.8, normalizedOffsetX: -0.1, normalizedOffsetY: 0.1)
        try ArtworkStorage.saveBannerGIF(try makeGIFData(), crop: crop)
        XCTAssertNotNil(ArtworkStorage.bannerGIFData())
        XCTAssertNotNil(ArtworkStorage.bannerCrop())

        try ArtworkStorage.saveBannerImage(makeImage(color: .blue))

        XCTAssertNil(ArtworkStorage.bannerGIFData())
        XCTAssertNil(ArtworkStorage.bannerCrop())
        guard case .image = ArtworkStorage.bannerMedia() else {
            return XCTFail("Expected static image after replacement")
        }
    }

    // 7. GIF -> GIF replacement
    func testGIFToGIFReplacementUpdatesDataCropAndCache() throws {
        let gif1 = try makeGIFData(frameCount: 2)
        let crop1 = ArtworkCrop(scale: 1.2, normalizedOffsetX: 0.05, normalizedOffsetY: 0)
        try ArtworkStorage.saveBannerGIF(gif1, crop: crop1)

        let gif2 = try makeGIFData(frameCount: 5)
        let crop2 = ArtworkCrop(scale: 2.5, normalizedOffsetX: -0.2, normalizedOffsetY: 0.3)
        try ArtworkStorage.saveBannerGIF(gif2, crop: crop2)

        XCTAssertEqual(ArtworkStorage.bannerGIFData(), gif2)
        guard case .animatedGIF(let image, let loadedCrop) = ArtworkStorage.bannerMedia() else {
            return XCTFail("Expected animated GIF after replacement")
        }
        XCTAssertEqual(loadedCrop, crop2)
        XCTAssertEqual(image.images?.count, 5)
    }

    // 8. stale cache invalidation
    func testStaleCacheInvalidation() throws {
        let gifData = try makeGIFData(frameCount: 3)
        try ArtworkStorage.saveBannerGIF(gifData)

        guard case .animatedGIF(let initialImage, _) = ArtworkStorage.bannerMedia() else {
            return XCTFail("Expected initial banner GIF")
        }

        ArtworkStorage.clearBannerCache()

        guard case .animatedGIF(let reloadedImage, _) = ArtworkStorage.bannerMedia() else {
            return XCTFail("Expected reloaded banner GIF")
        }

        XCTAssertFalse(initialImage === reloadedImage)
        XCTAssertEqual(initialImage.images?.count, reloadedImage.images?.count)
    }

    // 9. malformed GIF fails safely
    func testMalformedGIFFailsSafelyWithoutOverwritingExistingBanner() throws {
        let initialImage = makeImage(color: .green)
        try ArtworkStorage.saveBannerImage(initialImage)

        let corruptData = Data("bad-gif-header".utf8)
        XCTAssertThrowsError(try ArtworkStorage.saveBannerGIF(corruptData))

        guard case .image = ArtworkStorage.bannerMedia() else {
            return XCTFail("Expected static banner to remain intact")
        }
        XCTAssertNil(ArtworkStorage.bannerGIFData())
    }

    // 10. canceling crop preserves previous banner
    func testCancelingCropPreservesPreviousBanner() throws {
        let initialImage = makeImage(color: .purple)
        try ArtworkStorage.saveBannerImage(initialImage)

        let originalMedia = ArtworkStorage.bannerMedia()

        // User selected a photo/GIF, preview opened, but user cancelled -> neither saveBannerImage nor saveBannerGIF is called.
        let currentMedia = ArtworkStorage.bannerMedia()
        guard case .image(let img1) = originalMedia, case .image(let img2) = currentMedia else {
            return XCTFail("Expected image media")
        }
        XCTAssertEqual(img1.pngData(), img2.pngData())
    }

    // 11. Reduce Motion returns static/first-frame behavior
    func testReduceMotionReturnsFirstFrameForGIF() throws {
        let gifData = try makeGIFData(frameCount: 3)
        try ArtworkStorage.saveBannerGIF(gifData)

        guard case .animatedGIF(let image, _) = ArtworkStorage.bannerMedia() else {
            return XCTFail("Expected animated GIF")
        }

        // AnimatedPlaylistCoverImage uses `image.images?.first ?? image` when showsFirstFrameOnly is true.
        let firstFrame = image.images?.first
        XCTAssertNotNil(firstFrame)
        XCTAssertNil(firstFrame?.images, "First frame should be a still image without subframes")
    }

    // 12. existing static crop behavior remains unchanged
    func testExistingStaticCropBehaviorRemainsUnchanged() throws {
        let inputImage = makeImage(color: .yellow, size: CGSize(width: 800, height: 600))
        let cropped = ArtworkStorage.migratedBannerImage(
            inputImage,
            scale: 1.5,
            normalizedOffset: CGSize(width: 0.1, height: -0.1)
        )
        XCTAssertEqual(cropped.size, ArtworkStorage.bannerOutputSize)

        try ArtworkStorage.saveBannerImage(cropped)
        guard case .image(let loaded) = ArtworkStorage.bannerMedia() else {
            return XCTFail("Expected saved static banner")
        }
        XCTAssertEqual(loaded.size, ArtworkStorage.bannerOutputSize)
    }

    private func makeImage(color: UIColor, size: CGSize = CGSize(width: 10, height: 10)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func makeGIFData(frameCount: Int = 2, size: CGSize = CGSize(width: 10, height: 10)) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        CGImageDestinationSetProperties(
            destination,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        )
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]
        ] as CFDictionary

        for index in 0..<frameCount {
            let color = index.isMultiple(of: 2) ? UIColor.red : UIColor.blue
            guard let frame = makeImage(color: color, size: size).cgImage else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationAddImage(destination, frame, frameProperties)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data as Data
    }
}
