//
//  YouTubeStructuredSearchTests.swift
//  ShaudiTests
//

import XCTest
@testable import Shaudi

@MainActor
final class YouTubeStructuredSearchTests: XCTestCase {
    func testStructuredSearchDecodesTypedMusicCandidateFixture() throws {
        let candidates = try YouTubeStructuredSearchClient.candidates(
            from: structuredSearchFixtureData()
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.videoID, "struct00001")
        XCTAssertEqual(candidates.first?.title, "Example Song")
        XCTAssertEqual(candidates.first?.artistOrChannel, "Example Artist")
        XCTAssertEqual(candidates.first?.duration, 225)
        XCTAssertEqual(candidates.first?.resultType, .song)
    }

    func testSearchPreResolutionLimitsToFirstThreeUniquePlayableResults() {
        let results = (0..<10).map { index in
            YouTubeSearchResult(
                youtubeVideoID: index == 1 ? "search00000" : String(format: "s%010d", index),
                title: "Song \(index)",
                channelTitle: "Artist",
                thumbnailURL: nil,
                duration: TimeInterval(180 + index)
            )
        }

        let candidates = SearchPreResolutionPlan.candidates(from: results)

        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates.map(\.videoID), ["s0000000000", "search00000", "s0000000002"])
        XCTAssertEqual(candidates.map(\.rank), [1, 2, 3])
    }

    func testSearchPreResolutionSkipsBlankAndDuplicateVideoIDs() {
        let results = [
            YouTubeSearchResult(
                youtubeVideoID: "   ",
                title: "Blank",
                channelTitle: "Artist",
                thumbnailURL: nil
            ),
            YouTubeSearchResult(
                youtubeVideoID: "shared00001",
                title: "First",
                channelTitle: "Artist",
                thumbnailURL: nil
            ),
            YouTubeSearchResult(
                youtubeVideoID: " shared00001 ",
                title: "Duplicate",
                channelTitle: "Artist",
                thumbnailURL: nil
            ),
            YouTubeSearchResult(
                youtubeVideoID: "second00001",
                title: "Second",
                channelTitle: "Artist",
                thumbnailURL: nil
            )
        ]

        let candidates = SearchPreResolutionPlan.candidates(from: results)

        XCTAssertEqual(candidates.map(\.videoID), ["shared00001", "second00001"])
    }

    func testSearchPreResolutionQueryReplacementPreservesPromotedAndActivePlayback() {
        let obsolete = SearchPreResolutionPlan.obsoleteVideoIDs(
            previous: ["old00000001", "promoted001", "playing0001", "shared00001"],
            retaining: ["shared00001", "new00000001"],
            nonSpeculative: ["promoted001"],
            activePlayback: ["playing0001"]
        )

        XCTAssertEqual(obsolete, ["old00000001"])
    }

    func testStructuredClientUsesTypedPOSTRequestWithoutLiveNetwork() async throws {
        var capturedRequest: URLRequest?
        let responseURL = try XCTUnwrap(URL(string: "https://music.youtube.com"))
        let client = YouTubeStructuredSearchClient { request in
            capturedRequest = request
            return (
                self.structuredSearchFixtureData(),
                HTTPURLResponse(
                    url: responseURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        let candidates = try await client.search(query: "Example Artist Example Song")

        XCTAssertEqual(candidates.first?.videoID, "struct00001")
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.url?.host, "music.youtube.com")
        XCTAssertEqual(
            capturedRequest?.value(forHTTPHeaderField: "Origin"),
            "https://music.youtube.com"
        )
        let bodyData = try XCTUnwrap(capturedRequest?.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        XCTAssertEqual(body["params"] as? String, "EgWKAQIIAWoMEA4QChADEAQQCRAF")
        let context = try XCTUnwrap(body["context"] as? [String: Any])
        let requestClient = try XCTUnwrap(context["client"] as? [String: Any])
        XCTAssertEqual(requestClient["clientName"] as? String, "WEB_REMIX")
        XCTAssertEqual(requestClient["clientVersion"] as? String, "1.20231204.01.00")
    }

    func testStructuredParserFindsPlayableMusicCardShelfTopResult() throws {
        let data = try structuredFixture(
            contents: [
                "musicCardShelfRenderer": structuredCard(
                    videoID: "cardtop0001",
                    title: "Basket Case",
                    artist: "Green Day"
                )
            ]
        )

        let parsed = try YouTubeStructuredSearchClient.parse(data)

        XCTAssertEqual(parsed.diagnostics.cardShelves, 1)
        XCTAssertEqual(parsed.candidates.first?.videoID, "cardtop0001")
        XCTAssertEqual(parsed.candidates.first?.artistOrChannel, "Green Day")
    }

    func testStructuredParserFindsResponsiveRowInsideItemSection() throws {
        let data = try structuredFixture(
            contents: [
                "itemSectionRenderer": [
                    "contents": [[
                        "musicResponsiveListItemRenderer": structuredRow(
                            videoID: "itemsect001",
                            placement: .navigation,
                            title: "Jaded",
                            artist: "Green Day"
                        )
                    ]]
                ]
            ]
        )

        let parsed = try YouTubeStructuredSearchClient.parse(data)

        XCTAssertEqual(parsed.diagnostics.itemSections, 1)
        XCTAssertEqual(parsed.diagnostics.responsiveRows, 1)
        XCTAssertEqual(parsed.candidates.first?.videoID, "itemsect001")
    }

    func testStructuredParserFindsDirectMusicShelf() throws {
        let data = try structuredFixture(
            contents: [
                "musicShelfRenderer": [
                    "contents": [[
                        "musicResponsiveListItemRenderer": structuredRow(
                            videoID: "shelfdir001",
                            placement: .playlistItemData,
                            title: "Fat Lip",
                            artist: "Sum 41"
                        )
                    ]]
                ]
            ]
        )

        let parsed = try YouTubeStructuredSearchClient.parse(data)

        XCTAssertEqual(parsed.diagnostics.musicShelves, 1)
        XCTAssertEqual(parsed.candidates.first?.videoID, "shelfdir001")
    }

    func testStructuredParserExtractsAllDocumentedVideoIDPaths() throws {
        let placements: [(StructuredVideoIDPlacement, String)] = [
            (.playlistItemData, "playlist001"),
            (.navigation, "navpath0001"),
            (.flexColumn, "flexpath001"),
            (.overlay, "overlay0001")
        ]

        for (placement, videoID) in placements {
            let data = try structuredFixture(
                contents: [
                    "musicShelfRenderer": [
                        "contents": [[
                            "musicResponsiveListItemRenderer": structuredRow(
                                videoID: videoID,
                                placement: placement,
                                title: "Ocean Avenue",
                                artist: "Yellowcard"
                            )
                        ]]
                    ]
                ]
            )

            let candidates = try YouTubeStructuredSearchClient.candidates(from: data)
            XCTAssertEqual(candidates.first?.videoID, videoID, "placement=\(placement)")
        }
    }

    func testStructuredParserDeduplicatesVideoIDs() throws {
        let first = structuredRow(
            videoID: "duplicate01",
            placement: .playlistItemData,
            title: "All the Small Things",
            artist: "blink-182"
        )
        let duplicate = structuredRow(
            videoID: "duplicate01",
            placement: .overlay,
            title: "All the Small Things",
            artist: "blink-182"
        )
        let data = try structuredFixture(
            contents: [
                "itemSectionRenderer": [
                    "contents": [
                        ["musicResponsiveListItemRenderer": first],
                        ["musicResponsiveListItemRenderer": duplicate]
                    ]
                ]
            ]
        )

        let candidates = try YouTubeStructuredSearchClient.candidates(from: data)

        XCTAssertEqual(candidates.map(\.videoID), ["duplicate01"])
    }

    func testFamousStructuredSongCandidateReachesExistingScoring() throws {
        let data = try structuredFixture(
            contents: [
                "musicCardShelfRenderer": structuredCard(
                    videoID: "basketcase1",
                    title: "Basket Case",
                    artist: "Green Day"
                )
            ]
        )
        let result = try XCTUnwrap(
            YouTubeStructuredSearchClient.candidates(from: data).first?.searchResult
        )

        let score = RecommendationService().youtubeScore(
            result,
            target: candidate("Green Day", "Basket Case")
        )

        XCTAssertNotNil(score)
    }

    func testNormalStudioCandidateBeatsRejectedVariants() async throws {
        let target = candidate("Green Day", "Basket Case")
        let results = [
            YouTubeSearchResult(
                youtubeVideoID: "livevers001",
                title: "Green Day - Basket Case (Live)",
                channelTitle: "Green Day",
                thumbnailURL: nil
            ),
            YouTubeSearchResult(
                youtubeVideoID: "slowedver01",
                title: "Green Day - Basket Case (Slowed)",
                channelTitle: "Green Day",
                thumbnailURL: nil
            ),
            YouTubeSearchResult(
                youtubeVideoID: "basketcase1",
                title: "Basket Case",
                channelTitle: "Green Day - Topic",
                thumbnailURL: nil
            )
        ]
        let service = RecommendationService(
            similarTracks: { _, _, _ in [] },
            videoResolver: YouTubeRecommendationResolver(
                primarySearch: { _ in results },
                dataAPISearch: { _ in [] }
            ),
            resolutionCache: MemoryYouTubeResolutionCache()
        )

        let resolved = try await service.resolveOnYouTube(target)

        XCTAssertEqual(resolved?.youtubeResult.youtubeVideoID, "basketcase1")
    }

    func testStructuredParserReturnsCleanMissForValidEmptyResponse() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "contents": [
                "tabbedSearchResultsRenderer": ["tabs": []]
            ]
        ])

        let parsed = try YouTubeStructuredSearchClient.parse(data)

        XCTAssertTrue(parsed.candidates.isEmpty)
        XCTAssertEqual(parsed.diagnostics, .init())
    }

    func testStructuredParserRejectsMalformedOrChangedSchema() throws {
        let malformed = Data("not json".utf8)
        let changedSchema = try JSONSerialization.data(withJSONObject: [
            "contents": ["unknownRenderer": [:]]
        ])

        XCTAssertThrowsError(try YouTubeStructuredSearchClient.candidates(from: malformed))
        XCTAssertThrowsError(try YouTubeStructuredSearchClient.candidates(from: changedSchema))
    }

}
