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

    func testGenreAliasesNormalizeToCanonicalGenres() {
        XCTAssertEqual(GenreTagNormalizer.normalizedGenre(for: "hip hop"), "Hip-Hop")
        XCTAssertEqual(GenreTagNormalizer.normalizedGenre(for: "hip-hop"), "Hip-Hop")
        XCTAssertEqual(GenreTagNormalizer.normalizedGenre(for: "hiphop"), "Hip-Hop")
        XCTAssertEqual(GenreTagNormalizer.normalizedGenre(for: "rnb"), "R&B")
        XCTAssertEqual(GenreTagNormalizer.normalizedGenre(for: "r&b"), "R&B")
        XCTAssertEqual(GenreTagNormalizer.normalizedGenre(for: "rhythm and blues"), "R&B")
        XCTAssertEqual(GenreTagNormalizer.normalizedGenre(for: "pop punk"), "Pop Punk")
    }

    func testNonGenreTagsAreIgnoredAndAliasesCollapse() {
        let genres = GenreTagNormalizer.normalizedGenres(from: [
            GenreTag(name: "seen live", weight: 100),
            GenreTag(name: "favorites", weight: 90),
            GenreTag(name: "female vocalists", weight: 80),
            GenreTag(name: "2010s", weight: 70),
            GenreTag(name: "hip hop", weight: 60),
            GenreTag(name: "hip-hop", weight: 50)
        ])

        XCTAssertEqual(genres, ["Hip-Hop"])
    }

    func testGenreTagsRetainAtMostThreeStrongestGenres() {
        let genres = GenreTagNormalizer.normalizedGenres(from: [
            GenreTag(name: "pop", weight: 10),
            GenreTag(name: "hip hop", weight: 40),
            GenreTag(name: "trap", weight: 30),
            GenreTag(name: "r&b", weight: 20)
        ])

        XCTAssertEqual(genres, ["Hip-Hop", "Trap", "R&B"])
    }

    func testGenreListeningTimeIsDistributedWithoutMultiplyingDuration() {
        let favorites = FavoriteGenreCalculator.favorites(from: [
            (genres: ["Hip-Hop", "Trap"], listeningDuration: 300)
        ])

        XCTAssertEqual(favorites.reduce(0) { $0 + $1.listeningDuration }, 300, accuracy: 0.001)
        XCTAssertEqual(Set(favorites.map(\.name)), Set(["Hip-Hop", "Trap"]))
        XCTAssertEqual(Set(favorites.map(\.percentage)), Set([50]))
    }

    func testFavoriteGenresSortAndPercentagesUseClassifiedListeningTime() {
        let favorites = FavoriteGenreCalculator.favorites(from: [
            (genres: ["Hip-Hop"], listeningDuration: 300),
            (genres: ["Pop"], listeningDuration: 100),
            (genres: [], listeningDuration: 600)
        ])

        XCTAssertEqual(favorites.map(\.name), ["Hip-Hop", "Pop"])
        XCTAssertEqual(favorites.map(\.percentage), [75, 25])
    }

    func testGenreLookupUsesCachedResultWithoutCallingFetcher() async {
        let fetcher = FakeGenreTagFetcher(result: .success([GenreTag(name: "pop", weight: 1)]))
        let coordinator = GenreLookupCoordinator()
        let result = await coordinator.lookup(
            cacheState: GenreTagCacheState(
                genres: ["Pop"],
                fetchedAt: .now,
                lastAttemptAt: .now
            ),
            cacheKey: "artist-song",
            artist: "Artist",
            title: "Song",
            fetcher: fetcher
        )

        XCTAssertEqual(result, .cached)
        let callCount = await fetcher.calls()
        XCTAssertEqual(callCount, 0)
    }

    func testUncachedGenreLookupCallsFetcherOnceAndCachesEmptyResult() async {
        let fetcher = FakeGenreTagFetcher(result: .success([]))
        let coordinator = GenreLookupCoordinator()
        let emptyCache = GenreTagCacheState(genres: [], fetchedAt: nil, lastAttemptAt: nil)
        let result = await coordinator.lookup(
            cacheState: emptyCache,
            cacheKey: "artist-song",
            artist: "Artist",
            title: "Song",
            fetcher: fetcher
        )

        XCTAssertEqual(result, .success([]))
        var callCount = await fetcher.calls()
        XCTAssertEqual(callCount, 1)

        let cachedEmpty = GenreTagCacheState(
            genres: [],
            fetchedAt: .now,
            lastAttemptAt: .now
        )
        let retry = await coordinator.lookup(
            cacheState: cachedEmpty,
            cacheKey: "artist-song",
            artist: "Artist",
            title: "Song",
            fetcher: fetcher
        )
        XCTAssertEqual(retry, .cached)
        callCount = await fetcher.calls()
        XCTAssertEqual(callCount, 1)
    }

    func testSimultaneousGenreLookupTriggersOnlyOneFetcherCall() async {
        let fetcher = FakeGenreTagFetcher(
            result: .success([GenreTag(name: "pop", weight: 1)]),
            delayNanoseconds: 50_000_000
        )
        let coordinator = GenreLookupCoordinator()
        let state = GenreTagCacheState(genres: [], fetchedAt: nil, lastAttemptAt: nil)

        async let first = coordinator.lookup(
            cacheState: state,
            cacheKey: "artist-song",
            artist: "Artist",
            title: "Song",
            fetcher: fetcher
        )
        async let second = coordinator.lookup(
            cacheState: state,
            cacheKey: "artist-song",
            artist: "Artist",
            title: "Song",
            fetcher: fetcher
        )
        let results = await [first, second]

        XCTAssertTrue(results.contains(.success(["Pop"])))
        XCTAssertTrue(results.contains(.inFlight))
        let callCount = await fetcher.calls()
        XCTAssertEqual(callCount, 1)
    }

    func testGenreLookupFailureDefersRetryWithoutChangingCachedGenres() async {
        let fetcher = FakeGenreTagFetcher(result: .failure(FakeGenreTagFetcher.Error.offline))
        let coordinator = GenreLookupCoordinator()
        let result = await coordinator.lookup(
            cacheState: GenreTagCacheState(genres: [], fetchedAt: nil, lastAttemptAt: nil),
            cacheKey: "artist-song",
            artist: "Artist",
            title: "Song",
            fetcher: fetcher
        )

        XCTAssertEqual(result, .failed)
        let failedCache = GenreTagCacheState(genres: [], fetchedAt: nil, lastAttemptAt: .now)
        let retry = await coordinator.lookup(
            cacheState: failedCache,
            cacheKey: "artist-song",
            artist: "Artist",
            title: "Song",
            fetcher: fetcher
        )
        XCTAssertEqual(retry, .retryDeferred)
        let callCount = await fetcher.calls()
        XCTAssertEqual(callCount, 1)
    }

    func testDefaultGenreCacheStateAndUnclassifiedListeningAreSafe() {
        let defaultCache = GenreTagCacheState(
            genres: [],
            fetchedAt: nil,
            lastAttemptAt: nil
        )

        XCTAssertEqual(defaultCache.lookupDecision(), .lookup)
        XCTAssertTrue(
            FavoriteGenreCalculator.favorites(
                from: [(genres: [], listeningDuration: 300)]
            ).isEmpty
        )
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
            },
            fallbackBudget: isolatedFallbackBudget()
        )
        let context = resolutionContext()

        let first = try await resolver.dataAPIFallbackResults(
            query: "Artist Song",
            context: context
        )
        let second = try await resolver.dataAPIFallbackResults(
            query: "Another Song",
            context: context
        )

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

    func testCandidateSpecificWebMissDoesNotOpenCircuit() async throws {
        var requestCount = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in requestCount += 1; return [] },
            dataAPISearch: { _ in [] }
        )

        _ = try await resolver.primaryResults(query: "First")
        _ = try await resolver.primaryResults(query: "Second")

        XCTAssertEqual(requestCount, 2)
        XCTAssertFalse(resolver.isWebSearchCircuitOpen)
    }

    func testWebCircuitCooldownAllowsHalfOpenProbeAndSuccessfulRecovery() async throws {
        var date = Date(timeIntervalSince1970: 10_000)
        var requestCount = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in
                requestCount += 1
                if requestCount == 1 {
                    throw URLError(.httpTooManyRedirects)
                }
                return []
            },
            dataAPISearch: { _ in [] },
            now: { date }
        )

        _ = try await resolver.primaryOutcome(query: "blocked")
        date.addTimeInterval(RecommendationRadioPolicy.webCircuitCooldown - 1)
        let blocked = try await resolver.primaryOutcome(query: "too early")
        if case .circuitOpen = blocked {} else {
            XCTFail("Expected the circuit to remain open before cooldown")
        }
        XCTAssertEqual(requestCount, 1)

        date.addTimeInterval(2)
        _ = try await resolver.primaryOutcome(query: "probe")
        XCTAssertFalse(resolver.isWebSearchCircuitOpen)
        _ = try await resolver.primaryOutcome(query: "normal")
        XCTAssertEqual(requestCount, 3)
    }

    func testHalfOpenSystemicFailureReopensCircuit() async throws {
        var date = Date(timeIntervalSince1970: 20_000)
        var requestCount = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in
                requestCount += 1
                throw URLError(.httpTooManyRedirects)
            },
            dataAPISearch: { _ in [] },
            now: { date }
        )

        _ = try await resolver.primaryOutcome(query: "initial")
        date.addTimeInterval(RecommendationRadioPolicy.webCircuitCooldown + 1)
        _ = try await resolver.primaryOutcome(query: "failed probe")
        _ = try await resolver.primaryOutcome(query: "blocked again")

        XCTAssertEqual(requestCount, 2)
        XCTAssertTrue(resolver.isWebSearchCircuitOpen)
    }

    func testOnlyOneHalfOpenProbeCanRun() async throws {
        var date = Date(timeIntervalSince1970: 30_000)
        var requestCount = 0
        let gate = AsyncSearchGate()
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in
                requestCount += 1
                if requestCount == 1 {
                    throw URLError(.httpTooManyRedirects)
                }
                await gate.suspendUntilReleased()
                return []
            },
            dataAPISearch: { _ in [] },
            now: { date }
        )
        _ = try await resolver.primaryOutcome(query: "initial")
        date.addTimeInterval(RecommendationRadioPolicy.webCircuitCooldown + 1)

        let probe = Task { try await resolver.primaryOutcome(query: "probe") }
        await gate.waitUntilStarted()
        let simultaneous = try await resolver.primaryOutcome(query: "simultaneous")
        if case .circuitOpen = simultaneous {} else {
            XCTFail("Expected a second half-open request to be rejected")
        }
        XCTAssertEqual(requestCount, 2)
        await gate.release()
        _ = try await probe.value
    }

    func testTransientNetworkFailureRecoversAfterShortCooldown() async throws {
        var date = Date(timeIntervalSince1970: 40_000)
        var requestCount = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in
                requestCount += 1
                if requestCount == 1 {
                    throw URLError(.timedOut)
                }
                return []
            },
            dataAPISearch: { _ in [] },
            now: { date }
        )

        _ = try await resolver.primaryOutcome(query: "timeout")
        _ = try await resolver.primaryOutcome(query: "temporarily blocked")
        XCTAssertEqual(requestCount, 1)
        date.addTimeInterval(RecommendationRadioPolicy.transientWebCooldown + 1)
        _ = try await resolver.primaryOutcome(query: "probe")

        XCTAssertEqual(requestCount, 2)
        XCTAssertFalse(resolver.isWebSearchCircuitOpen)
    }

    func testSystemicWebFailureDoesNotRepeatedlyInvokeWebOrDataAPI() async throws {
        var webRequests = 0
        var dataAPIRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in
                webRequests += 1
                throw URLError(.httpTooManyRedirects)
            },
            dataAPISearch: { _ in
                dataAPIRequests += 1
                return []
            },
            fallbackBudget: isolatedFallbackBudget()
        )
        let context = resolutionContext()

        for index in 0..<20 {
            _ = try await resolver.primaryResults(query: "Song \(index)")
            _ = try await resolver.dataAPIFallbackResults(
                query: "Song \(index)",
                context: context
            )
        }

        XCTAssertEqual(webRequests, 1)
        XCTAssertEqual(dataAPIRequests, 2)
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
            },
            fallbackBudget: isolatedFallbackBudget()
        )
        let context = resolutionContext()

        for query in ["First", "Second", "Third"] {
            let web = try await resolver.primaryResults(query: query)
            let dataAPI = try await resolver.dataAPIFallbackResults(
                query: query,
                context: context
            )
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

    func testHealthyBufferSkipsOfficialFallbackAndUsesReservoirAlternative() async throws {
        let cache = MemoryYouTubeResolutionCache()
        var webRequests = 0
        var dataAPIRequests = 0
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
            dataAPISearch: { _ in dataAPIRequests += 1; return [] },
            fallbackBudget: isolatedFallbackBudget()
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
            excludingSongIdentities: [],
            context: resolutionContext(upcomingCount: 2)
        )

        XCTAssertEqual(resolved.map(\.title), ["Working Song"])
        XCTAssertEqual(webRequests, 2)
        XCTAssertEqual(dataAPIRequests, 0)
    }

    func testCriticalBufferAllowsOfficialFallbackAndCachesResult() async throws {
        let target = candidate("Artist", "Emergency Song")
        let cache = MemoryYouTubeResolutionCache()
        var webRequests = 0
        var dataAPIRequests = 0
        let official = youtubeResult(
            videoID: "emergency01",
            artist: target.artist,
            title: target.title
        )
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in webRequests += 1; return [] },
            dataAPISearch: { _ in dataAPIRequests += 1; return [official] },
            fallbackBudget: isolatedFallbackBudget()
        )
        let service = RecommendationService(
            similarTracks: { _, _, _ in [] },
            videoResolver: resolver,
            resolutionCache: cache
        )
        let context = resolutionContext(upcomingCount: 1)

        let resolved = try await service.recommendationsFromReservoir(
            [target],
            desiredCount: 1,
            excludingVideoIDs: [],
            excludingSongIdentities: [],
            context: context
        )
        let second = try await service.resolveOnYouTube(target)

        XCTAssertEqual(resolved.first?.youtubeResult.youtubeVideoID, "emergency01")
        XCTAssertEqual(second?.youtubeResult.youtubeVideoID, "emergency01")
        XCTAssertEqual(webRequests, 1)
        XCTAssertEqual(dataAPIRequests, 1)
        XCTAssertEqual(cache.storeCount, 1)
    }

    func testHealthyBufferDirectlyBlocksOfficialFallback() async throws {
        var dataAPIRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in [] },
            dataAPISearch: { _ in dataAPIRequests += 1; return [] },
            fallbackBudget: isolatedFallbackBudget()
        )

        let results = try await resolver.dataAPIFallbackResults(
            query: "Artist Song",
            context: resolutionContext(upcomingCount: 2)
        )

        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(dataAPIRequests, 0)
    }

    func testPerEpochOfficialFallbackLimitIsTwo() async throws {
        var dataAPIRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in [] },
            dataAPISearch: { _ in dataAPIRequests += 1; return [] },
            fallbackBudget: isolatedFallbackBudget()
        )
        let context = resolutionContext()

        for index in 0..<12 {
            _ = try await resolver.dataAPIFallbackResults(
                query: "Song \(index)",
                context: context
            )
        }

        XCTAssertEqual(dataAPIRequests, 2)
    }

    func testRadioSessionOfficialFallbackLimitIsSixAcrossEpochs() async throws {
        var dataAPIRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in [] },
            dataAPISearch: { _ in dataAPIRequests += 1; return [] },
            fallbackBudget: isolatedFallbackBudget()
        )
        let sessionID = UUID()

        for _ in 0..<4 {
            let context = resolutionContext(sessionID: sessionID)
            for index in 0..<4 {
                _ = try await resolver.dataAPIFallbackResults(
                    query: "Song \(index)",
                    context: context
                )
            }
        }

        XCTAssertEqual(dataAPIRequests, 6)
    }

    func testNewSeedResetsSessionBudgetButPreservesDailyUsage() {
        let budget = RecommendationDataAPIFallbackBudget(defaults: isolatedUserDefaults())
        let firstSession = UUID()
        for _ in 0..<3 {
            let epochID = UUID()
            _ = budget.reserveFallback(sessionID: firstSession, epochID: epochID)
            _ = budget.reserveFallback(sessionID: firstSession, epochID: epochID)
        }
        let newSessionReservation = budget.reserveFallback(
            sessionID: UUID(),
            epochID: UUID()
        )

        guard case .success(let usage) = newSessionReservation else {
            return XCTFail("Expected a new radio session allowance")
        }
        XCTAssertEqual(usage.session, 1)
        XCTAssertEqual(usage.daily, 7)
    }

    func testDailyBudgetPersistsAcrossResolverInstances() async throws {
        let defaults = isolatedUserDefaults()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var dataAPIRequests = 0

        for _ in 0..<2 {
            let budget = RecommendationDataAPIFallbackBudget(
                defaults: defaults,
                now: { date }
            )
            let resolver = YouTubeRecommendationResolver(
                primarySearch: { _ in [] },
                dataAPISearch: { _ in dataAPIRequests += 1; return [] },
                fallbackBudget: budget
            )
            for _ in 0..<3 {
                let context = resolutionContext()
                for index in 0..<2 {
                    _ = try await resolver.dataAPIFallbackResults(
                        query: "Song \(index)",
                        context: context
                    )
                }
            }
        }

        let restartedBudget = RecommendationDataAPIFallbackBudget(
            defaults: defaults,
            now: { date }
        )
        let restartedResolver = YouTubeRecommendationResolver(
            primarySearch: { _ in [] },
            dataAPISearch: { _ in dataAPIRequests += 1; return [] },
            fallbackBudget: restartedBudget
        )
        _ = try await restartedResolver.dataAPIFallbackResults(
            query: "Blocked after restart",
            context: resolutionContext()
        )

        XCTAssertEqual(dataAPIRequests, 10)
        XCTAssertEqual(restartedBudget.dailyCount(), 10)
    }

    func testDailyBudgetResetsOnCalendarDayChange() {
        let defaults = isolatedUserDefaults()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var date = Date(timeIntervalSince1970: 1_704_110_400)
        let budget = RecommendationDataAPIFallbackBudget(
            defaults: defaults,
            calendar: calendar,
            now: { date }
        )

        if case .failure = budget.reserveFallback(sessionID: UUID(), epochID: UUID()) {
            XCTFail("Expected fallback reservation")
        }
        XCTAssertEqual(budget.dailyCount(), 1)
        date = calendar.date(byAdding: .day, value: 1, to: date)!

        XCTAssertEqual(budget.dailyCount(), 0)
        if case .failure = budget.reserveFallback(sessionID: UUID(), epochID: UUID()) {
            XCTFail("Expected fallback reservation after day reset")
        }
        XCTAssertEqual(budget.dailyCount(), 1)
    }

    func testTwentyFourTrackBadWebEpochUsesAtMostTwoOfficialCalls() async throws {
        var webRequests = 0
        var dataAPIRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in
                webRequests += 1
                throw YouTubeWebSearchClient.SearchError.tooManyHTTPRedirects
            },
            dataAPISearch: { _ in dataAPIRequests += 1; return [] },
            fallbackBudget: isolatedFallbackBudget()
        )
        let context = resolutionContext()

        for index in 0..<24 {
            _ = try await resolver.primaryResults(query: "Song \(index)")
            _ = try await resolver.dataAPIFallbackResults(
                query: "Song \(index)",
                context: context
            )
        }

        XCTAssertEqual(webRequests, 1)
        XCTAssertEqual(dataAPIRequests, 2)
    }

    func testFiftyTrackBadWebRadioUsesAtMostSixOfficialCalls() async throws {
        var webRequests = 0
        var dataAPIRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in
                webRequests += 1
                throw YouTubeWebSearchClient.SearchError.abuseChallenge
            },
            dataAPISearch: { _ in dataAPIRequests += 1; return [] },
            fallbackBudget: isolatedFallbackBudget()
        )
        let sessionID = UUID()
        let epochIDs = [UUID(), UUID(), UUID()]

        for index in 0..<50 {
            let context = resolutionContext(
                sessionID: sessionID,
                epochID: epochIDs[min(index / 24, 2)]
            )
            _ = try await resolver.primaryResults(query: "Song \(index)")
            _ = try await resolver.dataAPIFallbackResults(
                query: "Song \(index)",
                context: context
            )
        }

        XCTAssertEqual(webRequests, 1)
        XCTAssertEqual(dataAPIRequests, 6)
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
            excludingSongIdentities: [],
            context: resolutionContext()
        )

        XCTAssertEqual(resolved.map(\.title), ["Working Song"])
        XCTAssertEqual(webRequests, 2)
    }

    func testZeroResultRefillSliceContinuesToNextSlice() async throws {
        let cache = MemoryYouTubeResolutionCache()
        var webRequests = 0
        var dataAPIRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { query in
                webRequests += 1
                guard query.contains("Song 9") else { return [] }
                return [self.youtubeResult(
                    videoID: "slicevalid1",
                    artist: "Artist 9",
                    title: "Song 9"
                )]
            },
            dataAPISearch: { _ in dataAPIRequests += 1; return [] },
            fallbackBudget: isolatedFallbackBudget()
        )
        let service = RecommendationService(
            similarTracks: { _, _, _ in [] },
            videoResolver: resolver,
            resolutionCache: cache
        )
        let candidates = (1...9).map { candidate("Artist \($0)", "Song \($0)") }

        let resolution = try await service.resolveReservoirCandidates(
            candidates,
            desiredCount: 1,
            excludingVideoIDs: [],
            excludingSongIdentities: [],
            context: resolutionContext()
        )

        XCTAssertEqual(resolution.recommendations.map(\.title), ["Song 9"])
        XCTAssertEqual(webRequests, 9)
        XCTAssertEqual(dataAPIRequests, 0)
        XCTAssertFalse(resolution.exhaustedCurrentPaths)
    }

    func testMultipleFailedRefillSlicesTerminateAtTrueExhaustion() async throws {
        let cache = MemoryYouTubeResolutionCache()
        var webRequests = 0
        var dataAPIRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in webRequests += 1; return [] },
            dataAPISearch: { _ in dataAPIRequests += 1; return [] },
            fallbackBudget: isolatedFallbackBudget()
        )
        let service = RecommendationService(
            similarTracks: { _, _, _ in [] },
            videoResolver: resolver,
            resolutionCache: cache
        )
        let candidates = (1...20).map { candidate("Artist \($0)", "Song \($0)") }

        let resolution = try await service.resolveReservoirCandidates(
            candidates,
            desiredCount: 1,
            excludingVideoIDs: [],
            excludingSongIdentities: [],
            context: resolutionContext()
        )

        XCTAssertTrue(resolution.recommendations.isEmpty)
        XCTAssertTrue(resolution.exhaustedCurrentPaths)
        XCTAssertEqual(webRequests, 20)
        XCTAssertEqual(dataAPIRequests, 2)
    }

    func testOpenWebCircuitRecoversCachedReservoirCandidatesWithoutNetwork() async throws {
        let first = candidate("Cached Artist 1", "Cached Song 1")
        let second = candidate("Cached Artist 2", "Cached Song 2")
        let cache = MemoryYouTubeResolutionCache([
            SongIdentity(artist: first.artist, title: first.title): youtubeResult(
                videoID: "cachedopen1",
                artist: first.artist,
                title: first.title
            ),
            SongIdentity(artist: second.artist, title: second.title): youtubeResult(
                videoID: "cachedopen2",
                artist: second.artist,
                title: second.title
            )
        ])
        var webRequests = 0
        var dataAPIRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in
                webRequests += 1
                throw URLError(.httpTooManyRedirects)
            },
            dataAPISearch: { _ in dataAPIRequests += 1; return [] },
            fallbackBudget: isolatedFallbackBudget()
        )
        _ = try await resolver.primaryResults(query: "open circuit")
        let service = RecommendationService(
            similarTracks: { _, _, _ in [] },
            videoResolver: resolver,
            resolutionCache: cache
        )

        let resolution = try await service.resolveReservoirCandidates(
            [candidate("Uncached", "Unavailable"), first, second],
            desiredCount: 2,
            excludingVideoIDs: [],
            excludingSongIdentities: [],
            context: resolutionContext(upcomingCount: 1)
        )

        XCTAssertEqual(Set(resolution.recommendations.map(\.title)), ["Cached Song 1", "Cached Song 2"])
        XCTAssertEqual(webRequests, 1)
        XCTAssertEqual(dataAPIRequests, 0)
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

    func testEarlyEpochRolloverUsesLastPlayedRecommendationExactlyOnce() {
        var session = RecommendationRadioSession(anchor: banditSeed())
        let played = canonicalSeed(index: 1)
        _ = session.confirmedRecommendationPlayback(seed: played)

        let first = session.startEarlyEpochIfPossible(anchor: played)
        let second = session.startEarlyEpochIfPossible(anchor: played)

        guard case .startNewEpoch(_, let anchor)? = first else {
            return XCTFail("Expected early epoch rollover")
        }
        XCTAssertEqual(anchor.songIdentity, played.songIdentity)
        XCTAssertEqual(session.epoch.consumedRecommendationCount, 0)
        XCTAssertNil(second)
    }

    func testEarlyEpochRolloverDoesNotLoopWithoutSuccessfulPlayback() {
        var session = RecommendationRadioSession(anchor: banditSeed())

        XCTAssertNil(session.startEarlyEpochIfPossible(anchor: banditSeed()))
        XCTAssertEqual(session.epoch.anchor.songIdentity, banditSeed().songIdentity)
    }

    func testEarlyEpochRolloverResetsOnlyEpochFallbackBudget() {
        let defaults = isolatedUserDefaults()
        let budget = RecommendationDataAPIFallbackBudget(defaults: defaults)
        let sessionID = UUID()
        let firstEpoch = UUID()
        let secondEpoch = UUID()

        _ = budget.reserveFallback(sessionID: sessionID, epochID: firstEpoch)
        _ = budget.reserveFallback(sessionID: sessionID, epochID: firstEpoch)
        XCTAssertEqual(
            budget.reserveFallback(sessionID: sessionID, epochID: firstEpoch),
            .failure(.epochBudgetExhausted)
        )
        guard case .success(let usage) = budget.reserveFallback(
            sessionID: sessionID,
            epochID: secondEpoch
        ) else {
            return XCTFail("Expected a fresh epoch allowance")
        }
        XCTAssertEqual(usage.epoch, 1)
        XCTAssertEqual(usage.session, 3)
        XCTAssertEqual(usage.daily, 3)
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

    private func resolutionContext(
        sessionID: UUID = UUID(),
        epochID: UUID = UUID(),
        upcomingCount: Int = 0
    ) -> RecommendationResolutionContext {
        RecommendationResolutionContext(
            sessionID: sessionID,
            epochID: epochID,
            upcomingCount: upcomingCount
        )
    }

    private func isolatedFallbackBudget(
        now: @escaping () -> Date = Date.init
    ) -> RecommendationDataAPIFallbackBudget {
        RecommendationDataAPIFallbackBudget(defaults: isolatedUserDefaults(), now: now)
    }

    private func isolatedUserDefaults() -> UserDefaults {
        UserDefaults(suiteName: "RecommendationFallbackTests.\(UUID().uuidString)")!
    }
}

private actor AsyncSearchGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspendUntilReleased() async {
        started = true
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor FakeGenreTagFetcher: GenreTagFetching {
    enum Error: Swift.Error {
        case offline
    }

    private let result: Result<[GenreTag], Swift.Error>
    private let delayNanoseconds: UInt64
    private(set) var callCount = 0

    init(result: Result<[GenreTag], Swift.Error>, delayNanoseconds: UInt64 = 0) {
        self.result = result
        self.delayNanoseconds = delayNanoseconds
    }

    func topTags(artist: String, title: String) async throws -> [GenreTag] {
        callCount += 1
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return try result.get()
    }

    func calls() -> Int {
        callCount
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

    func peek(for identity: SongIdentity, now: Date) async -> YouTubeSearchResult? {
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
            excludingSongIdentities: session.globalPlayedSongIdentities,
            context: RecommendationResolutionContext(
                sessionID: session.id,
                epochID: epochID,
                upcomingCount: upcoming.count
            )
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
            excludingSongIdentities: session.globalPlayedSongIdentities,
            context: RecommendationResolutionContext(
                sessionID: session.id,
                epochID: session.epoch.id,
                upcomingCount: upcoming.count
            )
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
