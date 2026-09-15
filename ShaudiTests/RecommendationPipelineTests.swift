import XCTest
@testable import Shaudi

@MainActor
final class RecommendationPipelineTests: XCTestCase {
    func testMusicMetadataDecodesCommonHTMLEntitiesForDisplay() {
        XCTAssertEqual(
            MusicMetadataText.decoded("That&#39;s What You Get"),
            "That's What You Get"
        )
        XCTAssertEqual(
            MusicMetadataText.decoded("Rock &amp; Roll"),
            "Rock & Roll"
        )
        XCTAssertEqual(
            MusicMetadataText.decoded("&quot;Song&#x27;s Name&quot;"),
            "\"Song's Name\""
        )
    }

    func testMusicMetadataLeavesAlreadyDecodedTextUnchanged() {
        let value = "That's What You Get"

        XCTAssertEqual(MusicMetadataText.decoded(value), value)
    }

    func testParamoreOfficialVideoIdentity() {
        let seed = manualSeed(
            title: "Paramore - That's What You Get [OFFICIAL VIDEO]",
            channel: "Paramore"
        )

        XCTAssertEqual(seed.cleanedArtist, "Paramore")
        XCTAssertEqual(seed.cleanedTitle, "That's What You Get")
    }

    func testShakiraLyricsUploadUsesMusicalIdentity() {
        let seed = manualSeed(
            title: "Shakira - Hips Don't Lie (Lyrics) ft. Wyclef Jean",
            channel: "7clouds Rock"
        )

        XCTAssertEqual(seed.cleanedArtist, "Shakira")
        XCTAssertEqual(seed.cleanedTitle, "Hips Don't Lie")
        XCTAssertEqual(seed.fallbackTitle, "Hips Don't Lie ft. Wyclef Jean")
    }

    func testBanditUsesTitleArtistInsteadOfUploader() {
        let seed = manualSeed(
            title: "Juice WRLD - Bandit ft. NBA Youngboy (Official Music Video)",
            channel: "Lyrical Lemonade"
        )

        XCTAssertEqual(seed.cleanedArtist, "Juice WRLD")
        XCTAssertEqual(seed.cleanedTitle, "Bandit")
    }

    func testFamousDexTrailingProductionCreditIsRemoved() {
        for credit in [
            "(Prod. JGramm)", "(prod. JGramm)",
            "(Produced by JGramm)", "[Prod. JGramm]"
        ] {
            let seed = manualSeed(
                title: "Famous Dex - Japan \(credit) [Official Lyric Video]",
                channel: "Famous Dex"
            )

            XCTAssertEqual(seed.cleanedArtist, "Famous Dex")
            XCTAssertEqual(seed.cleanedTitle, "Japan")
        }
    }

    func testProductionCleanupDoesNotStripMusicalVersions() {
        for version in [
            "Acoustic", "Remix", "Live", "Remastered 2011", "From \"Movie\""
        ] {
            let seed = manualSeed(
                title: "Artist - Song (\(version))",
                channel: "Artist"
            )
            XCTAssertEqual(seed.cleanedTitle, "Song (\(version))")
        }
    }

    func testLastFMIdentityIsNotReparsed() {
        let seed = RecommendationSeed(
            youtubeVideoID: "abcdefghijk",
            canonicalIdentity: SongIdentity(
                artist: "Lil Peep",
                title: "Falling Down - Bonus Track"
            ),
            youtubeTitle: "Falling Down - Bonus Track",
            youtubeChannel: "Lil Peep"
        )

        XCTAssertEqual(seed.cleanedArtist, "Lil Peep")
        XCTAssertEqual(seed.cleanedTitle, "Falling Down - Bonus Track")
        XCTAssertEqual(seed.artistSource, .lastFM)
    }

    func testLastFMIdentityRemainsAuthoritativeThroughConfirmedPlayback() {
        var session = RecommendationRadioSession(anchor: banditSeed())
        for index in 1..<RecommendationRadioPolicy.epochLength {
            _ = session.confirmedRecommendationPlayback(seed: canonicalSeed(index: index))
        }
        let fallingDown = RecommendationSeed(
            youtubeVideoID: "falling0001",
            canonicalIdentity: SongIdentity(
                artist: "Lil Peep",
                title: "Falling Down - Bonus Track"
            ),
            youtubeTitle: "Lil Peep & XXXTENTACION - Falling Down (Official Video)",
            youtubeChannel: "Lil Peep"
        )

        guard case .startNewEpoch(_, let anchor) =
            session.confirmedRecommendationPlayback(seed: fallingDown) else {
            return XCTFail("Expected the confirmed track to become the next epoch anchor")
        }
        XCTAssertEqual(anchor.cleanedArtist, "Lil Peep")
        XCTAssertEqual(anchor.cleanedTitle, "Falling Down - Bonus Track")
        XCTAssertEqual(anchor.artistSource, .lastFM)
    }

    func testTopicChannelSuffixIsRemoved() {
        let seed = manualSeed(title: "A Song", channel: "Artist Name - Topic")

        XCTAssertEqual(seed.cleanedArtist, "Artist Name")
        XCTAssertEqual(seed.cleanedTitle, "A Song")
        XCTAssertEqual(seed.artistSource, .topicChannel)
    }

    func testCanonicalTitleContainingHyphenIsPreserved() {
        let seed = RecommendationSeed(
            youtubeVideoID: "abcdefghijk",
            canonicalIdentity: SongIdentity(
                artist: "An Artist",
                title: "Part One - Part Two"
            ),
            youtubeTitle: "Part One - Part Two",
            youtubeChannel: "An Artist"
        )

        XCTAssertEqual(seed.cleanedArtist, "An Artist")
        XCTAssertEqual(seed.cleanedTitle, "Part One - Part Two")
    }

    func testExplicitArtistOverridePreventsHyphenReparse() {
        let seed = RecommendationSeed(
            youtubeVideoID: "abcdefghijk",
            rawTitle: "Falling Down - Bonus Track",
            displayedArtist: "Uploader",
            sourceChannel: "Uploader",
            userArtistOverride: "Lil Peep"
        )

        XCTAssertEqual(seed.cleanedArtist, "Lil Peep")
        XCTAssertEqual(seed.cleanedTitle, "Falling Down - Bonus Track")
        XCTAssertEqual(seed.artistSource, .userOverride)
    }

    func testOfficialAudioAndVisualizerArePresentationOnly() {
        XCTAssertEqual(
            manualSeed(title: "Artist - Song (Official Audio)", channel: "Uploader").cleanedTitle,
            "Song"
        )
        XCTAssertEqual(
            manualSeed(title: "Artist - Song [Visualizer]", channel: "Uploader").cleanedTitle,
            "Song"
        )
    }

    func testFeaturedArtistProducesOneBoundedAlternate() {
        let seed = manualSeed(
            title: "Artist - Song feat. Guest",
            channel: "Uploader"
        )

        XCTAssertEqual(seed.cleanedTitle, "Song")
        XCTAssertEqual(seed.fallbackTitle, "Song feat. Guest")
        XCTAssertEqual(
            SongNormalization.baseTitle("Song (feat. Guest)"),
            SongNormalization.baseTitle("Song")
        )
    }

    func testHTMLEntitiesAndTypographyNormalizeForIdentity() {
        let html = SongIdentity(artist: "Guns N&#39; Roses", title: "Don&#39;t Cry")
        let unicode = SongIdentity(artist: "Guns N’ Roses", title: "Don’t Cry")

        XCTAssertEqual(html.artist, "Guns N' Roses")
        XCTAssertEqual(html, unicode)
        XCTAssertEqual(
            manualSeed(title: "Artist — Song [4K]", channel: "Uploader").cleanedTitle,
            "Song"
        )
    }

    func testTrackNotFoundPermitsOnlyBoundedSeedFallback() {
        let error = LastFMRecommendationService.ServiceError.api(
            code: 6,
            message: "Track not found"
        )
        let networkError = LastFMRecommendationService.ServiceError.network("offline")

        XCTAssertTrue(error.permitsAlternateSeedRetry)
        XCTAssertFalse(networkError.permitsAlternateSeedRetry)
    }

    func testYouTubeCanonicalMatchMissingIsRejected() {
        let wrongSong = YouTubeSearchResult(
            youtubeVideoID: "abcdefghijk",
            title: "Artist - Completely Different Song (Official Video)",
            channelTitle: "Artist",
            thumbnailURL: nil
        )
        let target = LastFMSimilarTrack(
            artist: "Artist",
            title: "Wanted Song",
            match: 1,
            url: nil
        )

        XCTAssertNil(RecommendationService().youtubeScore(wrongSong, target: target))
    }

    func testHarmlessYouTubeFormattingStillMatchesCanonicalSong() {
        let result = YouTubeSearchResult(
            youtubeVideoID: "abcdefghijk",
            title: "Guns N’ Roses – Sweet Child O&#39; Mine (Official 4K Video)",
            channelTitle: "Guns N' Roses",
            thumbnailURL: nil
        )
        let target = LastFMSimilarTrack(
            artist: "Guns N' Roses",
            title: "Sweet Child O' Mine",
            match: 1,
            url: nil
        )

        XCTAssertNotNil(RecommendationService().youtubeScore(result, target: target))
    }

    func testDataAPIQuotaOpensCircuitAfterOneRequest() async throws {
        var requestCount = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in [] },
            dataAPISearch: { _ in
                requestCount += 1
                throw YouTubeMetadataClient.ClientError.quotaExceeded
            }
        )

        let first = try await resolver.dataAPIFallbackResults(query: "Artist Song")
        let second = try await resolver.dataAPIFallbackResults(query: "Another Song")

        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(resolver.isDataAPIQuotaCircuitOpen)
    }

    func testTooManyRedirectsOpensWebCircuitAfterOneRequest() async throws {
        var requestCount = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in
                requestCount += 1
                throw URLError(.httpTooManyRedirects)
            },
            dataAPISearch: { _ in [] }
        )

        let first = try await resolver.primaryResults(query: "First")
        let second = try await resolver.primaryResults(query: "Second")
        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(resolver.isWebSearchCircuitOpen)
    }

    func testHTTP429OpensWebCircuitAfterOneRequest() async throws {
        var requestCount = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in
                requestCount += 1
                throw YouTubeWebSearchClient.SearchError.httpStatus(429)
            },
            dataAPISearch: { _ in [] }
        )

        _ = try await resolver.primaryResults(query: "First")
        _ = try await resolver.primaryResults(query: "Second")
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(resolver.isWebSearchCircuitOpen)
    }

    func testWebAbuseChallengeURLIsRecognized() {
        XCTAssertTrue(YouTubeWebSearchClient.isAbuseChallengeURL(
            URL(string: "https://www.google.com/sorry/index?continue=youtube")
        ))
        XCTAssertFalse(YouTubeWebSearchClient.isAbuseChallengeURL(
            URL(string: "https://www.youtube.com/results?search_query=Song")
        ))
    }

    func testBothResolverCircuitsOpenWithoutRepeatedAttempts() async throws {
        var webRequestCount = 0
        var dataAPIRequestCount = 0
        let originalQueue = ["already-queued-1", "already-queued-2"]
        var queue = originalQueue
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in
                webRequestCount += 1
                throw URLError(.httpTooManyRedirects)
            },
            dataAPISearch: { _ in
                dataAPIRequestCount += 1
                throw YouTubeMetadataClient.ClientError.quotaExceeded
            }
        )

        for query in ["First", "Second", "Third"] {
            let web = try await resolver.primaryResults(query: query)
            let dataAPI = try await resolver.dataAPIFallbackResults(query: query)
            if !web.isEmpty || !dataAPI.isEmpty {
                queue.append(query)
            }
        }

        XCTAssertEqual(webRequestCount, 1)
        XCTAssertEqual(dataAPIRequestCount, 1)
        XCTAssertEqual(queue, originalQueue)
    }

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
        let result = youtubeResult(
            videoID: "cachemiss01",
            artist: target.artist,
            title: target.title
        )
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in webRequests += 1; return [result] },
            dataAPISearch: { _ in [] }
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

    func testPersistentVideoCacheReloadsExpiresAndEvictsLRU() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shaudi-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let policy = PersistentYouTubeResolutionCache.Policy(
            timeToLive: 100,
            maximumEntryCount: 2
        )
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
        let expired = await reloaded.result(for: third, now: baseDate.addingTimeInterval(200))

        XCTAssertNil(evicted)
        XCTAssertEqual(retained?.youtubeVideoID, "persist0003")
        XCTAssertNil(expired)
    }

    func testCandidateResolutionFailureAdvancesToNextReservoirCandidate() async throws {
        let cache = MemoryYouTubeResolutionCache()
        var webRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { query in
                webRequests += 1
                guard query.contains("Working Song") else { return [] }
                return [self.youtubeResult(
                    videoID: "working0001",
                    artist: "Artist B",
                    title: "Working Song"
                )]
            },
            dataAPISearch: { _ in [] }
        )
        let service = RecommendationService(
            similarTracks: { _, _, _ in [] },
            videoResolver: resolver,
            resolutionCache: cache
        )

        let resolved = try await service.recommendationsFromReservoir(
            [candidate("Artist A", "Broken Song"), candidate("Artist B", "Working Song")],
            desiredCount: 1,
            excludingVideoIDs: [],
            excludingSongIdentities: []
        )

        XCTAssertEqual(resolved.map(\.title), ["Working Song"])
        XCTAssertEqual(webRequests, 2)
    }

    func testAnchoredEpochDoesNotReseedRecommendationsOneThroughTwenty() {
        var session = RecommendationRadioSession(anchor: banditSeed())
        var lastFMCallCount = session.markEpochCandidateRequestStarted(
            epochID: session.epoch.id
        ) ? 1 : 0

        for index in 1...20 {
            let action = session.confirmedRecommendationPlayback(
                seed: canonicalSeed(index: index)
            )
            if case .startNewEpoch = action {
                lastFMCallCount += 1
            }
            if [1, 5, 20].contains(index) {
                XCTAssertEqual(lastFMCallCount, 1)
                XCTAssertEqual(session.epoch.anchor.cleanedTitle, "Bandit")
            }
        }
    }

    func testEpochBoundaryUsesCurrentRecommendationAsNewAnchor() {
        var session = RecommendationRadioSession(anchor: banditSeed())
        var lastFMCallCount = session.markEpochCandidateRequestStarted(
            epochID: session.epoch.id
        ) ? 1 : 0
        var boundaryAnchor: RecommendationSeed?

        for index in 1...RecommendationRadioPolicy.epochLength {
            let current = canonicalSeed(index: index)
            if case .startNewEpoch(let epochID, let anchor) =
                session.confirmedRecommendationPlayback(seed: current) {
                boundaryAnchor = anchor
                if session.markEpochCandidateRequestStarted(epochID: epochID) {
                    lastFMCallCount += 1
                }
            }
        }

        XCTAssertEqual(boundaryAnchor?.cleanedTitle, "Song 24")
        XCTAssertEqual(session.epoch.anchor.cleanedTitle, "Song 24")
        XCTAssertEqual(session.epoch.consumedRecommendationCount, 0)
        XCTAssertEqual(lastFMCallCount, 2)
    }

    func testReservoirRefillUsesSameEpochWithoutLastFMRequest() {
        var session = RecommendationRadioSession(anchor: banditSeed())
        var lastFMCallCount = session.markEpochCandidateRequestStarted(
            epochID: session.epoch.id
        ) ? 1 : 0
        let candidates = (1...50).map { candidate("Artist \($0)", "Song \($0)") }
        XCTAssertTrue(session.replaceReservoir(candidates, epochID: session.epoch.id))

        let refill = session.takeReservoirCandidates(upTo: 3, epochID: session.epoch.id)
        if session.markEpochCandidateRequestStarted(epochID: session.epoch.id) {
            lastFMCallCount += 1
        }

        XCTAssertEqual(refill.count, 3)
        XCTAssertEqual(session.reservoirCount, 47)
        XCTAssertEqual(lastFMCallCount, 1)
    }

    func testSessionDeduplicationCrossesEpochBoundary() {
        let repeated = SongIdentity(artist: "Earlier Artist", title: "Earlier Song")
        var session = RecommendationRadioSession(anchor: banditSeed())
        session.recordSeen(repeated)
        for index in 1...RecommendationRadioPolicy.epochLength {
            _ = session.confirmedRecommendationPlayback(seed: canonicalSeed(index: index))
        }
        XCTAssertTrue(session.replaceReservoir(
            [
                LastFMSimilarTrack(
                    artist: repeated.artist,
                    title: repeated.title,
                    match: 1,
                    url: nil
                ),
                candidate("Fresh Artist", "Fresh Song")
            ],
            epochID: session.epoch.id
        ))

        XCTAssertEqual(
            session.takeReservoirCandidates(upTo: 2, epochID: session.epoch.id).map(\.title),
            ["Fresh Song"]
        )
    }

    func testStaleEpochResultCannotReplaceCurrentReservoir() {
        var session = RecommendationRadioSession(anchor: banditSeed())
        let staleEpochID = session.epoch.id
        for index in 1...RecommendationRadioPolicy.epochLength {
            _ = session.confirmedRecommendationPlayback(seed: canonicalSeed(index: index))
        }

        XCTAssertFalse(session.replaceReservoir(
            [candidate("Stale", "Result")],
            epochID: staleEpochID
        ))
        XCTAssertEqual(session.reservoirCount, 0)
    }

    func testFiftyTrackMockedRadioSessionUsesThreeLastFMRequests() async throws {
        let harness = MockRecommendationRadioHarness(anchor: banditSeed())
        try await harness.start()

        for _ in 0..<50 {
            try await harness.consumeNext()
        }

        XCTAssertEqual(harness.lastFMCallCount, 3)
        XCTAssertEqual(harness.tagRequestCount, 0)
        XCTAssertEqual(harness.consumedIdentities.count, 50)
        XCTAssertEqual(Set(harness.consumedIdentities).count, 50)
        XCTAssertLessThanOrEqual(harness.maxUpcomingCount, 6)
        XCTAssertLessThanOrEqual(harness.history.count, 6)
        XCTAssertFalse(harness.upcoming.isEmpty)
        XCTAssertEqual(harness.requestedLimits, [50, 50, 50])
    }

    func testStaleRecommendationSessionTokenIsRejected() {
        let expected = UUID()

        XCTAssertFalse(RecommendationSessionValidity.accepts(
            expectedToken: expected,
            activeToken: UUID(),
            origin: .recommendations
        ))
        XCTAssertTrue(RecommendationSessionValidity.accepts(
            expectedToken: expected,
            activeToken: expected,
            origin: .recommendations
        ))
        XCTAssertFalse(RecommendationSessionValidity.accepts(
            expectedToken: expected,
            activeToken: expected,
            origin: .library
        ))
    }

    func testReservoirDedupesPlayedCandidatesAndContinuesAfterSeedFailure() {
        let played = SongIdentity(artist: "Artist A", title: "Song A")
        var reservoir = RecommendationCandidateReservoir()
        reservoir.store(
            [
                candidate("Artist A", "Song A"),
                candidate("Artist B", "Song B"),
                candidate("Artist B", "Song B"),
                candidate("Artist C", "Song C")
            ],
            excluding: [played],
            limit: 3
        )

        let fallback = reservoir.take(upTo: 1)

        XCTAssertEqual(fallback.count, 1)
        XCTAssertEqual(fallback.first?.artist, "Artist B")
        XCTAssertEqual(reservoir.count, 1)
    }

    private func manualSeed(title: String, channel: String) -> RecommendationSeed {
        RecommendationSeed(
            youtubeVideoID: "abcdefghijk",
            rawTitle: title,
            displayedArtist: channel,
            sourceChannel: channel,
            userArtistOverride: nil
        )
    }

    private func candidate(_ artist: String, _ title: String) -> LastFMSimilarTrack {
        LastFMSimilarTrack(artist: artist, title: title, match: 1, url: nil)
    }

    private func banditSeed() -> RecommendationSeed {
        RecommendationSeed(
            youtubeVideoID: "bandit00001",
            canonicalIdentity: SongIdentity(artist: "Juice WRLD", title: "Bandit"),
            youtubeTitle: "Juice WRLD - Bandit (Official Music Video)",
            youtubeChannel: "Lyrical Lemonade"
        )
    }

    private func canonicalSeed(index: Int) -> RecommendationSeed {
        RecommendationSeed(
            youtubeVideoID: String(format: "s%010d", index),
            canonicalIdentity: SongIdentity(artist: "Artist \(index)", title: "Song \(index)"),
            youtubeTitle: "Artist \(index) - Song \(index)",
            youtubeChannel: "Artist \(index)"
        )
    }

    private func youtubeResult(
        videoID: String,
        artist: String,
        title: String
    ) -> YouTubeSearchResult {
        YouTubeSearchResult(
            youtubeVideoID: videoID,
            title: "\(artist) - \(title) (Official Audio)",
            channelTitle: artist,
            thumbnailURL: nil
        )
    }
}

@MainActor
private final class MemoryYouTubeResolutionCache: YouTubeResolutionCaching {
    private var storage: [SongIdentity: YouTubeSearchResult]
    private(set) var storeCount = 0
    private(set) var removeCount = 0

    init() {
        storage = [:]
    }

    init(_ storage: [SongIdentity: YouTubeSearchResult]) {
        self.storage = storage
    }

    func result(for identity: SongIdentity, now: Date) async -> YouTubeSearchResult? {
        storage[identity]
    }

    func store(
        _ result: YouTubeSearchResult,
        for identity: SongIdentity,
        now: Date
    ) async {
        storeCount += 1
        storage[identity] = result
    }

    func remove(_ identity: SongIdentity) async {
        removeCount += 1
        storage[identity] = nil
    }
}

@MainActor
private final class MockRecommendationRadioHarness {
    private final class FixtureState {
        var lastFMCallCount = 0
        var requestedLimits: [Int] = []
        var nextVideoNumber = 1
        var searchResults: [String: YouTubeSearchResult] = [:]
    }

    private let fixture: FixtureState
    private let service: RecommendationService
    private(set) var session: RecommendationRadioSession
    private(set) var upcoming: [ResolvedRecommendation] = []
    private(set) var history: [SongIdentity] = []
    private(set) var consumedIdentities: [SongIdentity] = []
    private(set) var maxUpcomingCount = 0
    let tagRequestCount = 0

    var lastFMCallCount: Int { fixture.lastFMCallCount }
    var requestedLimits: [Int] { fixture.requestedLimits }

    init(anchor: RecommendationSeed) {
        let fixture = FixtureState()
        self.fixture = fixture
        session = RecommendationRadioSession(anchor: anchor)
        let cache = MemoryYouTubeResolutionCache()
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { query in
                fixture.searchResults[query].map { [$0] } ?? []
            },
            dataAPISearch: { _ in [] }
        )
        service = RecommendationService(
            similarTracks: { _, _, limit in
                fixture.lastFMCallCount += 1
                fixture.requestedLimits.append(limit)
                return (1...50).map { index in
                    let number = fixture.nextVideoNumber
                    fixture.nextVideoNumber += 1
                    let artist = "Epoch \(fixture.lastFMCallCount) Artist \(index)"
                    let title = "Epoch \(fixture.lastFMCallCount) Song \(index)"
                    let videoID = String(format: "m%010d", number)
                    fixture.searchResults["\(artist) \(title)"] = YouTubeSearchResult(
                        youtubeVideoID: videoID,
                        title: "\(artist) - \(title) (Official Audio)",
                        channelTitle: artist,
                        thumbnailURL: nil
                    )
                    return LastFMSimilarTrack(
                        artist: artist,
                        title: title,
                        match: 1 - Double(index) / 100,
                        url: nil
                    )
                }
            },
            videoResolver: resolver,
            resolutionCache: cache
        )
    }

    func start() async throws {
        try await loadCurrentEpoch()
        try await replenishIfNeeded()
    }

    func consumeNext() async throws {
        if upcoming.isEmpty {
            try await replenishIfNeeded()
        }
        let current = try XCTUnwrap(upcoming.first)
        upcoming.removeFirst()
        consumedIdentities.append(current.songIdentity)
        history.append(current.songIdentity)
        history = Array(history.suffix(RecommendationRadioPolicy.historyQueueLimit))

        let seed = RecommendationSeed(
            youtubeVideoID: current.youtubeResult.youtubeVideoID,
            canonicalIdentity: current.songIdentity,
            youtubeTitle: current.youtubeResult.title,
            youtubeChannel: current.youtubeResult.channelTitle
        )
        let action = session.confirmedRecommendationPlayback(seed: seed)
        if case .startNewEpoch = action {
            try await loadCurrentEpoch()
        }
        try await replenishIfNeeded()
    }

    private func loadCurrentEpoch() async throws {
        let epochID = session.epoch.id
        guard session.markEpochCandidateRequestStarted(epochID: epochID) else {
            return
        }
        let batch = try await service.recommendations(
            for: session.epoch.anchor,
            excludingVideoIDs: Set(upcoming.map { $0.youtubeResult.youtubeVideoID }),
            excludingSongIdentities: session.globalPlayedSongIdentities
        )
        XCTAssertTrue(session.replaceReservoir(batch.reservoirCandidates, epochID: epochID))
        append(batch.recommendations)
    }

    private func replenishIfNeeded() async throws {
        let desired = RecommendationRadioPolicy.targetUpcomingCount - upcoming.count
        guard desired > 0 else { return }
        let candidates = session.takeReservoirCandidates(
            upTo: 8,
            epochID: session.epoch.id
        )
        let resolution = try await service.resolveReservoirCandidates(
            candidates,
            desiredCount: desired,
            excludingVideoIDs: Set(upcoming.map { $0.youtubeResult.youtubeVideoID }),
            excludingSongIdentities: session.globalPlayedSongIdentities
        )
        XCTAssertTrue(session.returnUnusedReservoirCandidates(
            resolution.unusedCandidates,
            epochID: session.epoch.id
        ))
        append(resolution.recommendations)
    }

    private func append(_ results: [ResolvedRecommendation]) {
        for result in results where !session.globalPlayedSongIdentities.contains(result.songIdentity) {
            upcoming.append(result)
            session.recordSeen(result.songIdentity)
        }
        upcoming = Array(upcoming.prefix(RecommendationRadioPolicy.upcomingQueueLimit))
        maxUpcomingCount = max(maxUpcomingCount, upcoming.count)
    }
}
