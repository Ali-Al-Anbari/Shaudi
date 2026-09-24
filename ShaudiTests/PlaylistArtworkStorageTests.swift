import ImageIO
import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import Shaudi

@MainActor
final class PlaylistArtworkStorageTests: XCTestCase {
    private var artworkIDs: [UUID] = []
    private var trackCoverIDs: [UUID] = []

    override func tearDown() {
        for artworkID in artworkIDs {
            ArtworkStorage.deletePlaylistImage(for: artworkID)
        }
        for coverID in trackCoverIDs {
            ArtworkStorage.deleteTrackCover(for: coverID)
        }
        ArtworkStorage.clearPlaylistCoverCache()
        ArtworkStorage.clearTrackCoverCache()
        artworkIDs = []
        trackCoverIDs = []
        super.tearDown()
    }

    func testStaticPlaylistCoverStillLoads() throws {
        let artworkID = makeArtworkID()
        try ArtworkStorage.savePlaylistImage(makeImage(color: .red), for: artworkID)

        XCTAssertNotNil(ArtworkStorage.playlistImage(for: artworkID))
        guard case .image = ArtworkStorage.playlistCover(for: artworkID) else {
            return XCTFail("Expected a static playlist cover")
        }
    }

    func testGIFTypeIsRecognizedFromImageMetadata() throws {
        XCTAssertTrue(ArtworkStorage.isGIFData(try makeGIFData()))
        XCTAssertFalse(ArtworkStorage.isGIFData(makeImage(color: .blue).pngData()!))
    }

    func testGIFBytesPersistAndSurviveCacheReload() throws {
        let artworkID = makeArtworkID()
        let data = try makeGIFData()
        try ArtworkStorage.savePlaylistGIF(data, for: artworkID)

        XCTAssertEqual(ArtworkStorage.playlistGIFData(for: artworkID), data)
        ArtworkStorage.clearPlaylistCoverCache()

        guard case .animatedGIF(let image, _) = ArtworkStorage.playlistCover(for: artworkID) else {
            return XCTFail("Expected a GIF after reloading from storage")
        }
        XCTAssertGreaterThan(image.images?.count ?? 0, 1)
    }

    func testReplacingStaticCoverWithGIFRemovesStaticFile() throws {
        let artworkID = makeArtworkID()
        try ArtworkStorage.savePlaylistImage(makeImage(color: .red), for: artworkID)
        try ArtworkStorage.savePlaylistGIF(try makeGIFData(), for: artworkID)

        XCTAssertNil(ArtworkStorage.playlistImage(for: artworkID))
        XCTAssertNotNil(ArtworkStorage.playlistGIFData(for: artworkID))
        guard case .animatedGIF = ArtworkStorage.playlistCover(for: artworkID) else {
            return XCTFail("Expected replacement GIF")
        }
    }

    func testReplacingGIFWithStaticCoverRemovesGIFFile() throws {
        let artworkID = makeArtworkID()
        try ArtworkStorage.savePlaylistGIF(try makeGIFData(), for: artworkID)
        try ArtworkStorage.savePlaylistImage(makeImage(color: .green), for: artworkID)

        XCTAssertNil(ArtworkStorage.playlistGIFData(for: artworkID))
        XCTAssertNotNil(ArtworkStorage.playlistImage(for: artworkID))
        guard case .image = ArtworkStorage.playlistCover(for: artworkID) else {
            return XCTFail("Expected replacement static cover")
        }
    }

    func testResetRemovesStaticAndGIFStorage() throws {
        let staticID = makeArtworkID()
        let gifID = makeArtworkID()
        try ArtworkStorage.savePlaylistImage(makeImage(color: .red), for: staticID)
        try ArtworkStorage.savePlaylistGIF(try makeGIFData(), for: gifID)

        ArtworkStorage.deletePlaylistImage(for: staticID)
        ArtworkStorage.deletePlaylistImage(for: gifID)

        XCTAssertNil(ArtworkStorage.playlistCover(for: staticID))
        XCTAssertNil(ArtworkStorage.playlistCover(for: gifID))
        XCTAssertNil(ArtworkStorage.playlistGIFData(for: gifID))
    }

    func testCorruptAndMissingGIFFallBackSafely() throws {
        let artworkID = makeArtworkID()
        let corruptData = Data("not a gif".utf8)

        XCTAssertThrowsError(try ArtworkStorage.savePlaylistGIF(corruptData, for: artworkID))
        XCTAssertNil(ArtworkStorage.playlistCover(for: artworkID))
    }

    func testFailedPlaylistGIFReplacementKeepsStaticCoverCached() throws {
        let artworkID = makeArtworkID()
        try ArtworkStorage.savePlaylistImage(makeImage(color: .red), for: artworkID)
        guard case .image(let original) = ArtworkStorage.playlistCover(for: artworkID) else {
            return XCTFail("Expected original cover")
        }

        XCTAssertThrowsError(try ArtworkStorage.savePlaylistGIF(Data("GIFbad".utf8), for: artworkID))
        guard case .image(let retained) = ArtworkStorage.playlistCover(for: artworkID) else {
            return XCTFail("Expected retained cover")
        }
        XCTAssertTrue(original === retained)
        ArtworkStorage.clearPlaylistCoverCache()
        XCTAssertNotNil(ArtworkStorage.playlistImage(for: artworkID))
    }

    func testSingleFrameGIFLoadsAsAStaticRepresentation() throws {
        let artworkID = makeArtworkID()
        try ArtworkStorage.savePlaylistGIF(try makeGIFData(frameCount: 1), for: artworkID)

        guard case .animatedGIF(let image, _) = ArtworkStorage.playlistCover(for: artworkID) else {
            return XCTFail("Expected stored GIF media")
        }
        XCTAssertNil(image.images)
    }

    func testOversizedGIFReportsTheSizeLimit() {
        let artworkID = makeArtworkID()
        let data = Data(count: ArtworkStorage.maximumPlaylistGIFSize + 1)

        XCTAssertThrowsError(try ArtworkStorage.savePlaylistGIF(data, for: artworkID)) { error in
            guard case ArtworkStorageError.gifTooLarge = error else {
                return XCTFail("Expected the GIF size-limit error")
            }
        }
    }

    func testFailedTrackReplacementPreservesStaticCoverAndCache() throws {
        let coverID = makeTrackCoverID()
        try ArtworkStorage.saveTrackCover(data: makeImage(color: .red).pngData()!, for: coverID)
        guard case .image(let original) = ArtworkStorage.trackCover(for: coverID) else {
            return XCTFail("Expected original cover")
        }

        XCTAssertThrowsError(try ArtworkStorage.saveTrackCover(data: Data("GIFbad".utf8), for: coverID))
        XCTAssertThrowsError(try ArtworkStorage.saveTrackCover(data: Data("bad image".utf8), for: coverID))
        guard case .image(let retained) = ArtworkStorage.trackCover(for: coverID) else {
            return XCTFail("Expected retained cover")
        }
        XCTAssertTrue(original === retained)
    }

    func testFailedGIFWritePreservesOldStaticCover() throws {
        let coverID = makeTrackCoverID()
        try ArtworkStorage.saveTrackCover(data: makeImage(color: .red).pngData()!, for: coverID)
        let gifURL = trackGIFURL(for: coverID)
        try FileManager.default.createDirectory(at: gifURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: gifURL) }

        XCTAssertThrowsError(try ArtworkStorage.saveTrackCover(data: try makeGIFData(), for: coverID))
        guard case .image = ArtworkStorage.trackCover(for: coverID) else {
            return XCTFail("Expected old cover after failed write")
        }
        ArtworkStorage.clearTrackCoverCache()
        guard case .image = ArtworkStorage.trackCover(for: coverID) else {
            return XCTFail("Expected old cover to remain on disk")
        }
    }

    func testFailedGIFReplacementPreservesOldGIFAndCache() throws {
        let coverID = makeTrackCoverID()
        try ArtworkStorage.saveTrackCover(data: try makeGIFData(), for: coverID)
        guard case .animatedGIF(let original) = ArtworkStorage.trackCover(for: coverID) else {
            return XCTFail("Expected original GIF")
        }

        XCTAssertThrowsError(try ArtworkStorage.saveTrackCover(data: Data("GIFbad".utf8), for: coverID))
        guard case .animatedGIF(let retained) = ArtworkStorage.trackCover(for: coverID) else {
            return XCTFail("Expected retained GIF")
        }
        XCTAssertTrue(original === retained)
        ArtworkStorage.clearTrackCoverCache()
        guard case .animatedGIF = ArtworkStorage.trackCover(for: coverID) else {
            return XCTFail("Expected original GIF on disk")
        }
    }

    func testStaticToStaticTrackReplacement() throws {
        let coverID = makeTrackCoverID()
        try ArtworkStorage.saveTrackCover(data: makeImage(color: .red).pngData()!, for: coverID)
        try ArtworkStorage.saveTrackCover(data: makeImage(color: .blue).pngData()!, for: coverID)
        ArtworkStorage.clearTrackCoverCache()
        guard case .image(let image) = ArtworkStorage.trackCover(for: coverID) else {
            return XCTFail("Expected static cover")
        }
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trackGIFURL(for: coverID).path))
    }

    func testTrackCoverFormatTransitionsAndCacheReplacement() throws {
        let coverID = makeTrackCoverID()
        try ArtworkStorage.saveTrackCover(data: makeImage(color: .red).pngData()!, for: coverID)
        guard case .image(let original) = ArtworkStorage.trackCover(for: coverID) else {
            return XCTFail("Expected static cover")
        }

        try ArtworkStorage.saveTrackCover(data: try makeGIFData(), for: coverID)
        guard case .animatedGIF(let firstGIF) = ArtworkStorage.trackCover(for: coverID) else {
            return XCTFail("Expected GIF cover")
        }
        XCTAssertGreaterThan(firstGIF.images?.count ?? 0, 1)
        XCTAssertFalse(original === firstGIF)

        try ArtworkStorage.saveTrackCover(data: try makeGIFData(frameCount: 3), for: coverID)
        guard case .animatedGIF(let secondGIF) = ArtworkStorage.trackCover(for: coverID) else {
            return XCTFail("Expected replacement GIF")
        }
        XCTAssertFalse(firstGIF === secondGIF)
        XCTAssertEqual(secondGIF.images?.count, 3)

        try ArtworkStorage.saveTrackCover(data: makeImage(color: .blue).pngData()!, for: coverID)
        guard case .image = ArtworkStorage.trackCover(for: coverID) else {
            return XCTFail("Expected replacement static cover")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: trackGIFURL(for: coverID).path))
        ArtworkStorage.clearTrackCoverCache()
        guard case .image = ArtworkStorage.trackCover(for: coverID) else {
            return XCTFail("Expected static cover after cache reload")
        }
    }

    func testTrackAndPlaylistGIFsUseBoundedFrames() throws {
        let data = try makeGIFData(frameCount: 150, size: CGSize(width: 8, height: 8))
        let coverID = makeTrackCoverID()
        let artworkID = makeArtworkID()
        try ArtworkStorage.saveTrackCover(data: data, for: coverID)
        try ArtworkStorage.savePlaylistGIF(data, for: artworkID)

        guard case .animatedGIF(let trackImage) = ArtworkStorage.trackCover(for: coverID),
              case .animatedGIF(let playlistImage, _) = ArtworkStorage.playlistCover(for: artworkID) else {
            return XCTFail("Expected animated covers")
        }
        for image in [trackImage, playlistImage] {
            let frames = image.images ?? [image]
            XCTAssertEqual(frames.count, ArtworkStorage.maximumDecodedGIFFrames)
            let decodedBytes = frames.reduce(0) { $0 + ($1.cgImage?.width ?? 0) * ($1.cgImage?.height ?? 0) * 4 }
            XCTAssertLessThanOrEqual(decodedBytes, ArtworkStorage.maximumDecodedGIFBytes)
        }
    }

    func testLargeSourceGIFIsDownsampledForTrackAndPlaylist() throws {
        let data = try makeGIFData(frameCount: 2, size: CGSize(width: 2_048, height: 2_048))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let firstFrame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(firstFrame.width, 2_048)
        XCTAssertEqual(firstFrame.height, 2_048)
        let coverID = makeTrackCoverID()
        let artworkID = makeArtworkID()
        try ArtworkStorage.saveTrackCover(data: data, for: coverID)
        try ArtworkStorage.savePlaylistGIF(data, for: artworkID)

        guard case .animatedGIF(let trackImage) = ArtworkStorage.trackCover(for: coverID),
              case .animatedGIF(let playlistImage, _) = ArtworkStorage.playlistCover(for: artworkID) else {
            return XCTFail("Expected animated covers")
        }
        for image in [trackImage, playlistImage] {
            XCTAssertLessThanOrEqual(image.images?.first?.cgImage?.width ?? 0, Int(ArtworkStorage.playlistOutputSize.width))
        }
    }

    func testGIFToGIFReplacementInvalidatesStaleCacheAndCrop() throws {
        let artworkID = makeArtworkID()
        let firstData = try makeGIFData(frameCount: 2)
        let firstCrop = ArtworkCrop(scale: 1.5, normalizedOffsetX: 0.1, normalizedOffsetY: 0.2)
        try ArtworkStorage.savePlaylistGIF(firstData, crop: firstCrop, for: artworkID)

        guard case .animatedGIF(_, let loadedFirstCrop) = ArtworkStorage.playlistCover(for: artworkID) else {
            return XCTFail("Expected first GIF cover")
        }
        XCTAssertEqual(loadedFirstCrop, firstCrop)

        let secondData = try makeGIFData(frameCount: 3)
        let secondCrop = ArtworkCrop(scale: 2.0, normalizedOffsetX: -0.2, normalizedOffsetY: 0.3)
        try ArtworkStorage.savePlaylistGIF(secondData, crop: secondCrop, for: artworkID)

        guard case .animatedGIF(let secondImage, let loadedSecondCrop) = ArtworkStorage.playlistCover(for: artworkID) else {
            return XCTFail("Expected second GIF cover")
        }
        XCTAssertEqual(secondImage.images?.count, 3)
        XCTAssertEqual(loadedSecondCrop, secondCrop)

        ArtworkStorage.clearPlaylistCoverCache()
        guard case .animatedGIF(let reloadedImage, let reloadedCrop) = ArtworkStorage.playlistCover(for: artworkID) else {
            return XCTFail("Expected second GIF cover after cache reload")
        }
        XCTAssertEqual(reloadedImage.images?.count, 3)
        XCTAssertEqual(reloadedCrop, secondCrop)
    }

    func testCropMetadataSurvivesPersistence() throws {
        let artworkID = makeArtworkID()
        let data = try makeGIFData()
        let crop = ArtworkCrop(scale: 2.5, normalizedOffsetX: 0.35, normalizedOffsetY: -0.25)
        try ArtworkStorage.savePlaylistGIF(data, crop: crop, for: artworkID)

        ArtworkStorage.clearPlaylistCoverCache()
        guard case .animatedGIF(_, let loadedCrop) = ArtworkStorage.playlistCover(for: artworkID) else {
            return XCTFail("Expected GIF cover")
        }
        XCTAssertEqual(loadedCrop.scale, 2.5)
        XCTAssertEqual(loadedCrop.normalizedOffsetX, 0.35)
        XCTAssertEqual(loadedCrop.normalizedOffsetY, -0.25)
    }

    func testCropValuesAreDeviceIndependent() {
        let crop = ArtworkCrop(scale: 1.5, normalizedOffsetX: 0.2, normalizedOffsetY: 0.0)
        let imageSize = CGSize(width: 800, height: 400)

        let viewportSmall = CGSize(width: 40, height: 40)
        let baseWidthSmall = viewportSmall.height * (imageSize.width / imageSize.height)
        let scaledWidthSmall = baseWidthSmall * crop.scale
        let offsetSmall = crop.normalizedOffsetX * viewportSmall.width
        let leftSmall = (scaledWidthSmall - viewportSmall.width) / 2 - offsetSmall
        let fractionLeftSmall = leftSmall / scaledWidthSmall

        let viewportLarge = CGSize(width: 200, height: 200)
        let baseWidthLarge = viewportLarge.height * (imageSize.width / imageSize.height)
        let scaledWidthLarge = baseWidthLarge * crop.scale
        let offsetLarge = crop.normalizedOffsetX * viewportLarge.width
        let leftLarge = (scaledWidthLarge - viewportLarge.width) / 2 - offsetLarge
        let fractionLeftLarge = leftLarge / scaledWidthLarge

        XCTAssertEqual(fractionLeftSmall, fractionLeftLarge, accuracy: 0.0001)
    }

    func testSavePlaylistImageRemovesObsoleteCrop() throws {
        let artworkID = makeArtworkID()
        let gifData = try makeGIFData()
        let crop = ArtworkCrop(scale: 1.8, normalizedOffsetX: 0.1, normalizedOffsetY: 0.1)
        try ArtworkStorage.savePlaylistGIF(gifData, crop: crop, for: artworkID)
        XCTAssertNotNil(ArtworkStorage.playlistCrop(for: artworkID))

        try ArtworkStorage.savePlaylistImage(makeImage(color: .purple), for: artworkID)
        XCTAssertNil(ArtworkStorage.playlistCrop(for: artworkID))
        guard case .image = ArtworkStorage.playlistCover(for: artworkID) else {
            return XCTFail("Expected static image cover")
        }
    }

    func testMalformedCropFileFallsBackToDefault() throws {
        let artworkID = makeArtworkID()
        let gifData = try makeGIFData()
        try ArtworkStorage.savePlaylistGIF(gifData, for: artworkID)

        let cropURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artwork", isDirectory: true)
            .appendingPathComponent("playlist-\(artworkID.uuidString.lowercased()).crop.json")
        try Data("corrupted json".utf8).write(to: cropURL)

        ArtworkStorage.clearPlaylistCoverCache()
        guard case .animatedGIF(_, let fallbackCrop) = ArtworkStorage.playlistCover(for: artworkID) else {
            return XCTFail("Expected GIF cover")
        }
        XCTAssertEqual(fallbackCrop, ArtworkCrop.default)
    }

    private func makeTrackCoverID() -> UUID {
        let coverID = UUID()
        trackCoverIDs.append(coverID)
        return coverID
    }

    private func trackGIFURL(for coverID: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artwork", isDirectory: true)
            .appendingPathComponent("track-cover-\(coverID.uuidString.lowercased()).gif")
    }

    private func makeArtworkID() -> UUID {
        let artworkID = UUID()
        artworkIDs.append(artworkID)
        return artworkID
    }

    private func makeImage(color: UIColor, size: CGSize = CGSize(width: 4, height: 4)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // GIF fixtures use pixel dimensions, independent of device screen scale.
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func makeGIFData(frameCount: Int = 2, size: CGSize = CGSize(width: 4, height: 4)) throws -> Data {
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
