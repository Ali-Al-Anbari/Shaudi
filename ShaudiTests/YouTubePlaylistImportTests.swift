//
//  YouTubePlaylistImportTests.swift
//  ShaudiTests
//

import Foundation
import SwiftData
import XCTest
@testable import Shaudi

@MainActor
final class YouTubePlaylistImportTests: XCTestCase {
    private enum SimulatedError: LocalizedError {
        case networkFailure
        case saveFailure

        var errorDescription: String? {
            switch self {
            case .networkFailure: "Simulated network failure"
            case .saveFailure: "Simulated save failure"
            }
        }
    }

    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Track.self,
            Playlist.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        return (container, container.mainContext)
    }

    override func tearDown() {
        super.tearDown()
        YouTubePlaylistImporter.saveOverride = nil
    }

    // MARK: - 1. Standard playlist URL ID extraction
    func testStandardPlaylistURLIDExtraction() {
        let url1 = "https://www.youtube.com/playlist?list=PLDIoUOhQQPlXr63I_vwF9GD8sAKh77dWU"
        let parsed1 = YouTubeURLParser.parsePlaylist(url1)
        XCTAssertEqual(parsed1?.id, "PLDIoUOhQQPlXr63I_vwF9GD8sAKh77dWU")
        XCTAssertEqual(parsed1?.url.absoluteString, "https://www.youtube.com/playlist?list=PLDIoUOhQQPlXr63I_vwF9GD8sAKh77dWU")

        let url2 = "https://music.youtube.com/playlist?list=PLMC9KNkIncKtPzgY-5rmhvj7fax8fdxoj&si=abc123xyz"
        let parsed2 = YouTubeURLParser.parsePlaylist(url2)
        XCTAssertEqual(parsed2?.id, "PLMC9KNkIncKtPzgY-5rmhvj7fax8fdxoj")

        let url3 = "https://m.youtube.com/playlist?list=PLtest123"
        let parsed3 = YouTubeURLParser.parsePlaylist(url3)
        XCTAssertEqual(parsed3?.id, "PLtest123")
    }

    // MARK: - 2. Watch URL with list parameter
    func testWatchURLWithListParameter() {
        let watchURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI&index=1"
        let parsed = YouTubeURLParser.parsePlaylist(watchURL)
        XCTAssertEqual(parsed?.id, "PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI")

        let youtuBeURL = "https://youtu.be/dQw4w9WgXcQ?list=PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI"
        let parsedYoutu = YouTubeURLParser.parsePlaylist(youtuBeURL)
        XCTAssertEqual(parsedYoutu?.id, "PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI")
    }

    // MARK: - 3. Malformed URL
    func testMalformedURL() {
        XCTAssertNil(YouTubeURLParser.parsePlaylist("not a valid url"))
        XCTAssertNil(YouTubeURLParser.parsePlaylist("https://example.com/playlist?list=PL12345"))
        XCTAssertNil(YouTubeURLParser.parsePlaylist("https://www.youtube.com/playlist?list=bad@id!"))
        XCTAssertNil(YouTubeURLParser.parsePlaylist("ftp://youtube.com/playlist?list=PL12345"))
    }

    // MARK: - 4. Missing playlist ID
    func testMissingPlaylistID() {
        XCTAssertNil(YouTubeURLParser.parsePlaylist("https://www.youtube.com/playlist"))
        XCTAssertNil(YouTubeURLParser.parsePlaylist("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertNil(YouTubeURLParser.parsePlaylist(""))
        XCTAssertNil(YouTubeURLParser.parsePlaylist("   "))
    }

    // MARK: - 5. Structured playlist payload parsing
    func testStructuredPlaylistPayloadParsing() throws {
        let fixtureData = try makePlaylistFixtureData(
            title: "Test Playlist",
            items: [
                (id: "vid00000001", title: "Song One", artist: "Artist One"),
                (id: "vid00000002", title: "Song Two", artist: "Artist Two")
            ]
        )

        let parsed = try YouTubePlaylistExtractionClient.parsePage(fixtureData)
        XCTAssertEqual(parsed.playlistTitle, "Test Playlist")
        XCTAssertEqual(parsed.items.count, 2)
        XCTAssertEqual(parsed.items[0].videoID, "vid00000001")
        XCTAssertEqual(parsed.items[0].title, "Song One")
        XCTAssertEqual(parsed.items[0].artist, "Artist One")
        XCTAssertEqual(parsed.items[1].videoID, "vid00000002")
    }

    // MARK: - 6. Continuation parsing
    func testContinuationParsing() throws {
        let fixtureData = try makePlaylistFixtureData(
            title: "Continuation Test",
            items: [(id: "vid00000001", title: "Song One", artist: "Artist One")],
            continuationToken: "token_abc_123"
        )

        let parsed = try YouTubePlaylistExtractionClient.parsePage(fixtureData)
        XCTAssertEqual(parsed.continuationToken, "token_abc_123")
    }

    // MARK: - 7. Multi-page playlist aggregation
    func testMultiPagePlaylistAggregation() async throws {
        let page1 = try makePlaylistFixtureData(
            title: "Multi Page",
            items: [(id: "vid00000001", title: "Song 1", artist: "Artist 1")],
            continuationToken: "next_page_token"
        )
        let page2 = try makeContinuationFixtureData(
            items: [(id: "vid00000002", title: "Song 2", artist: "Artist 2")],
            continuationToken: nil
        )

        let client = YouTubePlaylistExtractionClient { request in
            let bodyString = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if bodyString.contains("next_page_token") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (page2, response)
            } else {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (page1, response)
            }
        }

        let playlist = try await client.fetchPlaylist(playlistID: "PLtestmultipage")
        XCTAssertEqual(playlist.items.count, 2)
        XCTAssertEqual(playlist.items[0].videoID, "vid00000001")
        XCTAssertEqual(playlist.items[1].videoID, "vid00000002")
    }

    // MARK: - 8. Duplicate video IDs in source
    func testDuplicateVideoIDsInSource() async throws {
        let pageData = try makePlaylistFixtureData(
            title: "Duplicates Test",
            items: [
                (id: "vid00000001", title: "Song 1", artist: "Artist 1"),
                (id: "vid00000002", title: "Song 2", artist: "Artist 2"),
                (id: "vid00000001", title: "Song 1 Dup", artist: "Artist 1")
            ]
        )

        let client = YouTubePlaylistExtractionClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (pageData, response)
        }

        let playlist = try await client.fetchPlaylist(playlistID: "PLduplicates")
        XCTAssertEqual(playlist.items.count, 2)
        XCTAssertEqual(playlist.duplicateSkippedCount, 1)
        XCTAssertEqual(playlist.items.map(\.videoID), ["vid00000001", "vid00000002"])
    }

    // MARK: - 9. Unavailable/deleted video skipped
    func testUnavailableDeletedVideoSkipped() async throws {
        let pageData = try makePlaylistFixtureData(
            title: "Unavailable Test",
            items: [
                (id: "vid00000001", title: "Valid Song", artist: "Artist"),
                (id: "vid00000002", title: "[Deleted video]", artist: nil),
                (id: "vid00000003", title: "[Private video]", artist: nil),
                (id: "vid00000004", title: "Unavailable video", artist: nil)
            ]
        )

        let client = YouTubePlaylistExtractionClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (pageData, response)
        }

        let playlist = try await client.fetchPlaylist(playlistID: "PLunavailable")
        XCTAssertEqual(playlist.items.count, 1)
        XCTAssertEqual(playlist.unavailableSkippedCount, 3)
        XCTAssertEqual(playlist.items.first?.videoID, "vid00000001")
    }

    // MARK: - 10. Private/unusable item skipped
    func testPrivateUnusableItemSkipped() async throws {
        let pageData = try makePlaylistFixtureData(
            title: "Unusable Item Test",
            items: [
                (id: "bad_short", title: "Short ID", artist: "Artist"),
                (id: "vid00000001", title: "Valid Song", artist: "Artist")
            ]
        )

        let client = YouTubePlaylistExtractionClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (pageData, response)
        }

        let playlist = try await client.fetchPlaylist(playlistID: "PLunusable")
        XCTAssertEqual(playlist.items.count, 1)
        XCTAssertEqual(playlist.unavailableSkippedCount, 1)
        XCTAssertEqual(playlist.items.first?.videoID, "vid00000001")
    }

    // MARK: - 11. Canonical URL construction
    func testCanonicalURLConstruction() {
        let item = PendingYouTubePlaylistItem(
            videoID: "dQw4w9WgXcQ",
            title: "Never Gonna Give You Up",
            artist: "Rick Astley",
            thumbnailURL: nil,
            sourceOrder: 0
        )
        XCTAssertEqual(item.canonicalURL.absoluteString, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    // MARK: - 12. Unicode title/artist
    func testUnicodeTitleArtist() throws {
        let fixtureData = try makePlaylistFixtureData(
            title: "K-Pop Hits &amp; More",
            items: [
                (id: "vid00000001", title: "ROSÉ &amp; Bruno Mars - APT.", artist: "ROSÉ"),
                (id: "vid00000002", title: "아이유 (IU) - 밤편지", artist: "아이유 (IU)"),
                (id: "vid00000003", title: "Beyoncé - TEXAS HOLD &apos;EM", artist: "Beyoncé")
            ]
        )

        let parsed = try YouTubePlaylistExtractionClient.parsePage(fixtureData)
        XCTAssertEqual(parsed.playlistTitle, "K-Pop Hits & More")
        XCTAssertEqual(parsed.items.count, 3)

        let pending1 = PendingYouTubePlaylistItem(
            videoID: parsed.items[0].videoID!,
            title: parsed.items[0].title!,
            artist: parsed.items[0].artist,
            thumbnailURL: nil,
            sourceOrder: 0
        )
        XCTAssertEqual(pending1.title, "ROSÉ & Bruno Mars - APT.")
        XCTAssertEqual(pending1.artist, "ROSÉ")

        let pending2 = PendingYouTubePlaylistItem(
            videoID: parsed.items[1].videoID!,
            title: parsed.items[1].title!,
            artist: parsed.items[1].artist,
            thumbnailURL: nil,
            sourceOrder: 1
        )
        XCTAssertEqual(pending2.title, "아이유 (IU) - 밤편지")
        XCTAssertEqual(pending2.artist, "아이유 (IU)")

        let pending3 = PendingYouTubePlaylistItem(
            videoID: parsed.items[2].videoID!,
            title: parsed.items[2].title!,
            artist: parsed.items[2].artist,
            thumbnailURL: nil,
            sourceOrder: 2
        )
        XCTAssertEqual(pending3.title, "Beyoncé - TEXAS HOLD 'EM")
        XCTAssertEqual(pending3.artist, "Beyoncé")
    }

    // MARK: - 13. Missing artist
    func testMissingArtist() throws {
        let fixtureData = try makePlaylistFixtureData(
            title: "No Artist Test",
            items: [
                (id: "vid00000001", title: "Standalone Song", artist: nil)
            ]
        )

        let parsed = try YouTubePlaylistExtractionClient.parsePage(fixtureData)
        let item = try XCTUnwrap(parsed.items.first)
        let pending = PendingYouTubePlaylistItem(
            videoID: item.videoID!,
            title: item.title!,
            artist: item.artist,
            thumbnailURL: nil,
            sourceOrder: 0
        )
        XCTAssertEqual(pending.title, "Standalone Song")
        XCTAssertNil(pending.artist)
    }

    // MARK: - 14. Preserving source order
    func testPreservingSourceOrder() async throws {
        let pageData = try makePlaylistFixtureData(
            title: "Order Test",
            items: [
                (id: "vid00000001", title: "First", artist: "A"),
                (id: "vid00000002", title: "Second", artist: "B"),
                (id: "vid00000003", title: "Third", artist: "C")
            ]
        )

        let client = YouTubePlaylistExtractionClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (pageData, response)
        }

        let playlist = try await client.fetchPlaylist(playlistID: "PLorder")
        XCTAssertEqual(playlist.items.map(\.videoID), ["vid00000001", "vid00000002", "vid00000003"])
        XCTAssertEqual(playlist.items.map(\.sourceOrder), [0, 1, 2])
    }

    // MARK: - 15. Zero YouTube Data API client usage
    func testZeroYouTubeDataAPIClientUsage() async throws {
        var requestedURLs: [URL] = []
        let pageData = try makePlaylistFixtureData(
            title: "Zero API Test",
            items: [(id: "vid00000001", title: "Song 1", artist: "Artist 1")]
        )

        let client = YouTubePlaylistExtractionClient { request in
            requestedURLs.append(request.url!)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (pageData, response)
        }

        _ = try await client.fetchPlaylist(playlistID: "PLzeroapi")
        for url in requestedURLs {
            XCTAssertFalse(url.absoluteString.contains("googleapis.com"), "Must not call official YouTube Data API")
            XCTAssertFalse(url.absoluteString.contains("youtube/v3"), "Must not call YouTube Data API v3")
        }
    }

    // MARK: - Live Network Check
    func testLivePublicPlaylistValidation() async throws {
        let client = YouTubePlaylistExtractionClient()
        let playlistID = "PLDIoUOhQQPlXr63I_vwF9GD8sAKh77dWU"
        let playlist = try await client.fetchPlaylist(playlistID: playlistID)
        XCTAssertFalse(playlist.items.isEmpty, "Should discover items from live public playlist")
        print("[LiveValidation] Discovered items=\(playlist.items.count), unavailable=\(playlist.unavailableSkippedCount), duplicates=\(playlist.duplicateSkippedCount), title=\(playlist.title ?? "none")")
    }

    // MARK: - 16. Fetched songs appear in preview
    func testFetchedSongsAppearInPreview() {
        let items = [
            PendingYouTubePlaylistItem(videoID: "vid00000001", title: "Song 1", artist: "Artist 1", thumbnailURL: nil, sourceOrder: 0),
            PendingYouTubePlaylistItem(videoID: "vid00000002", title: "Song 2", artist: "Artist 2", thumbnailURL: nil, sourceOrder: 1)
        ]
        let playlist = ExtractedYouTubePlaylist(
            playlistID: "PLtest",
            title: "Test",
            items: items,
            unavailableSkippedCount: 0,
            duplicateSkippedCount: 0
        )
        XCTAssertEqual(playlist.items.count, 2)
        XCTAssertEqual(playlist.items.map(\.title), ["Song 1", "Song 2"])
    }

    // MARK: - 17. Preview causes zero SwiftData mutation
    func testPreviewCausesZeroSwiftDataMutation() throws {
        let (_container, ctx) = try makeContext()
        _ = ExtractedYouTubePlaylist(
            playlistID: "PLpreviewtest",
            title: "Preview Test",
            items: [
                PendingYouTubePlaylistItem(videoID: "vid00000001", title: "Song 1", artist: "Artist 1", thumbnailURL: nil, sourceOrder: 0)
            ],
            unavailableSkippedCount: 0,
            duplicateSkippedCount: 0
        )

        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        let playlists = try ctx.fetch(FetchDescriptor<Playlist>())
        XCTAssertEqual(tracks.count, 0, "Preview must not create SwiftData tracks")
        XCTAssertEqual(playlists.count, 0, "Preview must not create SwiftData playlists")
        XCTAssertFalse(ctx.hasChanges, "ModelContext must have zero unsaved changes")
    }

    // MARK: - 18. Remove one song from pending import
    func testRemoveOneSongFromPendingImport() {
        var items = [
            PendingYouTubePlaylistItem(videoID: "vid00000001", title: "A", artist: nil, thumbnailURL: nil, sourceOrder: 0),
            PendingYouTubePlaylistItem(videoID: "vid00000002", title: "B", artist: nil, thumbnailURL: nil, sourceOrder: 1),
            PendingYouTubePlaylistItem(videoID: "vid00000003", title: "C", artist: nil, thumbnailURL: nil, sourceOrder: 2)
        ]

        items.removeAll { $0.videoID == "vid00000002" }
        XCTAssertEqual(items.map(\.videoID), ["vid00000001", "vid00000003"])
    }

    // MARK: - 19. Remove multiple songs
    func testRemoveMultipleSongs() {
        var items = [
            PendingYouTubePlaylistItem(videoID: "vid00000001", title: "A", artist: nil, thumbnailURL: nil, sourceOrder: 0),
            PendingYouTubePlaylistItem(videoID: "vid00000002", title: "B", artist: nil, thumbnailURL: nil, sourceOrder: 1),
            PendingYouTubePlaylistItem(videoID: "vid00000003", title: "C", artist: nil, thumbnailURL: nil, sourceOrder: 2),
            PendingYouTubePlaylistItem(videoID: "vid00000004", title: "D", artist: nil, thumbnailURL: nil, sourceOrder: 3)
        ]

        let toRemove: Set<String> = ["vid00000001", "vid00000003"]
        items.removeAll { toRemove.contains($0.videoID) }
        XCTAssertEqual(items.map(\.videoID), ["vid00000002", "vid00000004"])
    }

    // MARK: - 20. Remaining order stays correct
    func testRemainingOrderStaysCorrect() {
        var items = [
            PendingYouTubePlaylistItem(videoID: "vid00000001", title: "A", artist: nil, thumbnailURL: nil, sourceOrder: 0),
            PendingYouTubePlaylistItem(videoID: "vid00000002", title: "B", artist: nil, thumbnailURL: nil, sourceOrder: 1),
            PendingYouTubePlaylistItem(videoID: "vid00000003", title: "C", artist: nil, thumbnailURL: nil, sourceOrder: 2),
            PendingYouTubePlaylistItem(videoID: "vid00000004", title: "D", artist: nil, thumbnailURL: nil, sourceOrder: 3)
        ]

        // Remove B
        items.removeAll { $0.videoID == "vid00000002" }
        XCTAssertEqual(items.map(\.title), ["A", "C", "D"])
    }

    // MARK: - 21. Select All if implemented (Keep All)
    func testSelectAllRestoresOriginalList() {
        let original = [
            PendingYouTubePlaylistItem(videoID: "vid00000001", title: "A", artist: nil, thumbnailURL: nil, sourceOrder: 0),
            PendingYouTubePlaylistItem(videoID: "vid00000002", title: "B", artist: nil, thumbnailURL: nil, sourceOrder: 1)
        ]
        var current = [original[0]]
        XCTAssertEqual(current.count, 1)

        // Keep All restores full original list
        current = original
        XCTAssertEqual(current.count, 2)
        XCTAssertEqual(current.map(\.videoID), ["vid00000001", "vid00000002"])
    }

    // MARK: - 22. Clear All if implemented (Remove All)
    func testClearAllRemovesAll() {
        var current = [
            PendingYouTubePlaylistItem(videoID: "vid00000001", title: "A", artist: nil, thumbnailURL: nil, sourceOrder: 0),
            PendingYouTubePlaylistItem(videoID: "vid00000002", title: "B", artist: nil, thumbnailURL: nil, sourceOrder: 1)
        ]
        current.removeAll()
        XCTAssertTrue(current.isEmpty)
    }

    // MARK: - 23. Import disabled when zero songs remain
    func testImportDisabledWhenZeroSongsRemain() throws {
        let (_container, ctx) = try makeContext()
        XCTAssertThrowsError(
            try YouTubePlaylistImporter.apply(
                items: [],
                originalFetchedCount: 5,
                unavailableSkippedCount: 0,
                destination: .libraryOnly,
                in: ctx
            )
        ) { error in
            XCTAssertEqual(error as? YouTubePlaylistImporterError, .noSongsSelected)
        }
    }

    // MARK: - 24. Removed item is not persisted
    func testRemovedItemIsNotPersisted() throws {
        let (_container, ctx) = try makeContext()
        let items = [
            PendingYouTubePlaylistItem(videoID: "vid00000001", title: "A", artist: nil, thumbnailURL: nil, sourceOrder: 0)
        ]

        _ = try YouTubePlaylistImporter.apply(
            items: items,
            originalFetchedCount: 2,
            unavailableSkippedCount: 0,
            destination: .libraryOnly,
            in: ctx
        )

        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.youtubeVideoID, "vid00000001")
        XCTAssertNil(tracks.first { $0.youtubeVideoID == "vid00000002" })
    }

    // MARK: - 25. Fetched count differs correctly from selected count
    func testFetchedCountDiffersCorrectlyFromSelectedCount() throws {
        let (_container, ctx) = try makeContext()
        let selected = [
            PendingYouTubePlaylistItem(videoID: "vid00000001", title: "A", artist: nil, thumbnailURL: nil, sourceOrder: 0)
        ]

        let summary = try YouTubePlaylistImporter.apply(
            items: selected,
            originalFetchedCount: 5,
            unavailableSkippedCount: 1,
            destination: .libraryOnly,
            in: ctx
        )

        XCTAssertEqual(summary.selectedSongCount, 1)
        XCTAssertEqual(summary.removedBeforeImportCount, 4)
    }

    // MARK: - 26. Removed-before-import count is correct
    func testRemovedBeforeImportCountIsCorrect() throws {
        let (_container, ctx) = try makeContext()
        let selected = [
            PendingYouTubePlaylistItem(videoID: "vid00000001", title: "A", artist: nil, thumbnailURL: nil, sourceOrder: 0),
            PendingYouTubePlaylistItem(videoID: "vid00000002", title: "B", artist: nil, thumbnailURL: nil, sourceOrder: 1)
        ]

        let summary = try YouTubePlaylistImporter.apply(
            items: selected,
            originalFetchedCount: 5,
            unavailableSkippedCount: 2,
            destination: .libraryOnly,
            in: ctx
        )

        XCTAssertEqual(summary.removedBeforeImportCount, 3)
    }

    // MARK: - 27. Existing Track reuse by video ID
    func testExistingTrackReuseByVideoID() throws {
        let (_container, ctx) = try makeContext()
        let existing = Track(
            title: "Original Title",
            youtubeURL: URL(string: "https://www.youtube.com/watch?v=vid00000001")!,
            youtubeVideoID: "vid00000001"
        )
        ctx.insert(existing)
        try ctx.save()

        let items = [
            PendingYouTubePlaylistItem(videoID: "vid00000001", title: "New Title", artist: "Artist", thumbnailURL: nil, sourceOrder: 0)
        ]

        let summary = try YouTubePlaylistImporter.apply(
            items: items,
            originalFetchedCount: 1,
            unavailableSkippedCount: 0,
            destination: .libraryOnly,
            in: ctx
        )

        XCTAssertEqual(summary.newSongsAddedCount, 0)
        XCTAssertEqual(summary.existingSongsReusedCount, 1)

        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        XCTAssertEqual(tracks.count, 1, "Must not create duplicate Track in Library")
        XCTAssertEqual(tracks.first?.title, "Original Title", "Must not overwrite existing title")
    }

    // MARK: - 28. New Track creation
    func testNewTrackCreation() throws {
        let (_container, ctx) = try makeContext()
        let items = [
            PendingYouTubePlaylistItem(videoID: "vid00000001", title: "Brand New Track", artist: "Artist", thumbnailURL: URL(string: "https://example.com/thumb.jpg"), sourceOrder: 0)
        ]

        let summary = try YouTubePlaylistImporter.apply(
            items: items,
            originalFetchedCount: 1,
            unavailableSkippedCount: 0,
            destination: .libraryOnly,
            in: ctx
        )

        XCTAssertEqual(summary.newSongsAddedCount, 1)
        XCTAssertEqual(summary.existingSongsReusedCount, 0)

        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        XCTAssertEqual(tracks.count, 1)
        let track = try XCTUnwrap(tracks.first)
        XCTAssertEqual(track.title, "Brand New Track")
        XCTAssertEqual(track.channelTitle, "Artist")
        XCTAssertEqual(track.youtubeVideoID, "vid00000001")
        XCTAssertEqual(track.youtubeURL.absoluteString, "https://www.youtube.com/watch?v=vid00000001")
        XCTAssertEqual(track.thumbnailURL?.absoluteString, "https://example.com/thumb.jpg")
    }

    // MARK: - 29. Metadata fill without overwriting user edit
    func testMetadataFillWithoutOverwritingUserEdit() throws {
        let (_container, ctx) = try makeContext()
        let existing = Track(
            title: "Custom Title",
            youtubeURL: URL(string: "https://www.youtube.com/watch?v=vid00000001")!,
            youtubeVideoID: "vid00000001",
            userArtistOverride: "My Custom Artist"
        )
        ctx.insert(existing)
        try ctx.save()

        let items = [
            PendingYouTubePlaylistItem(
                videoID: "vid00000001",
                title: "Imported Title",
                artist: "Imported Artist",
                thumbnailURL: URL(string: "https://example.com/imported.jpg"),
                sourceOrder: 0
            )
        ]

        _ = try YouTubePlaylistImporter.apply(
            items: items,
            originalFetchedCount: 1,
            unavailableSkippedCount: 0,
            destination: .libraryOnly,
            in: ctx
        )

        let track = try XCTUnwrap(ctx.fetch(FetchDescriptor<Track>()).first)
        XCTAssertEqual(track.title, "Custom Title", "User edited title must not be overwritten")
        XCTAssertEqual(track.userArtistOverride, "My Custom Artist", "User artist override must not be overwritten")
        XCTAssertEqual(track.thumbnailURL?.absoluteString, "https://example.com/imported.jpg", "Missing thumbnail should be filled")
    }

    // MARK: - 30. Library-only import
    func testLibraryOnlyImport() throws {
        let (_container, ctx) = try makeContext()
        let items = [
            PendingYouTubePlaylistItem(videoID: "vid00000001", title: "A", artist: nil, thumbnailURL: nil, sourceOrder: 0)
        ]

        let summary = try YouTubePlaylistImporter.apply(
            items: items,
            originalFetchedCount: 1,
            unavailableSkippedCount: 0,
            destination: .libraryOnly,
            in: ctx
        )

        XCTAssertTrue(summary.isLibraryOnly)
        XCTAssertEqual(summary.playlistMembershipsAddedCount, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Playlist>()).count, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Track>()).count, 1)
    }

    // MARK: - 31. New Playlist import
    func testNewPlaylistImport() throws {
        let (_container, ctx) = try makeContext()
        let items = [
            PendingYouTubePlaylistItem(videoID: "vid00000001", title: "A", artist: nil, thumbnailURL: nil, sourceOrder: 0),
            PendingYouTubePlaylistItem(videoID: "vid00000002", title: "B", artist: nil, thumbnailURL: nil, sourceOrder: 1)
        ]

        let summary = try YouTubePlaylistImporter.apply(
            items: items,
            originalFetchedCount: 2,
            unavailableSkippedCount: 0,
            destination: .newPlaylist(name: "Road Trip Vibes"),
            in: ctx
        )

        XCTAssertFalse(summary.isLibraryOnly)
        XCTAssertEqual(summary.destinationTitle, "Road Trip Vibes")
        XCTAssertEqual(summary.playlistMembershipsAddedCount, 2)

        let playlists = try ctx.fetch(FetchDescriptor<Playlist>())
        XCTAssertEqual(playlists.count, 1)
        let playlist = try XCTUnwrap(playlists.first)
        XCTAssertEqual(playlist.name, "Road Trip Vibes")
        XCTAssertEqual(playlist.tracks.count, 2)
        XCTAssertEqual(playlist.tracksInPlaybackOrder.map(\.title), ["A", "B"])
    }

    // MARK: - 32. Existing Playlist import
    func testExistingPlaylistImport() throws {
        let (_container, ctx) = try makeContext()
        let existingPlaylist = Playlist(name: "Favorites")
        ctx.insert(existingPlaylist)
        try ctx.save()

        let items = [
            PendingYouTubePlaylistItem(videoID: "vid00000001", title: "New Song", artist: nil, thumbnailURL: nil, sourceOrder: 0)
        ]

        let summary = try YouTubePlaylistImporter.apply(
            items: items,
            originalFetchedCount: 1,
            unavailableSkippedCount: 0,
            destination: .existingPlaylist(existingPlaylist.persistentModelID),
            in: ctx
        )

        XCTAssertEqual(summary.playlistMembershipsAddedCount, 1)
        XCTAssertEqual(existingPlaylist.tracks.count, 1)
        XCTAssertEqual(existingPlaylist.tracks.first?.title, "New Song")
    }

    // MARK: - 33. Duplicate playlist membership skipped
    func testDuplicatePlaylistMembershipSkipped() throws {
        let (_container, ctx) = try makeContext()
        let track = Track(
            title: "Already In Playlist",
            youtubeURL: URL(string: "https://www.youtube.com/watch?v=vid00000001")!,
            youtubeVideoID: "vid00000001"
        )
        let playlist = Playlist(name: "Gym", tracks: [track])
        ctx.insert(track)
        ctx.insert(playlist)
        try ctx.save()

        let items = [
            PendingYouTubePlaylistItem(videoID: "vid00000001", title: "Already In Playlist", artist: nil, thumbnailURL: nil, sourceOrder: 0)
        ]

        let summary = try YouTubePlaylistImporter.apply(
            items: items,
            originalFetchedCount: 1,
            unavailableSkippedCount: 0,
            destination: .existingPlaylist(playlist.persistentModelID),
            in: ctx
        )

        XCTAssertEqual(summary.playlistMembershipsAddedCount, 0)
        XCTAssertEqual(summary.duplicateMembershipsSkippedCount, 1)
        XCTAssertEqual(playlist.tracks.count, 1)
    }

    // MARK: - 34. Same Track reused across multiple playlist memberships
    func testSameTrackReusedAcrossMultiplePlaylistMemberships() throws {
        let (_container, ctx) = try makeContext()
        let track = Track(
            title: "Shared Song",
            youtubeURL: URL(string: "https://www.youtube.com/watch?v=vid00000001")!,
            youtubeVideoID: "vid00000001"
        )
        let playlist1 = Playlist(name: "Playlist 1", tracks: [track])
        let playlist2 = Playlist(name: "Playlist 2", tracks: [])
        ctx.insert(track)
        ctx.insert(playlist1)
        ctx.insert(playlist2)
        try ctx.save()

        let items = [
            PendingYouTubePlaylistItem(videoID: "vid00000001", title: "Shared Song", artist: nil, thumbnailURL: nil, sourceOrder: 0)
        ]

        let summary = try YouTubePlaylistImporter.apply(
            items: items,
            originalFetchedCount: 1,
            unavailableSkippedCount: 0,
            destination: .existingPlaylist(playlist2.persistentModelID),
            in: ctx
        )

        XCTAssertEqual(summary.playlistMembershipsAddedCount, 1)
        XCTAssertEqual(playlist1.tracks.count, 1)
        XCTAssertEqual(playlist2.tracks.count, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Track>()).count, 1, "Only one global Track exists")
    }

    // MARK: - 35. Empty/unusable playlist error
    func testEmptyUnusablePlaylistError() async throws {
        let emptyData = try makePlaylistFixtureData(
            title: "Empty Playlist",
            items: []
        )

        let client = YouTubePlaylistExtractionClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (emptyData, response)
        }

        do {
            _ = try await client.fetchPlaylist(playlistID: "PLempty")
            XCTFail("Expected emptyOrUnusablePlaylist error")
        } catch let error as YouTubePlaylistExtractionError {
            guard case .emptyOrUnusablePlaylist = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - 36. Network failure
    func testNetworkFailure() async throws {
        let client = YouTubePlaylistExtractionClient { _ in
            throw SimulatedError.networkFailure
        }

        do {
            _ = try await client.fetchPlaylist(playlistID: "PLnetworkfail")
            XCTFail("Expected network error")
        } catch let error as YouTubePlaylistExtractionError {
            guard case .network = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - 37. Malformed payload
    func testMalformedPayload() {
        XCTAssertThrowsError(
            try YouTubePlaylistExtractionClient.parsePage(Data("not json".utf8))
        )
    }

    // MARK: - 38. Continuation failure behavior
    func testContinuationFailureBehavior() async throws {
        let page1 = try makePlaylistFixtureData(
            title: "Continuation Fail",
            items: [(id: "vid00000001", title: "Song 1", artist: "Artist 1")],
            continuationToken: "broken_token"
        )

        let client = YouTubePlaylistExtractionClient { request in
            let bodyString = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if bodyString.contains("broken_token") {
                throw SimulatedError.networkFailure
            } else {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (page1, response)
            }
        }

        do {
            _ = try await client.fetchPlaylist(playlistID: "PLcontfail")
            XCTFail("Expected continuationFailed error")
        } catch let error as YouTubePlaylistExtractionError {
            guard case .continuationFailed = error else {
                return XCTFail("Expected continuationFailed, got \(error)")
            }
        }
    }

    // MARK: - 39. SwiftData save failure reporting
    func testSwiftDataSaveFailureReporting() throws {
        let (_container, ctx) = try makeContext()
        YouTubePlaylistImporter.saveOverride = { _ in
            throw SimulatedError.saveFailure
        }

        let items = [
            PendingYouTubePlaylistItem(videoID: "vid00000001", title: "Song 1", artist: nil, thumbnailURL: nil, sourceOrder: 0)
        ]

        XCTAssertThrowsError(
            try YouTubePlaylistImporter.apply(
                items: items,
                originalFetchedCount: 1,
                unavailableSkippedCount: 0,
                destination: .newPlaylist(name: "Failed Playlist"),
                in: ctx
            )
        )

        // Verify rollback: no orphaned tracks or playlists remained
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Track>()).count, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Playlist>()).count, 0)
    }

    // MARK: - 40. Apply only after explicit import confirmation
    func testApplyOnlyAfterExplicitImportConfirmation() throws {
        let (_container, ctx) = try makeContext()
        let items = [
            PendingYouTubePlaylistItem(videoID: "vid00000001", title: "Pending", artist: nil, thumbnailURL: nil, sourceOrder: 0)
        ]

        // Simply having items in memory mutates nothing
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Track>()).count, 0)

        // Only explicit apply persists
        _ = try YouTubePlaylistImporter.apply(
            items: items,
            originalFetchedCount: 1,
            unavailableSkippedCount: 0,
            destination: .libraryOnly,
            in: ctx
        )
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Track>()).count, 1)
    }

    // MARK: - 41. Only selected items are persisted
    func testOnlySelectedItemsArePersisted() throws {
        let (_container, ctx) = try makeContext()
        let allFetched = [
            PendingYouTubePlaylistItem(videoID: "vid00000001", title: "Keep", artist: nil, thumbnailURL: nil, sourceOrder: 0),
            PendingYouTubePlaylistItem(videoID: "vid00000002", title: "Discard", artist: nil, thumbnailURL: nil, sourceOrder: 1)
        ]

        let selected = [allFetched[0]]

        let summary = try YouTubePlaylistImporter.apply(
            items: selected,
            originalFetchedCount: allFetched.count,
            unavailableSkippedCount: 0,
            destination: .libraryOnly,
            in: ctx
        )

        XCTAssertEqual(summary.selectedSongCount, 1)
        XCTAssertEqual(summary.removedBeforeImportCount, 1)

        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.youtubeVideoID, "vid00000001")
    }

    // MARK: - Fixture Generators
    private func makePlaylistFixtureData(
        title: String,
        items: [(id: String, title: String, artist: String?)],
        continuationToken: String? = nil
    ) throws -> Data {
        var contents: [[String: Any]] = []

        for item in items {
            let lockup: [String: Any] = [
                "lockupViewModel": [
                    "contentId": item.id,
                    "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
                    "metadata": [
                        "lockupMetadataViewModel": [
                            "title": [
                                "content": item.title
                            ],
                            "metadata": [
                                "contentMetadataViewModel": [
                                    "metadataRows": item.artist != nil ? [
                                        [
                                            "metadataParts": [
                                                ["text": ["content": item.artist!]]
                                            ]
                                        ]
                                    ] : []
                                ]
                            ]
                        ]
                    ]
                ]
            ]
            contents.append(lockup)
        }

        if let continuationToken {
            contents.append([
                "continuationItemRenderer": [
                    "continuationEndpoint": [
                        "continuationCommand": [
                            "token": continuationToken
                        ]
                    ]
                ]
            ])
        }

        let root: [String: Any] = [
            "metadata": [
                "playlistMetadataRenderer": [
                    "title": title
                ]
            ],
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "tabs": [
                        [
                            "tabRenderer": [
                                "content": [
                                    "sectionListRenderer": [
                                        "contents": [
                                            [
                                                "itemSectionRenderer": [
                                                    "contents": contents
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        return try JSONSerialization.data(withJSONObject: root)
    }

    private func makeContinuationFixtureData(
        items: [(id: String, title: String, artist: String?)],
        continuationToken: String? = nil
    ) throws -> Data {
        var contents: [[String: Any]] = []

        for item in items {
            let lockup: [String: Any] = [
                "lockupViewModel": [
                    "contentId": item.id,
                    "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
                    "metadata": [
                        "lockupMetadataViewModel": [
                            "title": ["content": item.title],
                            "metadata": [
                                "contentMetadataViewModel": [
                                    "metadataRows": item.artist != nil ? [
                                        ["metadataParts": [["text": ["content": item.artist!]]]]
                                    ] : []
                                ]
                            ]
                        ]
                    ]
                ]
            ]
            contents.append(lockup)
        }

        if let continuationToken {
            contents.append([
                "continuationItemRenderer": [
                    "continuationEndpoint": [
                        "continuationCommand": [
                            "token": continuationToken
                        ]
                    ]
                ]
            ])
        }

        let root: [String: Any] = [
            "onResponseReceivedActions": [
                [
                    "appendContinuationItemsAction": [
                        "continuationItems": contents
                    ]
                ]
            ]
        ]

        return try JSONSerialization.data(withJSONObject: root)
    }
}
