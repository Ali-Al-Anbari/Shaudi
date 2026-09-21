//
//  PlaylistRecommendationTests.swift
//  ShaudiTests
//

import SwiftData
import XCTest
@testable import Shaudi

@MainActor
final class PlaylistRecommendationTests: XCTestCase {

    // MARK: - Helpers

    private func makeTrack(
        id: String = UUID().uuidString,
        title: String = "Test Song",
        artist: String = "Test Artist",
        dateAdded: Date = .now
    ) -> Track {
        Track(
            title: title,
            youtubeURL: URL(string: "https://www.youtube.com/watch?v=\(id)")!,
            youtubeVideoID: id,
            dateAdded: dateAdded,
            channelTitle: artist,
            thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"),
            duration: 200,
            metadataLastRefreshed: .now
        )
    }

    private func makeSimilar(
        artist: String,
        title: String,
        match: Double
    ) -> LastFMSimilarTrack {
        LastFMSimilarTrack(
            artist: artist,
            title: title,
            match: match,
            url: nil
        )
    }

    private func makeYouTubeResult(
        videoID: String,
        artist: String,
        title: String
    ) -> YouTubeSearchResult {
        YouTubeSearchResult(
            youtubeVideoID: videoID,
            title: "\(artist) - \(title)",
            channelTitle: artist,
            thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"),
            duration: 200
        )
    }

    private func makeResolved(
        artist: String,
        title: String,
        videoID: String,
        match: Double = 0.85,
        youtubeTitle: String? = nil,
        uploader: String? = nil
    ) -> ResolvedRecommendation {
        ResolvedRecommendation(
            artist: artist,
            title: title,
            match: match,
            youtubeResult: YouTubeSearchResult(
                youtubeVideoID: videoID,
                title: youtubeTitle ?? "\(artist) - \(title)",
                channelTitle: uploader ?? artist,
                thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"),
                duration: 200
            )
        )
    }

    private func makeTestContainer() throws -> (ModelContainer, ModelContext) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Track.self, Playlist.self, configurations: config)
        return (container, container.mainContext)
    }

    // MARK: - 22 Deterministic Tests

    // 1. playlist open may automatically perform bounded Last.fm work
    func testPlaylistOpenMayAutomaticallyPerformBoundedLastFMWork() async throws {
        let t1 = makeTrack(id: "v1", title: "Boulevard of Broken Dreams", artist: "Green Day")
        var lastFMQueried = false

        let service = PlaylistRecommendationService(
            similarTracks: { artist, title, _, _ in
                lastFMQueried = true
                return [self.makeSimilar(artist: "blink-182", title: "Dammit", match: 0.9)]
            },
            safeResolve: { candidate in
                self.makeResolved(artist: candidate.artist, title: candidate.title, videoID: "res1")
            }
        )

        let result = try await service.recommendations(for: [t1])
        XCTAssertTrue(lastFMQueried)
        XCTAssertEqual(result.visibleRecommendations.count, 1)
        XCTAssertEqual(result.visibleRecommendations.first?.title, "Dammit")
    }

    // 2. automatic Last.fm remains capped at <= 5 calls
    func testAutomaticLastFMRemainsCappedAt5Calls() async throws {
        var tracks: [Track] = []
        for i in 1...15 {
            tracks.append(makeTrack(id: "v\(i)", title: "Song \(i)", artist: "Artist \(i)"))
        }

        var callCount = 0
        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in
                callCount += 1
                return [self.makeSimilar(artist: "RecArtist", title: "RecSong", match: 0.8)]
            },
            safeResolve: { candidate in
                self.makeResolved(artist: candidate.artist, title: candidate.title, videoID: "r1")
            }
        )

        _ = try await service.recommendations(for: tracks)
        XCTAssertLessThanOrEqual(callCount, 5)
        XCTAssertGreaterThan(callCount, 0)
    }

    // 3. cache hit avoids repeat Last.fm work
    func testCacheHitAvoidsRepeatLastFMWork() async throws {
        let tracks = [makeTrack(id: "v1", title: "Song 1", artist: "Artist 1")]
        var callCount = 0
        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in
                callCount += 1
                return [self.makeSimilar(artist: "RecArtist", title: "RecSong", match: 0.8)]
            },
            safeResolve: { candidate in
                self.makeResolved(artist: candidate.artist, title: candidate.title, videoID: "r1")
            }
        )

        let res1 = try await service.recommendations(for: tracks, playlistID: "p1")
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(res1.visibleRecommendations.count, 1)

        let res2 = try await service.recommendations(for: tracks, playlistID: "p1")
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(res2.visibleRecommendations.count, 1)
    }

    // 4. automatic recommendation generation may use persistent YouTube ID cache
    func testAutomaticRecommendationGenerationMayUsePersistentYouTubeIDCache() async throws {
        let tracks = [makeTrack(id: "v1", title: "Song 1", artist: "Artist 1")]
        var safeResolverCalled = false
        var officialResolverCalled = false

        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in
                [self.makeSimilar(artist: "Cached Artist", title: "Cached Song", match: 0.9)]
            },
            safeResolve: { candidate in
                safeResolverCalled = true
                return self.makeResolved(artist: candidate.artist, title: candidate.title, videoID: "cachedVid")
            },
            officialResolve: { _ in
                officialResolverCalled = true
                return nil
            }
        )

        let result = try await service.recommendations(for: tracks)
        XCTAssertTrue(safeResolverCalled)
        XCTAssertFalse(officialResolverCalled)
        XCTAssertEqual(result.visibleRecommendations.count, 1)
        XCTAssertEqual(result.visibleRecommendations.first?.youtubeResult.youtubeVideoID, "cachedVid")
    }

    // 5. automatic recommendation generation may use structured resolver
    func testAutomaticRecommendationGenerationMayUseStructuredResolver() async throws {
        let tracks = [makeTrack(id: "v1", title: "Song 1", artist: "Artist 1")]
        var structuredResolverUsed = false

        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in
                [self.makeSimilar(artist: "Structured Artist", title: "Structured Song", match: 0.88)]
            },
            safeResolve: { candidate in
                structuredResolverUsed = true
                return self.makeResolved(artist: candidate.artist, title: candidate.title, videoID: "structuredVid")
            }
        )

        let result = try await service.recommendations(for: tracks)
        XCTAssertTrue(structuredResolverUsed)
        XCTAssertEqual(result.visibleRecommendations.first?.youtubeResult.youtubeVideoID, "structuredVid")
    }

    // 6. automatic recommendation generation does NOT invoke official search.list
    func testAutomaticRecommendationGenerationDoesNotInvokeOfficialSearchList() async throws {
        let tracks = [makeTrack(id: "v1", title: "Song 1", artist: "Artist 1")]
        var officialResolveCalls = 0

        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in
                [self.makeSimilar(artist: "Artist A", title: "Song A", match: 0.85)]
            },
            safeResolve: { _ in
                nil
            },
            officialResolve: { _ in
                officialResolveCalls += 1
                return nil
            }
        )

        let result = try await service.recommendations(for: tracks)
        XCTAssertEqual(officialResolveCalls, 0, "Automatic recommendations must never invoke official search.list")
        XCTAssertEqual(result.visibleRecommendations.count, 0)
        XCTAssertEqual(result.deferredCandidates.count, 1)
    }

    // 7. candidate requiring official search is deferred
    func testCandidateRequiringOfficialSearchIsDeferred() async throws {
        let tracks = [makeTrack(id: "v1", title: "Song 1", artist: "Artist 1")]

        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in
                [self.makeSimilar(artist: "Needs Official", title: "Fallback Track", match: 0.85)]
            },
            safeResolve: { _ in nil }
        )

        let result = try await service.recommendations(for: tracks)
        XCTAssertTrue(result.visibleRecommendations.isEmpty)
        XCTAssertEqual(result.deferredCandidates.count, 1)
        XCTAssertEqual(result.deferredCandidates.first?.identity.title, "Fallback Track")
    }

    // 8. lower-ranked safe candidate can still resolve after a deferred one
    func testLowerRankedSafeCandidateCanStillResolveAfterADeferredOne() async throws {
        let tracks = [makeTrack(id: "v1", title: "Song 1", artist: "Artist 1")]

        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in
                [
                    self.makeSimilar(artist: "High Rank Artist", title: "High Rank Song", match: 0.95),
                    self.makeSimilar(artist: "Low Rank Artist", title: "Low Rank Song", match: 0.80)
                ]
            },
            safeResolve: { candidate in
                if candidate.title == "High Rank Song" {
                    return nil
                } else {
                    return self.makeResolved(artist: candidate.artist, title: candidate.title, videoID: "lowRankVid")
                }
            }
        )

        let result = try await service.recommendations(for: tracks)
        XCTAssertEqual(result.visibleRecommendations.count, 1)
        XCTAssertEqual(result.visibleRecommendations.first?.title, "Low Rank Song")
        XCTAssertEqual(result.deferredCandidates.count, 1)
        XCTAssertEqual(result.deferredCandidates.first?.identity.title, "High Rank Song")
    }

    // 9. fewer than 5 safe results produces Find More state
    func testFewerThan5SafeResultsProducesFindMoreState() async throws {
        let tracks = [makeTrack(id: "v1", title: "Song 1", artist: "Artist 1")]

        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in
                [
                    self.makeSimilar(artist: "Artist 1", title: "Song 1", match: 0.9),
                    self.makeSimilar(artist: "Artist 2", title: "Song 2", match: 0.85),
                    self.makeSimilar(artist: "Artist 3", title: "Song 3", match: 0.8)
                ]
            },
            safeResolve: { candidate in
                if candidate.title == "Song 1" || candidate.title == "Song 2" {
                    return self.makeResolved(artist: candidate.artist, title: candidate.title, videoID: candidate.title)
                }
                return nil
            }
        )

        let result = try await service.recommendations(for: tracks)
        XCTAssertEqual(result.visibleRecommendations.count, 2)
        XCTAssertEqual(result.deferredCandidates.count, 1)
        XCTAssertTrue(result.canFindMore)
    }

    // 10. 5 safe results does NOT show Find More unnecessarily
    func test5SafeResultsDoesNotShowFindMoreUnnecessarily() async throws {
        let tracks = [makeTrack(id: "v1", title: "Song 1", artist: "Artist 1")]

        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in
                (1...5).map { self.makeSimilar(artist: "Artist \($0)", title: "Song \($0)", match: 0.9 - Double($0) * 0.01) }
            },
            safeResolve: { candidate in
                self.makeResolved(artist: candidate.artist, title: candidate.title, videoID: candidate.title)
            }
        )

        let result = try await service.recommendations(for: tracks)
        XCTAssertEqual(result.visibleRecommendations.count, 5)
        XCTAssertFalse(result.canFindMore)
    }

    // 11. tapping Find More permits official search fallback
    func testTappingFindMorePermitsOfficialSearchFallback() async throws {
        let tracks = [makeTrack(id: "v1", title: "Song 1", artist: "Artist 1")]
        var officialResolveCalls = 0

        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in
                [
                    self.makeSimilar(artist: "Artist 1", title: "Song 1", match: 0.9),
                    self.makeSimilar(artist: "Artist 2", title: "Song 2", match: 0.8)
                ]
            },
            safeResolve: { candidate in
                if candidate.title == "Song 1" {
                    return self.makeResolved(artist: candidate.artist, title: candidate.title, videoID: "vid1")
                }
                return nil
            },
            officialResolve: { candidate in
                officialResolveCalls += 1
                return self.makeResolved(artist: candidate.artist, title: candidate.title, videoID: "official_\(candidate.title)")
            }
        )

        let initialResult = try await service.recommendations(for: tracks, playlistID: "p1")
        XCTAssertEqual(initialResult.visibleRecommendations.count, 1)
        XCTAssertEqual(officialResolveCalls, 0)
        XCTAssertTrue(initialResult.canFindMore)

        let updated = try await service.findMore(for: tracks, playlistID: "p1", currentResult: initialResult)
        XCTAssertEqual(officialResolveCalls, 1)
        XCTAssertEqual(updated.visibleRecommendations.count, 2)
        XCTAssertEqual(updated.visibleRecommendations.last?.youtubeResult.youtubeVideoID, "official_Song 2")
    }

    // 12. Find More stops after enough songs are resolved
    func testFindMoreStopsAfterEnoughSongsAreResolved() async throws {
        let tracks = [makeTrack(id: "v1", title: "Song 1", artist: "Artist 1")]
        var officialCalls = 0

        let initialVisible = (1...3).map { makeResolved(artist: "Visible \($0)", title: "V\($0)", videoID: "visible\($0)") }
        let deferred = (1...4).map {
            ScoredPlaylistCandidate(
                track: makeSimilar(artist: "Deferred \($0)", title: "D\($0)", match: 0.8),
                identity: SongIdentity(artist: "Deferred \($0)", title: "D\($0)"),
                score: 0.8,
                supportingAnchorCount: 1
            )
        }

        let initialResult = PlaylistRecommendationResult(
            visibleRecommendations: initialVisible,
            spareResolved: [],
            deferredCandidates: deferred
        )

        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in [] },
            safeResolve: { _ in nil },
            officialResolve: { candidate in
                officialCalls += 1
                return self.makeResolved(artist: candidate.artist, title: candidate.title, videoID: "off_\(candidate.title)")
            }
        )

        let updated = try await service.findMore(for: tracks, playlistID: "p1", currentResult: initialResult)
        XCTAssertEqual(updated.visibleRecommendations.count, 5)
        XCTAssertEqual(officialCalls, 2, "Should stop immediately after resolving 2 songs to reach 5 visible")
        XCTAssertEqual(updated.deferredCandidates.count, 2, "Remaining 2 deferred songs should not be queried")
        XCTAssertFalse(updated.canFindMore)
    }

    // 13. Find More does not search all remaining candidates unnecessarily
    func testFindMoreDoesNotSearchAllRemainingCandidatesUnnecessarily() async throws {
        let tracks = [makeTrack(id: "v1", title: "Song 1", artist: "Artist 1")]
        var officialCalls = 0

        let initialVisible = (1...4).map { makeResolved(artist: "Visible \($0)", title: "V\($0)", videoID: "visible\($0)") }
        let deferred = (1...10).map {
            ScoredPlaylistCandidate(
                track: makeSimilar(artist: "Deferred \($0)", title: "D\($0)", match: 0.8),
                identity: SongIdentity(artist: "Deferred \($0)", title: "D\($0)"),
                score: 0.8,
                supportingAnchorCount: 1
            )
        }

        let initialResult = PlaylistRecommendationResult(
            visibleRecommendations: initialVisible,
            spareResolved: [],
            deferredCandidates: deferred
        )

        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in [] },
            safeResolve: { _ in nil },
            officialResolve: { candidate in
                officialCalls += 1
                return self.makeResolved(artist: candidate.artist, title: candidate.title, videoID: "off_\(candidate.title)")
            }
        )

        let updated = try await service.findMore(for: tracks, playlistID: "p1", currentResult: initialResult)
        XCTAssertEqual(updated.visibleRecommendations.count, 5)
        XCTAssertEqual(officialCalls, 1, "Should stop after 1 resolve")
        XCTAssertEqual(updated.deferredCandidates.count, 9)
    }

    // 14. quick Add does not trigger new official search
    func testQuickAddDoesNotTriggerNewOfficialSearch() {
        var officialCalls = 0
        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in [] },
            safeResolve: { _ in nil },
            officialResolve: { _ in
                officialCalls += 1
                return nil
            }
        )

        let visible = (1...5).map { makeResolved(artist: "A\($0)", title: "T\($0)", videoID: "v\($0)") }
        let spare = [makeResolved(artist: "Spare 1", title: "S1", videoID: "s1")]
        let initialResult = PlaylistRecommendationResult(
            visibleRecommendations: visible,
            spareResolved: spare,
            deferredCandidates: []
        )

        let updated = service.consumeVisibleRecommendation(visible[0], from: initialResult, playlistID: "p1")
        XCTAssertEqual(officialCalls, 0)
        XCTAssertEqual(updated.visibleRecommendations.count, 5)
        XCTAssertEqual(updated.visibleRecommendations.last?.title, "S1")
        XCTAssertEqual(updated.spareResolved.count, 0)
    }

    // 15. Reject does not trigger new official search
    func testRejectDoesNotTriggerNewOfficialSearch() {
        var officialCalls = 0
        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in [] },
            safeResolve: { _ in nil },
            officialResolve: { _ in
                officialCalls += 1
                return nil
            }
        )

        let visible = (1...5).map { makeResolved(artist: "A\($0)", title: "T\($0)", videoID: "v\($0)") }
        let spare = [makeResolved(artist: "Spare 1", title: "S1", videoID: "s1")]
        let initialResult = PlaylistRecommendationResult(
            visibleRecommendations: visible,
            spareResolved: spare,
            deferredCandidates: []
        )

        let updated = service.rejectRecommendation(visible[0], from: initialResult, playlistID: "p1")
        XCTAssertEqual(officialCalls, 0)
        XCTAssertEqual(updated.visibleRecommendations.count, 5)
        XCTAssertEqual(updated.visibleRecommendations.last?.title, "S1")
    }

    // 16. Reject remains playlist-specific
    func testRejectRemainsPlaylistSpecific() {
        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in [] },
            safeResolve: { _ in nil }
        )

        let item = makeResolved(artist: "Artist A", title: "Song A", videoID: "vidA")
        let result = PlaylistRecommendationResult(
            visibleRecommendations: [item],
            spareResolved: [],
            deferredCandidates: []
        )

        _ = service.rejectRecommendation(item, from: result, playlistID: "playlist1")

        XCTAssertTrue(service.rejectionStore.isRejected(item.songIdentity, videoID: "vidA", for: "playlist1"))
        XCTAssertFalse(service.rejectionStore.isRejected(item.songIdentity, videoID: "vidA", for: "playlist2"))
    }

    // 17. rejected candidates are excluded from future playlist recommendation generations
    func testRejectedCandidatesAreExcludedFromFuturePlaylistRecommendationGenerations() async throws {
        let tracks = [makeTrack(id: "v1", title: "Song 1", artist: "Artist 1")]

        let item = makeResolved(artist: "Artist A", title: "Song A", videoID: "vidA")
        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in
                [
                    self.makeSimilar(artist: "Artist A", title: "Song A", match: 0.95),
                    self.makeSimilar(artist: "Artist B", title: "Song B", match: 0.85)
                ]
            },
            safeResolve: { candidate in
                self.makeResolved(artist: candidate.artist, title: candidate.title, videoID: candidate.title)
            }
        )

        service.rejectionStore.reject(item.songIdentity, videoID: "vidA", for: "playlist1")

        let result1 = try await service.recommendations(for: tracks, playlistID: "playlist1", forceRefresh: true)
        XCTAssertFalse(result1.visibleRecommendations.contains { $0.title == "Song A" })
        XCTAssertTrue(result1.visibleRecommendations.contains { $0.title == "Song B" })

        let result2 = try await service.recommendations(for: tracks, playlistID: "playlist2", forceRefresh: true)
        XCTAssertTrue(result2.visibleRecommendations.contains { $0.title == "Song A" })
    }

    // 18. recommendation row tap plays normally
    func testRecommendationRowTapPlaysNormally() {
        let item = makeResolved(artist: "Artist A", title: "Song A", videoID: "vid123")
        let playable = PlayableTrack(
            youtubeVideoID: item.youtubeResult.youtubeVideoID,
            title: item.title,
            channelTitle: item.artist,
            thumbnailURL: item.youtubeResult.thumbnailURL,
            duration: item.youtubeResult.duration
        )

        XCTAssertEqual(playable.youtubeVideoID, "vid123")
        XCTAssertEqual(playable.title, "Song A")
        XCTAssertEqual(playable.channelTitle, "Artist A")
        XCTAssertEqual(item.songIdentity.artist, "Artist A")
        XCTAssertEqual(item.songIdentity.title, "Song A")
    }

    // 19. normal ... actions remain available
    func testNormalEllipsisActionsRemainAvailable() throws {
        let (container, context) = try makeTestContainer()
        _ = container
        let playlist = Playlist(name: "Test Playlist")
        context.insert(playlist)

        let item = makeResolved(artist: "Artist A", title: "Song A", videoID: "vid123")
        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in [] },
            safeResolve: { _ in nil }
        )

        let added = service.addRecommendation(item, to: playlist, in: context, existingLibraryTracks: [])
        XCTAssertNotNil(added)
        XCTAssertEqual(playlist.tracks.count, 1)

        let transient = Track(
            title: item.title,
            youtubeURL: URL(string: "https://www.youtube.com/watch?v=\(item.youtubeResult.youtubeVideoID)")!,
            youtubeVideoID: item.youtubeResult.youtubeVideoID,
            channelTitle: item.artist,
            thumbnailURL: item.youtubeResult.thumbnailURL,
            duration: item.youtubeResult.duration,
            metadataLastRefreshed: .now
        )
        context.insert(transient)
        XCTAssertEqual(transient.youtubeVideoID, "vid123")
    }

    // 20. external playlist change invalidates cache while preserving no-automatic-official-search rule
    func testExternalPlaylistChangeInvalidatesCacheWhilePreservingNoAutomaticOfficialSearchRule() async throws {
        let t1 = makeTrack(id: "v1", title: "Song 1", artist: "Artist 1")
        let t2 = makeTrack(id: "v2", title: "Song 2", artist: "Artist 2")
        var officialCalls = 0

        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in
                [self.makeSimilar(artist: "RecArtist", title: "RecSong", match: 0.9)]
            },
            safeResolve: { candidate in
                self.makeResolved(artist: candidate.artist, title: candidate.title, videoID: "vid_\(candidate.title)")
            },
            officialResolve: { _ in
                officialCalls += 1
                return nil
            }
        )

        _ = try await service.recommendations(for: [t1], playlistID: "p1")
        XCTAssertEqual(officialCalls, 0)

        _ = try await service.recommendations(for: [t1, t2], playlistID: "p1")
        XCTAssertEqual(officialCalls, 0, "External playlist change re-resolves safely without official search")
    }

    // 21. Refresh may make new Last.fm calls but still does not automatically consume official search.list
    func testRefreshMayMakeNewLastFMCallsButStillDoesNotAutomaticallyConsumeOfficialSearchList() async throws {
        let tracks = [
            makeTrack(id: "v1", title: "Song 1", artist: "Artist 1"),
            makeTrack(id: "v2", title: "Song 2", artist: "Artist 2")
        ]

        var lastFMCalls = 0
        var officialCalls = 0

        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in
                lastFMCalls += 1
                return [self.makeSimilar(artist: "RecArtist", title: "RecSong", match: 0.85)]
            },
            safeResolve: { candidate in
                self.makeResolved(artist: candidate.artist, title: candidate.title, videoID: "safeVid")
            },
            officialResolve: { _ in
                officialCalls += 1
                return nil
            }
        )

        _ = try await service.recommendations(for: tracks, playlistID: "p1", rotation: 0)
        XCTAssertGreaterThan(lastFMCalls, 0)
        XCTAssertEqual(officialCalls, 0)

        let previousLastFMCalls = lastFMCalls
        _ = try await service.recommendations(for: tracks, playlistID: "p1", rotation: 1, forceRefresh: true)
        XCTAssertGreaterThan(lastFMCalls, previousLastFMCalls, "Refresh may make new Last.fm calls")
        XCTAssertEqual(officialCalls, 0, "Refresh must still not invoke official search")
    }

    // 22. existing Recommendation Radio official fallback behavior is unchanged
    func testExistingRecommendationRadioOfficialFallbackBehaviorIsUnchanged() {
        let testSessionID = UUID()
        let testEpochID = UUID()
        let primaryAttempt = RecommendationYouTubeResolutionAttempt.primaryOnly()
        let fallbackContext = RecommendationResolutionContext(sessionID: testSessionID, epochID: testEpochID, upcomingCount: 0)
        let fallbackAttempt = RecommendationYouTubeResolutionAttempt.officialFallback(fallbackContext)

        switch primaryAttempt {
        case .primaryOnly:
            break
        default:
            XCTFail("Expected primaryOnly attempt")
        }

        switch fallbackAttempt {
        case .officialFallback(let context):
            XCTAssertEqual(context.currentUpcomingCount(), 0)
            XCTAssertEqual(context.sessionID, testSessionID)
        default:
            XCTFail("Expected officialFallback attempt")
        }
    }

    // MARK: - Canonical identity persistence regressions

    func testAuthoritativeRecommendationIdentitySurvivesSaveReloadAndPlaylistProfileBuild() throws {
        let (container, context) = try makeTestContainer()
        let playlist = Playlist(name: "Canonical Round Trip")
        context.insert(playlist)
        let recommendation = makeResolved(
            artist: "Lana Del Rey",
            title: "West Coast",
            videoID: "canonical01"
        )
        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in [] },
            safeResolve: { _ in nil }
        )

        XCTAssertNotNil(service.addRecommendation(
            recommendation,
            to: playlist,
            in: context,
            existingLibraryTracks: []
        ))

        let reloadedTracks = try ModelContext(container).fetch(FetchDescriptor<Track>())
        let reloaded = try XCTUnwrap(
            reloadedTracks.first { $0.youtubeVideoID == recommendation.youtubeResult.youtubeVideoID }
        )
        XCTAssertEqual(reloaded.title, "West Coast")
        XCTAssertEqual(reloaded.displayArtist, "Lana Del Rey")
        let profile = PlaylistVibeProfile.build(from: [reloaded])
        let anchor = try XCTUnwrap(profile.representativeAnchors.first)

        XCTAssertEqual(
            anchor.songIdentity,
            SongIdentity(artist: "Lana Del Rey", title: "West Coast")
        )
        XCTAssertTrue(profile.existingIdentities.contains(anchor.songIdentity))
    }

    func testMisleadingUploaderDoesNotReplaceCanonicalArtistAfterPersistenceRoundTrip() throws {
        let (container, context) = try makeTestContainer()
        let playlist = Playlist(name: "Uploader Identity")
        context.insert(playlist)
        let recommendation = makeResolved(
            artist: "Lana Del Rey",
            title: "West Coast",
            videoID: "canonical02",
            youtubeTitle: "West Coast (fan upload)",
            uploader: "SomeFanArchive"
        )
        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in [] },
            safeResolve: { _ in nil }
        )

        XCTAssertNotNil(service.addRecommendation(
            recommendation,
            to: playlist,
            in: context,
            existingLibraryTracks: []
        ))

        let reloaded = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<Track>())
                .first { $0.youtubeVideoID == "canonical02" }
        )
        XCTAssertEqual(reloaded.displayArtist, "Lana Del Rey")
        XCTAssertNotEqual(reloaded.displayArtist, "SomeFanArchive")

        let anchor = try XCTUnwrap(
            PlaylistVibeProfile.build(from: [reloaded]).representativeAnchors.first
        )
        XCTAssertEqual(anchor.songIdentity.artist, "Lana Del Rey")
        XCTAssertEqual(anchor.songIdentity.title, "West Coast")
    }

    func testSameTitleDifferentCanonicalArtistsRemainDistinctAfterPersistenceRoundTrip() throws {
        let (container, context) = try makeTestContainer()
        let playlist = Playlist(name: "Same Title")
        context.insert(playlist)
        let first = makeResolved(
            artist: "Artist One",
            title: "Home",
            videoID: "same-title1"
        )
        let second = makeResolved(
            artist: "Artist Two",
            title: "Home",
            videoID: "same-title2"
        )
        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in [] },
            safeResolve: { _ in nil }
        )

        XCTAssertNotNil(service.addRecommendation(
            first,
            to: playlist,
            in: context,
            existingLibraryTracks: []
        ))
        XCTAssertNotNil(service.addRecommendation(
            second,
            to: playlist,
            in: context,
            existingLibraryTracks: []
        ))

        let reloadedTracks = try ModelContext(container).fetch(FetchDescriptor<Track>())
        XCTAssertEqual(
            Set(reloadedTracks.compactMap(\.displayArtist)),
            ["Artist One", "Artist Two"]
        )
        XCTAssertEqual(Set(reloadedTracks.map(\.title)), ["Home"])
        let profile = PlaylistVibeProfile.build(from: reloadedTracks)
        let expected: Set<SongIdentity> = [
            SongIdentity(artist: "Artist One", title: "Home"),
            SongIdentity(artist: "Artist Two", title: "Home")
        ]

        XCTAssertEqual(profile.existingIdentities, expected)
        XCTAssertEqual(Set(profile.representativeAnchors.map(\.songIdentity)), expected)
    }

    func testUserArtistOverrideRetainsPrecedenceAfterRecommendationPersistenceRoundTrip() throws {
        let (container, context) = try makeTestContainer()
        let playlist = Playlist(name: "Override Precedence")
        context.insert(playlist)
        let recommendation = makeResolved(
            artist: "Canonical Artist",
            title: "Canonical Song",
            videoID: "override001"
        )
        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in [] },
            safeResolve: { _ in nil }
        )

        let inserted = try XCTUnwrap(service.addRecommendation(
            recommendation,
            to: playlist,
            in: context,
            existingLibraryTracks: []
        ))
        inserted.userArtistOverride = "My Corrected Artist"
        try context.save()

        let reloaded = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<Track>())
                .first { $0.youtubeVideoID == "override001" }
        )
        let anchor = try XCTUnwrap(
            PlaylistVibeProfile.build(from: [reloaded]).representativeAnchors.first
        )

        XCTAssertEqual(anchor.songIdentity.artist, "My Corrected Artist")
        XCTAssertEqual(anchor.songIdentity.title, "Canonical Song")
        guard case .userOverride = anchor.artistSource else {
            return XCTFail("Expected explicit user override to remain authoritative")
        }
    }

    func testUserEditedTitleRetainsPrecedenceOverPersistedRecommendationTitle() throws {
        let (container, context) = try makeTestContainer()
        let playlist = Playlist(name: "Title Override")
        context.insert(playlist)
        let recommendation = makeResolved(
            artist: "Canonical Artist",
            title: "Canonical Song",
            videoID: "override002"
        )
        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in [] },
            safeResolve: { _ in nil }
        )

        let inserted = try XCTUnwrap(service.addRecommendation(
            recommendation,
            to: playlist,
            in: context,
            existingLibraryTracks: []
        ))
        inserted.title = "My Corrected Title"
        try context.save()

        let reloaded = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<Track>())
                .first { $0.youtubeVideoID == "override002" }
        )
        let anchor = try XCTUnwrap(
            PlaylistVibeProfile.build(from: [reloaded]).representativeAnchors.first
        )

        XCTAssertEqual(anchor.songIdentity.artist, "Canonical Artist")
        XCTAssertEqual(anchor.songIdentity.title, "My Corrected Title")
    }

    func testLegacyTrackWithoutRecommendationProvenanceUsesExistingParser() {
        let legacy = makeTrack(
            id: "legacy00001",
            title: "Legacy Artist - Legacy Song",
            artist: "Archive Uploader"
        )

        XCTAssertNil(legacy.authoritativeRecommendationTitle)
        XCTAssertNil(legacy.authoritativeRecommendationArtist)
        let anchor = PlaylistVibeProfile.build(from: [legacy]).representativeAnchors.first

        XCTAssertEqual(
            anchor?.songIdentity,
            SongIdentity(artist: "Legacy Artist", title: "Legacy Song")
        )
    }

    func testExistingLibraryTrackIsReusedAndGainsRecommendationProvenance() throws {
        let (container, context) = try makeTestContainer()
        let playlist = Playlist(name: "Existing Track")
        let existing = makeTrack(
            id: "existing001",
            title: "West Coast",
            artist: "SomeFanArchive"
        )
        context.insert(playlist)
        context.insert(existing)
        try context.save()
        let recommendation = makeResolved(
            artist: "Lana Del Rey",
            title: "West Coast",
            videoID: "existing001",
            youtubeTitle: "West Coast (fan upload)",
            uploader: "SomeFanArchive"
        )
        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in [] },
            safeResolve: { _ in nil }
        )

        let added = try XCTUnwrap(service.addRecommendation(
            recommendation,
            to: playlist,
            in: context,
            existingLibraryTracks: [existing]
        ))

        XCTAssertTrue(added === existing)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Track>()).count, 1)
        XCTAssertEqual(existing.channelTitle, "SomeFanArchive")
        XCTAssertEqual(
            existing.persistedAuthoritativeRecommendationIdentity,
            SongIdentity(artist: "Lana Del Rey", title: "West Coast")
        )
        XCTAssertEqual(
            PlaylistVibeProfile.build(from: [existing])
                .representativeAnchors.first?.songIdentity,
            SongIdentity(artist: "Lana Del Rey", title: "West Coast")
        )
    }

    func testRecommendationPromotionPreservesTransportMetadata() throws {
        let (container, context) = try makeTestContainer()
        let playlist = Playlist(name: "Transport Metadata")
        context.insert(playlist)
        let thumbnailURL = URL(string: "https://example.com/canonical-cover.jpg")!
        let recommendation = ResolvedRecommendation(
            artist: "Canonical Artist",
            title: "Canonical Song",
            match: 0.9,
            youtubeResult: YouTubeSearchResult(
                youtubeVideoID: "metadata001",
                title: "Misleading Upload Title",
                channelTitle: "Unrelated Uploader",
                thumbnailURL: thumbnailURL,
                duration: 321
            )
        )
        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in [] },
            safeResolve: { _ in nil }
        )

        XCTAssertNotNil(service.addRecommendation(
            recommendation,
            to: playlist,
            in: context,
            existingLibraryTracks: []
        ))
        let reloaded = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<Track>())
                .first { $0.youtubeVideoID == "metadata001" }
        )

        XCTAssertEqual(reloaded.youtubeVideoID, "metadata001")
        XCTAssertEqual(reloaded.thumbnailURL, thumbnailURL)
        XCTAssertEqual(reloaded.duration, 321)
        XCTAssertEqual(reloaded.title, "Canonical Song")
        XCTAssertEqual(reloaded.channelTitle, "Canonical Artist")
        XCTAssertEqual(reloaded.authoritativeRecommendationTitle, "Canonical Song")
        XCTAssertEqual(reloaded.authoritativeRecommendationArtist, "Canonical Artist")
    }

    func testManualTrackDoesNotBecomeAuthoritativeRecommendationIdentity() {
        let manual = makeTrack(
            id: "manual00001",
            title: "Artist Name - Song Name",
            artist: "Artist Name"
        )

        XCTAssertNil(manual.persistedAuthoritativeRecommendationIdentity)
        XCTAssertEqual(
            PlaylistVibeProfile.build(from: [manual])
                .representativeAnchors.first?.songIdentity,
            SongIdentity(artist: "Artist Name", title: "Song Name")
        )
    }

    func testRawUploaderMetadataRemainsLowConfidenceForLegacyTrack() {
        let upload = makeTrack(
            id: "uploader001",
            title: "A Song Without Artist Attribution",
            artist: "Random Upload Channel"
        )

        let profile = PlaylistVibeProfile.build(from: [upload])

        XCTAssertNil(upload.persistedAuthoritativeRecommendationIdentity)
        XCTAssertTrue(profile.representativeAnchors.isEmpty)
        XCTAssertTrue(profile.existingIdentities.isEmpty)
    }
}
