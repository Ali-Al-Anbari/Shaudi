import XCTest
@testable import Shaudi

@MainActor
final class RecommendationFeedbackTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var storageKey: String!

    override func setUp() {
        super.setUp()
        suiteName = "RecommendationFeedbackTests.\(UUID().uuidString)"
        storageKey = "feedback"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        RecommendationFeedbackStore.shared.clearAll()
    }

    override func tearDown() {
        RecommendationFeedbackStore.shared.clearAll()
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        storageKey = nil
        super.tearDown()
    }

    func testMoreLikeThisPreferencePersists() {
        let identity = SongIdentity(artist: "Lana Del Rey", title: "West Coast")
        makeStore().record(.moreLikeThis, identity: identity)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.snapshot.moreLikeSongs.count, 1)
        XCTAssertGreaterThan(reloaded.snapshot.scoreAdjustment(for: identity), 0)
    }

    func testLessLikeThisPreferencePersistsWithoutBlockingArtist() {
        let identity = SongIdentity(artist: "Lana Del Rey", title: "West Coast")
        makeStore().record(.lessLikeThis, identity: identity)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.snapshot.lessLikeSongs.count, 1)
        XCTAssertLessThan(reloaded.snapshot.scoreAdjustment(for: identity), 0)
        XCTAssertTrue(
            reloaded.snapshot.allowsAutomaticRecommendation(
                SongIdentity(artist: "Lana Del Rey", title: "Video Games")
            )
        )
    }

    func testBlockedArtistPersistsAndNormalizationAvoidsDuplicates() {
        let store = makeStore()
        for artist in ["Lana Del Rey", "lana del rey", "  Lana Del Rey  "] {
            store.record(
                .dontRecommendArtist,
                identity: SongIdentity(artist: artist, title: "Song")
            )
        }

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.snapshot.excludedArtistNames.count, 1)
        XCTAssertTrue(reloaded.snapshot.isArtistExcluded("LANA DEL REY"))
    }

    func testBlockedArtistIsRejectedBeforeYouTubeResolution() async throws {
        let store = makeStore()
        let identity = SongIdentity(artist: "Blocked Artist", title: "Song")
        store.record(.dontRecommendArtist, identity: identity)
        var resolutionCalls = 0
        let service = makeService(feedbackStore: store) { _ in
            resolutionCalls += 1
            return [self.youtubeResult(artist: identity.artist, title: identity.title)]
        }

        let result = try await service.resolveOnYouTube(
            LastFMSimilarTrack(
                artist: identity.artist,
                title: identity.title,
                match: 1,
                url: nil
            )
        )

        XCTAssertNil(result)
        XCTAssertEqual(resolutionCalls, 0)
    }

    func testBlockedArtistDoesNotPreventManualSearchPlayback() {
        let identity = SongIdentity(artist: "Blocked Artist", title: "Manual Song")
        RecommendationFeedbackStore.shared.record(.dontRecommendArtist, identity: identity)
        let manager = PlaybackManager()
        let playable = PlayableTrack(
            youtubeVideoID: "manual-search",
            title: identity.title,
            channelTitle: identity.artist,
            thumbnailURL: nil,
            duration: nil
        )

        manager.seedManualSearchForTesting(playable)

        XCTAssertEqual(manager.currentPlayableTrack?.youtubeVideoID, "manual-search")
    }

    func testBlockedArtistRemovesAutomaticTrackButKeepsManualQueueItem() {
        let identity = SongIdentity(artist: "Blocked Artist", title: "Auto Song")
        let current = makeTrack(id: "current", artist: "Current Artist")
        let manual = makeTrack(id: "manual", artist: identity.artist)
        let automatic = makeTrack(id: "automatic", artist: identity.artist)
        let other = makeTrack(id: "other", artist: "Other Artist")
        let manager = PlaybackManager()
        manager.seedRecommendationQueueForTesting(
            tracks: [current, manual, automatic, other],
            currentIndex: 0,
            manualQueueCount: 1,
            identitiesByVideoID: [
                "manual": SongIdentity(artist: identity.artist, title: "Manual Song"),
                "automatic": identity,
                "other": SongIdentity(artist: "Other Artist", title: "Other Song")
            ]
        )

        manager.recordRecommendationFeedback(.dontRecommendArtist, for: identity)

        XCTAssertEqual(manager.upcomingQueueTracks.map(\.youtubeVideoID), ["manual", "other"])
        XCTAssertEqual(manager.currentPlayableTrack?.youtubeVideoID, "current")
    }

    func testMoreLikeThisDoesNotOverwhelmLastFMSimilarity() async throws {
        let store = makeStore()
        store.record(
            .moreLikeThis,
            identity: SongIdentity(artist: "Preferred Artist", title: "Preferred Song")
        )
        let service = rankedService(
            feedbackStore: store,
            candidates: [
                candidate("Other Artist", "Strong Match", match: 0.90),
                candidate("Preferred Artist", "Related Song", match: 0.75)
            ]
        )

        let ranked = try await service.rankedCandidates(
            for: seed(),
            excludingSongIdentities: []
        )

        XCTAssertEqual(ranked.first?.track.artist, "Other Artist")
    }

    func testLessLikeThisStronglyDownranksSongButDoesNotHardBlockArtist() async throws {
        let store = makeStore()
        store.record(
            .lessLikeThis,
            identity: SongIdentity(artist: "Artist", title: "Disliked Song")
        )
        let service = rankedService(
            feedbackStore: store,
            candidates: [
                candidate("Artist", "Disliked Song", match: 0.95),
                candidate("Artist", "Different Song", match: 0.80),
                candidate("Other", "Song", match: 0.75)
            ]
        )

        let ranked = try await service.rankedCandidates(
            for: seed(),
            excludingSongIdentities: []
        )

        XCTAssertNotEqual(ranked.first?.track.title, "Disliked Song")
        XCTAssertTrue(ranked.contains { $0.track.title == "Different Song" })
        XCTAssertTrue(ranked.contains { $0.track.title == "Disliked Song" })
    }

    func testRemovingOneArtistExclusionAndClearingAllFeedback() {
        let store = makeStore()
        let first = SongIdentity(artist: "First Artist", title: "One")
        let second = SongIdentity(artist: "Second Artist", title: "Two")
        store.record(.dontRecommendArtist, identity: first)
        store.record(.dontRecommendArtist, identity: second)
        store.record(.moreLikeThis, identity: first)
        store.record(.lessLikeThis, identity: second)

        store.removeExcludedArtist(" first artist ")
        XCTAssertFalse(store.snapshot.isArtistExcluded(first.artist))
        XCTAssertTrue(store.snapshot.isArtistExcluded(second.artist))

        store.clearAll()
        XCTAssertTrue(store.snapshot.isEmpty)
        XCTAssertTrue(makeStore().snapshot.isEmpty)
    }

    func testLastFMAuthoritativeArtistWinsOverUploaderText() {
        let result = ResolvedRecommendation(
            artist: "Lana Del Rey",
            title: "West Coast",
            match: 1,
            youtubeResult: YouTubeSearchResult(
                youtubeVideoID: "authoritative",
                title: "West Coast",
                channelTitle: "SomeFanArchive",
                thumbnailURL: nil
            )
        )

        XCTAssertEqual(result.transportMetadata.canonicalIdentity.artist, "Lana Del Rey")
        XCTAssertNotEqual(result.transportMetadata.canonicalIdentity.artist, "SomeFanArchive")
    }

    private func makeStore() -> RecommendationFeedbackStore {
        RecommendationFeedbackStore(defaults: defaults, storageKey: storageKey)
    }

    private func makeService(
        feedbackStore: RecommendationFeedbackStore,
        primarySearch: @escaping (String) async throws -> [YouTubeSearchResult]
    ) -> RecommendationService {
        RecommendationService(
            similarTracks: { _, _, _ in [] },
            videoResolver: YouTubeRecommendationResolver(
                primarySearch: primarySearch,
                dataAPISearch: { _ in [] }
            ),
            resolutionCache: FeedbackTestResolutionCache(),
            feedbackStore: feedbackStore
        )
    }

    private func rankedService(
        feedbackStore: RecommendationFeedbackStore,
        candidates: [LastFMSimilarTrack]
    ) -> RecommendationService {
        RecommendationService(
            similarTracks: { _, _, _ in candidates },
            videoResolver: YouTubeRecommendationResolver(
                primarySearch: { _ in [] },
                dataAPISearch: { _ in [] }
            ),
            resolutionCache: FeedbackTestResolutionCache(),
            feedbackStore: feedbackStore
        )
    }

    private func seed() -> RecommendationSeed {
        RecommendationSeed(
            youtubeVideoID: "seed",
            canonicalIdentity: SongIdentity(artist: "Seed Artist", title: "Seed Song"),
            youtubeTitle: "Seed Artist - Seed Song",
            youtubeChannel: "Seed Artist"
        )
    }

    private func candidate(_ artist: String, _ title: String, match: Double) -> LastFMSimilarTrack {
        LastFMSimilarTrack(artist: artist, title: title, match: match, url: nil)
    }

    private func youtubeResult(artist: String, title: String) -> YouTubeSearchResult {
        YouTubeSearchResult(
            youtubeVideoID: "resolved-video",
            title: "\(artist) - \(title)",
            channelTitle: artist,
            thumbnailURL: nil
        )
    }

    private func makeTrack(id: String, artist: String) -> Track {
        Track(
            title: "Song \(id)",
            youtubeURL: URL(string: "https://www.youtube.com/watch?v=\(id)")!,
            youtubeVideoID: id,
            channelTitle: artist
        )
    }
}

@MainActor
private final class FeedbackTestResolutionCache: YouTubeResolutionCaching {
    func peek(for identity: SongIdentity, now: Date) async -> YouTubeSearchResult? {
        nil
    }

    func result(for identity: SongIdentity, now: Date) async -> YouTubeSearchResult? {
        nil
    }

    func learn(
        _ identity: SongIdentity,
        videoID: String,
        metadata: YouTubeResolutionMetadata,
        source: YouTubeResolutionKnowledgeSource,
        now: Date
    ) async -> Bool {
        true
    }

    func remove(_ identity: SongIdentity) async {}
}
