//
//  RecommendationPipelineTests.swift
//  ShaudiTests
//

import XCTest
@testable import Shaudi

@MainActor
final class RecommendationPipelineTests: XCTestCase {
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

    func testPrimarySimilarPoolSkipsArtistTopTracksFallback() async throws {
        var topTrackCalls = 0
        let service = fallbackTestService(
            similarTracks: { _, _, _ in
                [
                    self.candidate("Artist 1", "Song 1"),
                    self.candidate("Artist 2", "Song 2"),
                    self.candidate("Artist 3", "Song 3")
                ]
            },
            topTracks: { _, _ in
                topTrackCalls += 1
                return []
            }
        )

        let ranked = try await service.rankedCandidates(
            for: unreleasedSeed(),
            excludingSongIdentities: []
        )

        XCTAssertEqual(ranked.count, 3)
        XCTAssertEqual(topTrackCalls, 0)
    }

    func testEmptyPrimaryUsesTopTrackAsSurrogateOnce() async throws {
        var similarRequests: [(String, String)] = []
        var topTrackCalls = 0
        let service = fallbackTestService(
            similarTracks: { artist, title, _ in
                similarRequests.append((artist, title))
                guard title == "Lucid Dreams" else { return [] }
                return [
                    self.candidate("Artist 1", "Song 1"),
                    self.candidate("Artist 2", "Song 2"),
                    self.candidate("Artist 3", "Song 3")
                ]
            },
            topTracks: { _, _ in
                topTrackCalls += 1
                return [LastFMTopTrack(artist: "Juice WRLD", title: "Lucid Dreams")]
            }
        )

        let ranked = try await service.rankedCandidates(
            for: unreleasedSeed(),
            excludingSongIdentities: []
        )

        XCTAssertEqual(topTrackCalls, 1)
        XCTAssertEqual(similarRequests.map(\.1), ["Some Unreleased Song", "Lucid Dreams"])
        XCTAssertEqual(ranked.count, 3)
    }

    func testSurrogateSelectionSkipsCurrentSongAtTopOfRanking() async throws {
        var similarTitles: [String] = []
        let service = fallbackTestService(
            similarTracks: { _, title, _ in
                similarTitles.append(title)
                return title == "Lucid Dreams"
                    ? [self.candidate("Artist", "Recommendation")]
                    : []
            },
            topTracks: { _, _ in
                [
                    LastFMTopTrack(artist: "juice wrld", title: "Some Unreleased Song"),
                    LastFMTopTrack(artist: "Juice WRLD", title: "Lucid Dreams")
                ]
            }
        )

        _ = try await service.rankedCandidates(
            for: unreleasedSeed(),
            excludingSongIdentities: []
        )

        XCTAssertEqual(similarTitles, ["Some Unreleased Song", "Lucid Dreams"])
    }

    func testEmptyArtistTopTracksFailsGracefully() async throws {
        var similarCallCount = 0
        var topTrackCalls = 0
        let service = fallbackTestService(
            similarTracks: { _, _, _ in similarCallCount += 1; return [] },
            topTracks: { _, _ in topTrackCalls += 1; return [] }
        )

        let ranked = try await service.rankedCandidates(
            for: unreleasedSeed(),
            excludingSongIdentities: []
        )

        XCTAssertTrue(ranked.isEmpty)
        XCTAssertEqual(similarCallCount, 1)
        XCTAssertEqual(topTrackCalls, 1)
    }

    func testEmptySurrogateSimilarTracksDoesNotRecursivelyRetry() async throws {
        var similarCallCount = 0
        var topTrackCalls = 0
        let service = fallbackTestService(
            similarTracks: { _, _, _ in similarCallCount += 1; return [] },
            topTracks: { _, _ in
                topTrackCalls += 1
                return [LastFMTopTrack(artist: "Juice WRLD", title: "Lucid Dreams")]
            }
        )

        let ranked = try await service.rankedCandidates(
            for: unreleasedSeed(),
            excludingSongIdentities: []
        )

        XCTAssertTrue(ranked.isEmpty)
        XCTAssertEqual(similarCallCount, 2)
        XCTAssertEqual(topTrackCalls, 1)
    }

    func testReservoirRefillCannotRepeatSurrogateLookupInSameEpoch() async throws {
        var topTrackCalls = 0
        let service = fallbackTestService(
            similarTracks: { _, title, _ in
                title == "Lucid Dreams"
                    ? (1...5).map { self.candidate("Artist \($0)", "Song \($0)") }
                    : []
            },
            topTracks: { _, _ in
                topTrackCalls += 1
                return [LastFMTopTrack(artist: "Juice WRLD", title: "Lucid Dreams")]
            }
        )
        var session = RecommendationRadioSession(anchor: unreleasedSeed())
        let epochID = session.epoch.id

        XCTAssertTrue(session.markEpochCandidateRequestStarted(epochID: epochID))
        let ranked = try await service.rankedCandidates(
            for: session.epoch.anchor,
            excludingSongIdentities: session.globalPlayedSongIdentities
        )
        XCTAssertTrue(session.replaceReservoir(ranked.map(\.track), epochID: epochID))
        _ = session.takeReservoirCandidates(upTo: 2, epochID: epochID)

        XCTAssertFalse(session.markEpochCandidateRequestStarted(epochID: epochID))
        XCTAssertEqual(topTrackCalls, 1)
    }

    func testNewEpochMayEvaluateSurrogateFallbackAgain() async throws {
        var topTrackCalls = 0
        let service = fallbackTestService(
            similarTracks: { _, title, _ in
                title == "Lucid Dreams"
                    ? (1...3).map { self.candidate("Artist \($0)", "Song \($0)") }
                    : []
            },
            topTracks: { _, _ in
                topTrackCalls += 1
                return [LastFMTopTrack(artist: "Juice WRLD", title: "Lucid Dreams")]
            }
        )
        var session = RecommendationRadioSession(anchor: unreleasedSeed())

        XCTAssertTrue(session.markEpochCandidateRequestStarted(epochID: session.epoch.id))
        _ = try await service.rankedCandidates(
            for: session.epoch.anchor,
            excludingSongIdentities: session.globalPlayedSongIdentities
        )
        for index in 1...RecommendationRadioPolicy.epochLength {
            _ = session.confirmedRecommendationPlayback(seed: canonicalSeed(index: index))
        }
        XCTAssertTrue(session.markEpochCandidateRequestStarted(epochID: session.epoch.id))
        _ = try await service.rankedCandidates(
            for: session.epoch.anchor,
            excludingSongIdentities: session.globalPlayedSongIdentities
        )

        XCTAssertEqual(topTrackCalls, 2)
    }

    func testSurrogateFallbackDoesNotChangeActualEpochAnchor() async throws {
        let actualSeed = unreleasedSeed()
        let session = RecommendationRadioSession(anchor: actualSeed)
        let service = fallbackTestService(
            similarTracks: { _, title, _ in
                title == "Lucid Dreams"
                    ? [self.candidate("Artist", "Recommendation")]
                    : []
            },
            topTracks: { _, _ in
                [LastFMTopTrack(artist: "Juice WRLD", title: "Lucid Dreams")]
            }
        )

        _ = try await service.rankedCandidates(
            for: session.epoch.anchor,
            excludingSongIdentities: session.globalPlayedSongIdentities
        )

        XCTAssertEqual(session.epoch.anchor.songIdentity, actualSeed.songIdentity)
        XCTAssertEqual(session.epoch.anchor.youtubeVideoID, actualSeed.youtubeVideoID)
    }

    func testSurrogateCandidatesStillHonorSessionCanonicalDedupe() async throws {
        let played = SongIdentity(artist: "Played Artist", title: "Played Song")
        let service = fallbackTestService(
            similarTracks: { _, title, _ in
                guard title == "Lucid Dreams" else { return [] }
                return [
                    self.candidate(played.artist, played.title),
                    self.candidate("Fresh 1", "Song 1"),
                    self.candidate("Fresh 2", "Song 2"),
                    self.candidate("Fresh 3", "Song 3")
                ]
            },
            topTracks: { _, _ in
                [LastFMTopTrack(artist: "Juice WRLD", title: "Lucid Dreams")]
            }
        )

        let ranked = try await service.rankedCandidates(
            for: unreleasedSeed(),
            excludingSongIdentities: [played]
        )

        XCTAssertFalse(ranked.map(\.identity).contains(played))
        XCTAssertEqual(ranked.count, 3)
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

}
