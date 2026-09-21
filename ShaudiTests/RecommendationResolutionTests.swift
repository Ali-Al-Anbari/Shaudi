//
//  RecommendationResolutionTests.swift
//  ShaudiTests
//

import XCTest
@testable import Shaudi

@MainActor
final class RecommendationResolutionTests: XCTestCase {
    func testVideoResolutionCacheHitSkipsResolvers() async throws {
        let target = candidate("Artist", "Song")
        let identity = SongIdentity(artist: target.artist, title: target.title)
        let cached = youtubeResult(
            videoID: "cachehit001",
            artist: target.artist,
            title: target.title
        )
        let cache = MemoryYouTubeResolutionCache([identity: cached])
        var webRequests = 0
        var dataAPIRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in webRequests += 1; return [] },
            dataAPISearch: { _ in dataAPIRequests += 1; return [] }
        )
        let service = RecommendationService(
            similarTracks: { _, _, _ in [] },
            videoResolver: resolver,
            resolutionCache: cache
        )

        let result = try await service.resolveOnYouTube(target)

        XCTAssertEqual(result?.youtubeResult.youtubeVideoID, "cachehit001")
        XCTAssertEqual(webRequests, 0)
        XCTAssertEqual(dataAPIRequests, 0)
    }

    func testVideoResolutionCacheMissStoresAndThenHits() async throws {
        let target = candidate("Artist", "Song")
        let cache = MemoryYouTubeResolutionCache()
        var webRequests = 0
        var dataAPIRequests = 0
        let result = youtubeResult(
            videoID: "cachemiss01",
            artist: target.artist,
            title: target.title
        )
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in webRequests += 1; return [result] },
            dataAPISearch: { _ in dataAPIRequests += 1; return [] }
        )
        let service = RecommendationService(
            similarTracks: { _, _, _ in [] },
            videoResolver: resolver,
            resolutionCache: cache
        )

        let first = try await service.resolveOnYouTube(target)
        let second = try await service.resolveOnYouTube(target)

        XCTAssertEqual(first?.youtubeResult.youtubeVideoID, "cachemiss01")
        XCTAssertEqual(second?.youtubeResult.youtubeVideoID, "cachemiss01")
        XCTAssertEqual(webRequests, 1)
        XCTAssertEqual(dataAPIRequests, 0)
        XCTAssertEqual(cache.storeCount, 1)
    }

    func testUnavailableCachedVideoIsEvictedAndCanBeResolvedAgain() async throws {
        let target = candidate("Artist", "Song")
        let identity = SongIdentity(artist: target.artist, title: target.title)
        let stale = youtubeResult(
            videoID: "stalecache1",
            artist: target.artist,
            title: target.title
        )
        let fresh = youtubeResult(
            videoID: "freshcache1",
            artist: target.artist,
            title: target.title
        )
        let cache = MemoryYouTubeResolutionCache([identity: stale])
        var webRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in webRequests += 1; return [fresh] },
            dataAPISearch: { _ in [] }
        )
        let service = RecommendationService(
            similarTracks: { _, _, _ in [] },
            videoResolver: resolver,
            resolutionCache: cache
        )

        let staleResolution = try await service.resolveOnYouTube(target)
        XCTAssertEqual(staleResolution?.youtubeResult.youtubeVideoID, "stalecache1")
        await service.invalidateVideoResolution(for: identity)
        let freshResolution = try await service.resolveOnYouTube(target)
        XCTAssertEqual(freshResolution?.youtubeResult.youtubeVideoID, "freshcache1")
        XCTAssertEqual(webRequests, 1)
        XCTAssertEqual(cache.removeCount, 1)
    }

    func testPersistentVideoCacheReloadsRetainsLongTermAndEvictsLRU() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shaudi-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let policy = PersistentYouTubeResolutionCache.Policy(maximumEntryCount: 2)
        let baseDate = Date(timeIntervalSince1970: 1_000)
        let first = SongIdentity(artist: "Artist 1", title: "Song 1")
        let second = SongIdentity(artist: "Artist 2", title: "Song 2")
        let third = SongIdentity(artist: "Artist 3", title: "Song 3")
        let cache = PersistentYouTubeResolutionCache(fileURL: fileURL, policy: policy)

        await cache.store(
            youtubeResult(videoID: "persist0001", artist: first.artist, title: first.title),
            for: first,
            now: baseDate
        )
        await cache.store(
            youtubeResult(videoID: "persist0002", artist: second.artist, title: second.title),
            for: second,
            now: baseDate.addingTimeInterval(1)
        )
        await cache.store(
            youtubeResult(videoID: "persist0003", artist: third.artist, title: third.title),
            for: third,
            now: baseDate.addingTimeInterval(2)
        )

        let reloaded = PersistentYouTubeResolutionCache(fileURL: fileURL, policy: policy)
        let evicted = await reloaded.result(for: first, now: baseDate.addingTimeInterval(3))
        let retained = await reloaded.result(for: third, now: baseDate.addingTimeInterval(3))
        let longTerm = await reloaded.result(for: third, now: baseDate.addingTimeInterval(200))

        XCTAssertNil(evicted)
        XCTAssertEqual(retained?.youtubeVideoID, "persist0003")
        XCTAssertEqual(longTerm?.youtubeVideoID, "persist0003")
    }

    func testOfficialFallbackUsesCurrentUpcomingCountInsteadOfSnapshot() async throws {
        var upcomingCount = 3
        var dataAPIRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in [] },
            dataAPISearch: { _ in dataAPIRequests += 1; return [] },
            fallbackBudget: isolatedFallbackBudget()
        )
        let context = RecommendationResolutionContext(
            sessionID: UUID(),
            epochID: UUID(),
            upcomingCount: 3,
            currentUpcomingCount: { upcomingCount }
        )
        upcomingCount = 0

        _ = try await resolver.dataAPIFallbackOutcome(query: "Artist Song", context: context)

        XCTAssertEqual(dataAPIRequests, 1)
    }

    func testOfficialFallbackSkipsWhenCurrentBufferIsHealthy() async throws {
        var upcomingCount = 0
        var dataAPIRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in [] },
            dataAPISearch: { _ in dataAPIRequests += 1; return [] },
            fallbackBudget: isolatedFallbackBudget()
        )
        let context = RecommendationResolutionContext(
            sessionID: UUID(),
            epochID: UUID(),
            upcomingCount: 0,
            currentUpcomingCount: { upcomingCount }
        )
        upcomingCount = 2

        _ = try await resolver.dataAPIFallbackOutcome(query: "Artist Song", context: context)

        XCTAssertEqual(dataAPIRequests, 0)
    }

    func testInactiveOldSessionCannotInvokeResolversOrConsumeBudget() async throws {
        var webRequests = 0
        var dataAPIRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in webRequests += 1; return [] },
            dataAPISearch: { _ in dataAPIRequests += 1; return [] },
            fallbackBudget: isolatedFallbackBudget()
        )
        let context = RecommendationResolutionContext(
            sessionID: UUID(),
            epochID: UUID(),
            upcomingCount: 0,
            isActive: { false }
        )

        do {
            _ = try await resolver.primaryOutcome(query: "stale", isActive: { false })
            XCTFail("Expected stale primary resolution to cancel")
        } catch is CancellationError {}
        _ = try await resolver.dataAPIFallbackOutcome(query: "stale", context: context)

        XCTAssertEqual(webRequests, 0)
        XCTAssertEqual(dataAPIRequests, 0)
    }

    func testLowConfidenceCandidateIsRejectedAndNotCached() async throws {
        let target = candidate("Expected Artist", "Expected Song")
        let wrong = YouTubeSearchResult(
            youtubeVideoID: "wrongvid001",
            title: "Unrelated Creator - Different Song",
            channelTitle: "Unrelated Creator",
            thumbnailURL: nil
        )
        let cache = MemoryYouTubeResolutionCache()
        let service = RecommendationService(
            similarTracks: { _, _, _ in [] },
            videoResolver: YouTubeRecommendationResolver(
                primarySearch: { _ in [wrong] },
                dataAPISearch: { _ in [] }
            ),
            resolutionCache: cache
        )

        let resolved = try await service.resolveOnYouTube(target)
        let cached = await cache.peek(for: targetIdentity(target), now: .now)
        XCTAssertNil(resolved)
        XCTAssertNil(cached)
        XCTAssertEqual(cache.storeCount, 0)
    }

    func testExactIdentityCandidateBeatsEarlierUnrelatedResult() async throws {
        let target = candidate("Example Artist", "Example Song")
        let unrelated = YouTubeSearchResult(
            youtubeVideoID: "unrelated01",
            title: "Different Artist - Different Song",
            channelTitle: "Different Artist",
            thumbnailURL: nil
        )
        let exact = youtubeResult(
            videoID: "exactmat001",
            artist: target.artist,
            title: target.title
        )
        let service = RecommendationService(
            similarTracks: { _, _, _ in [] },
            videoResolver: YouTubeRecommendationResolver(
                primarySearch: { _ in [unrelated, exact] },
                dataAPISearch: { _ in [] }
            ),
            resolutionCache: MemoryYouTubeResolutionCache()
        )

        let resolved = try await service.resolveOnYouTube(target)

        XCTAssertEqual(resolved?.youtubeResult.youtubeVideoID, "exactmat001")
    }

    func testLiveCoverAndSlowedVersionsAreRejected() {
        let target = candidate("Example Artist", "Example Song")
        for (index, marker) in ["Live", "Cover", "Slowed"].enumerated() {
            let result = YouTubeSearchResult(
                youtubeVideoID: String(format: "variant%04d", index),
                title: "Example Artist - Example Song (\(marker))",
                channelTitle: "Example Artist",
                thumbnailURL: nil
            )
            XCTAssertNil(RecommendationService().youtubeScore(result, target: target))
        }
    }

    func testDurationSimilarityRaisesCandidateConfidence() throws {
        let target = candidate("Example Artist", "Example Song")
        let close = YouTubeSearchResult(
            youtubeVideoID: "duration001",
            title: "Example Artist - Example Song (Official Audio)",
            channelTitle: "Example Artist",
            thumbnailURL: nil,
            duration: 201
        )
        let far = YouTubeSearchResult(
            youtubeVideoID: "duration002",
            title: "Example Artist - Example Song (Official Audio)",
            channelTitle: "Example Artist",
            thumbnailURL: nil,
            duration: 500
        )
        let service = RecommendationService()
        let closeScore = try XCTUnwrap(
            service.youtubeScore(close, target: target, expectedDuration: 200)
        )
        let farScore = try XCTUnwrap(
            service.youtubeScore(far, target: target, expectedDuration: 200)
        )

        XCTAssertGreaterThan(closeScore, farScore)
    }

    func testAuthoritativeLastFMIdentityIsNeverReparsedFromUploadTitle() {
        let identity = SongIdentity(artist: "Canonical Artist", title: "Canonical Song")
        let seed = RecommendationSeed(
            youtubeVideoID: "lastfm00001",
            canonicalIdentity: identity,
            youtubeTitle: "Uploader Name - Misleading Upload Title",
            youtubeChannel: "Compilation Channel"
        )

        XCTAssertEqual(seed.songIdentity, identity)
        XCTAssertEqual(seed.confidentSongIdentityForCaching, identity)
    }

    func testManualSearchSelectionTeachesCacheWhenIdentityIsConfident() async {
        let cache = MemoryYouTubeResolutionCache()
        let learned = await YouTubeResolutionKnowledgeTeacher.learnIfConfident(
            videoID: "manual00001",
            rawTitle: "Example Artist - Example Song (Official Video)",
            displayedArtist: "Uploader",
            sourceChannel: "Uploader",
            userArtistOverride: nil,
            metadata: YouTubeResolutionMetadata(
                title: "Example Artist - Example Song (Official Video)",
                channel: "Uploader"
            ),
            source: .manualSearch,
            cache: cache
        )

        XCTAssertTrue(learned)
        let cached = await cache.peek(
            for: SongIdentity(artist: "Example Artist", title: "Example Song"),
            now: .now
        )
        XCTAssertEqual(cached?.youtubeVideoID, "manual00001")
    }

    func testLibraryAndPlaylistKnownIDsTeachCacheWithConfidentIdentity() async {
        let cache = MemoryYouTubeResolutionCache()
        let libraryLearned = await YouTubeResolutionKnowledgeTeacher.learnIfConfident(
            videoID: "library0001",
            rawTitle: "Library Song",
            displayedArtist: "Library Artist",
            sourceChannel: "Uploader",
            userArtistOverride: "Library Artist",
            metadata: YouTubeResolutionMetadata(title: "Library Song", channel: "Uploader"),
            source: .library,
            cache: cache
        )
        let playlistLearned = await YouTubeResolutionKnowledgeTeacher.learnIfConfident(
            videoID: "playlist001",
            rawTitle: "Playlist Song",
            displayedArtist: "Playlist Artist - Topic",
            sourceChannel: "Playlist Artist - Topic",
            userArtistOverride: nil,
            metadata: YouTubeResolutionMetadata(
                title: "Playlist Song",
                channel: "Playlist Artist - Topic"
            ),
            source: .playlist,
            cache: cache
        )

        XCTAssertTrue(libraryLearned)
        XCTAssertTrue(playlistLearned)
        XCTAssertEqual(cache.storeCount, 2)
    }

    func testUncertainUploaderIdentityDoesNotTeachCache() async {
        let cache = MemoryYouTubeResolutionCache()

        let learned = await YouTubeResolutionKnowledgeTeacher.learnIfConfident(
            videoID: "uncertain01",
            rawTitle: "A Song Without Artist Attribution",
            displayedArtist: "Random Upload Channel",
            sourceChannel: "Random Upload Channel",
            userArtistOverride: nil,
            metadata: YouTubeResolutionMetadata(
                title: "A Song Without Artist Attribution",
                channel: "Random Upload Channel"
            ),
            source: .manualSearch,
            cache: cache
        )

        XCTAssertFalse(learned)
        XCTAssertEqual(cache.storeCount, 0)
    }

    func testLowConfidenceUploaderCannotReplaceLearnedIdentity() async {
        let cache = MemoryYouTubeResolutionCache()
        let videoID = "identity001"
        let trusted = await YouTubeResolutionKnowledgeTeacher.learnIfConfident(
            videoID: videoID,
            rawTitle: "Lana Del Rey- Wayamaya",
            displayedArtist: "zumra del rey",
            sourceChannel: "zumra del rey",
            userArtistOverride: nil,
            metadata: YouTubeResolutionMetadata(
                title: "Lana Del Rey- Wayamaya",
                channel: "zumra del rey"
            ),
            source: .manualSearch,
            cache: cache
        )
        let lowConfidence = await YouTubeResolutionKnowledgeTeacher.learnIfConfident(
            videoID: videoID,
            rawTitle: "Wayamaya",
            displayedArtist: "zumra del rey",
            sourceChannel: "zumra del rey",
            userArtistOverride: nil,
            metadata: YouTubeResolutionMetadata(
                title: "Wayamaya",
                channel: "zumra del rey"
            ),
            source: .manualSearch,
            cache: cache
        )

        XCTAssertTrue(trusted)
        XCTAssertFalse(lowConfidence)
        XCTAssertEqual(cache.storeCount, 1)
        let learned = await cache.learnedIdentity(forVideoID: videoID)
        XCTAssertEqual(learned, SongIdentity(artist: "Lana Del Rey", title: "Wayamaya"))
    }

    func testTemporaryStructuredFailureDoesNotDeleteKnownMapping() async throws {
        let identity = SongIdentity(artist: "Example Artist", title: "Example Song")
        let cache = MemoryYouTubeResolutionCache([
            identity: youtubeResult(
                videoID: "retain00001",
                artist: identity.artist,
                title: identity.title
            )
        ])
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in throw URLError(.timedOut) },
            dataAPISearch: { _ in [] }
        )

        _ = try await resolver.primaryResults(query: "temporary failure")

        let cached = await cache.peek(for: identity, now: .now)
        XCTAssertEqual(cached?.youtubeVideoID, "retain00001")
        XCTAssertEqual(cache.removeCount, 0)
    }

    func testPersistentCacheHandlesThousandsOfLongLivedMappings() async throws {
        struct Fixture: Codable {
            let videoID: String
            let canonicalArtist: String
            let canonicalTitle: String
            let youtubeTitle: String
            let channel: String
            let thumbnailURL: URL?
            let duration: TimeInterval?
            let source: String
            let resolvedAt: Date
            let lastAccessedAt: Date
            let lastValidatedAt: Date?
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shaudi-large-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var fixture: [String: Fixture] = [:]
        for index in 0..<2_000 {
            let identity = SongIdentity(artist: "Artist \(index)", title: "Song \(index)")
            fixture[identity.cacheKey] = Fixture(
                videoID: String(format: "v%010d", index),
                canonicalArtist: identity.artist,
                canonicalTitle: identity.title,
                youtubeTitle: "\(identity.artist) - \(identity.title)",
                channel: identity.artist,
                thumbnailURL: nil,
                duration: 180,
                source: "structured",
                resolvedAt: now,
                lastAccessedAt: now,
                lastValidatedAt: now
            )
        }
        try JSONEncoder().encode(fixture).write(to: fileURL, options: .atomic)
        let cache = PersistentYouTubeResolutionCache(
            fileURL: fileURL,
            policy: .init(maximumEntryCount: 2_500)
        )

        let entryCount = await cache.entryCount()
        let retained = await cache.peek(
            for: SongIdentity(artist: "Artist 1999", title: "Song 1999"),
            now: now.addingTimeInterval(365 * 24 * 60 * 60)
        )
        XCTAssertEqual(entryCount, 2_000)
        XCTAssertEqual(retained?.youtubeVideoID, "v0000001999")
    }

}
