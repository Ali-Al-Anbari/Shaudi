import ImageIO
import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import Shaudi

@MainActor
final class PlaylistArtworkStorageTests: XCTestCase {
    private var artworkIDs: [UUID] = []

    override func tearDown() {
        for artworkID in artworkIDs {
            ArtworkStorage.deletePlaylistImage(for: artworkID)
        }
        ArtworkStorage.clearPlaylistCoverCache()
        artworkIDs = []
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

        guard case .animatedGIF(let image) = ArtworkStorage.playlistCover(for: artworkID) else {
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

    func testSingleFrameGIFLoadsAsAStaticRepresentation() throws {
        let artworkID = makeArtworkID()
        try ArtworkStorage.savePlaylistGIF(try makeGIFData(frameCount: 1), for: artworkID)

        guard case .animatedGIF(let image) = ArtworkStorage.playlistCover(for: artworkID) else {
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

    private func makeArtworkID() -> UUID {
        let artworkID = UUID()
        artworkIDs.append(artworkID)
        return artworkID
    }

    private func makeImage(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    private func makeGIFData(frameCount: Int = 2) throws -> Data {
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
            guard let frame = makeImage(color: color).cgImage else {
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
