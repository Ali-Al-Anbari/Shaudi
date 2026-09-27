import XCTest
@testable import Shaudi

@MainActor
final class YouTubeArtworkTests: XCTestCase {
    private let videoID = "abcdefghijk"

    func testCandidatesUpgradeSavedThumbnailWithoutMetadataRequest() {
        let saved = URL(string: "https://i.ytimg.com/vi/abcdefghijk/default.jpg")!
        XCTAssertEqual(
            YouTubeArtwork.candidates(videoID: videoID, fallback: saved).map(\.lastPathComponent),
            ["maxresdefault.jpg", "sddefault.jpg", "hqdefault.jpg", "default.jpg"]
        )
        XCTAssertTrue(YouTubeArtwork.candidates(videoID: videoID, fallback: saved)
            .allSatisfy { $0.host == "i.ytimg.com" })
    }

    func testMissingAndPlaceholderMaxresFallsBackAndCachesFullSource() async {
        let small = imageData(width: 120, height: 90)
        let standard = imageData(width: 640, height: 480)
        let calls = CallCounter()
        let artwork = YouTubeArtwork { url in
            await calls.add(url.lastPathComponent)
            let data = url.lastPathComponent == "sddefault.jpg" ? standard : small
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let first = await artwork.image(videoID: videoID, fallback: nil)
        XCTAssertEqual(first?.cgImage?.width, 640)
        let second = await artwork.image(videoID: videoID, fallback: nil)
        XCTAssertEqual(second?.cgImage?.width, 640)
        let requested = await calls.values
        XCTAssertEqual(requested, ["maxresdefault.jpg", "sddefault.jpg"])
    }

    func testHTTPFailureFallsBackToSavedArtwork() async {
        let saved = URL(string: "https://example.com/saved.jpg")!
        let fallbackData = imageData(width: 320, height: 180)
        let artwork = YouTubeArtwork { url in
            let status = url == saved ? 200 : 404
            return (fallbackData, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let image = await artwork.image(videoID: videoID, fallback: saved)
        XCTAssertEqual(image?.cgImage?.width, 320)
    }

    func testInvalidImageFallsBackToSavedArtwork() async {
        let saved = URL(string: "https://example.com/saved.jpg")!
        let fallbackData = imageData(width: 320, height: 180)
        let artwork = YouTubeArtwork { url in
            let data = url == saved ? fallbackData : Data("not an image".utf8)
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let image = await artwork.image(videoID: videoID, fallback: saved)
        XCTAssertEqual(image?.cgImage?.width, 320)
    }

    func testSmallRequestCannotPoisonFullSizeCache() async {
        let large = imageData(width: 1_280, height: 720)
        let calls = CallCounter()
        let artwork = YouTubeArtwork { url in
            await calls.add(url.lastPathComponent)
            return (large, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let rowImage = await artwork.image(videoID: videoID, fallback: nil)
        let playerImage = await artwork.image(videoID: videoID, fallback: nil)
        XCTAssertEqual(rowImage?.cgImage?.width, 1_280)
        XCTAssertEqual(playerImage?.cgImage?.width, 1_280)
        let requested = await calls.values
        XCTAssertEqual(requested, ["maxresdefault.jpg"])
    }

    private func imageData(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
}

private actor CallCounter {
    private(set) var values: [String] = []
    func add(_ value: String) {
        values.append(value)
    }
}
