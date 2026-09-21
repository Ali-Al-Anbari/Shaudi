import Foundation
import XCTest
@testable import Shaudi

@MainActor
final class RecommendationPersonalizationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testColdStartAndUnknownArtistAreNeutral() {
        let profile = RecommendationPersonalizationProfile.empty
        let adjustment = profile.adjustment(for: identity("Unknown", "Discovery"))

        XCTAssertEqual(adjustment, .neutral)
        XCTAssertEqual(adjustment.total, 0)
    }

    func testColdStartPreservesLastFMOrdering() async throws {
        let stores = makeStores(profile: .empty)
        let service = service(
            candidates: [
                candidate("Lower", "Song", match: 0.70),
                candidate("Higher", "Song", match: 0.90)
            ],
            feedback: stores.feedback,
            personalization: stores.personalization
        )

        let ranked = try await service.rankedCandidates(
            for: seed(),
            excludingSongIdentities: []
        )

        XCTAssertEqual(ranked.map(\.track.artist), ["Higher", "Lower"])
    }

    func testFrequentlyEngagedArtistGetsBoundedPositiveBoost() {
        let events = (0..<8).map { index in
            event(
                artist: "Paramore",
                title: "Song \(index)",
                listened: 190,
                duration: 200,
                outcome: .naturalCompletion
            )
        }
        let profile = RecommendationPersonalizationProfile(events: events, now: now)
        let adjustment = profile.adjustment(for: identity("Paramore", "New Song"))

        XCTAssertGreaterThan(adjustment.artist, 0)
        XCTAssertLessThanOrEqual(adjustment.artist, 0.075)
        XCTAssertLessThanOrEqual(adjustment.total, 0.10)
    }

    func testRepeatedEarlySkipsAreNegativeButOneShortListenIsNotStrong() {
        let skipped = event(
            artist: "Skipped Artist",
            title: "Skipped Song",
            listened: 8,
            duration: 200,
            outcome: .manualNext
        )
        let one = RecommendationPersonalizationProfile(events: [skipped], now: now)
            .adjustment(for: skipped.identity)
        let repeated = RecommendationPersonalizationProfile(
            events: [skipped, skipped, skipped],
            now: now
        ).adjustment(for: skipped.identity)

        XCTAssertLessThan(one.total, 0)
        XCTAssertGreaterThan(one.total, -0.04)
        XCTAssertLessThan(repeated.total, one.total)
        XCTAssertGreaterThanOrEqual(repeated.total, -0.12)
    }

    func testShortListenWithoutManualNextOrDurationRemainsNeutral() {
        let short = event(
            artist: "Accidental",
            title: "Short",
            listened: 8,
            duration: nil,
            outcome: nil
        )

        XCTAssertEqual(
            RecommendationPersonalizationProfile(events: [short], now: now)
                .adjustment(for: short.identity).total,
            0
        )
    }

    func testEngagementBucketsUseAuthoritativeDurationThresholds() {
        XCTAssertEqual(bucket(listened: 8, duration: 200, outcome: .manualNext), .earlySkip)
        XCTAssertEqual(bucket(listened: 50, duration: 200), .meaningful)
        XCTAssertEqual(bucket(listened: 120, duration: 200), .strong)
        XCTAssertEqual(bucket(listened: 170, duration: 200), .nearCompletion)
        XCTAssertEqual(bucket(listened: 200, duration: nil), .strong)
        XCTAssertEqual(bucket(listened: 8, duration: nil, outcome: .manualNext), .neutral)
        XCTAssertEqual(bucket(listened: 8, duration: 200, outcome: .naturalCompletion), .neutral)
    }

    func testRepeatedPlaysStrengthenSongAndArtistAffinity() {
        let played = event(
            artist: "Green Day",
            title: "Basket Case",
            listened: 180,
            duration: 200,
            outcome: .naturalCompletion
        )
        let once = RecommendationPersonalizationProfile(events: [played], now: now)
            .adjustment(for: played.identity)
        let repeated = RecommendationPersonalizationProfile(
            events: [played, played, played],
            now: now
        ).adjustment(for: played.identity)

        XCTAssertGreaterThan(repeated.artist, once.artist)
        XCTAssertGreaterThan(repeated.song, once.song)
    }

    func testFrequentlyPlayedSongBoostsArtistNeighborhoodMoreThanExactReplay() {
        let played = event(
            artist: "Green Day",
            title: "Basket Case",
            listened: 190,
            duration: 200,
            outcome: .naturalCompletion
        )
        let profile = RecommendationPersonalizationProfile(
            events: Array(repeating: played, count: 8),
            now: now
        )

        XCTAssertGreaterThan(
            profile.adjustment(for: identity("Green Day", "New Song")).total,
            profile.adjustment(for: played.identity).total
        )
    }

    func testRecentEngagementOutweighsOldEquivalentEngagement() {
        let recent = event(
            artist: "Recent",
            title: "Song",
            listened: 180,
            duration: 200,
            outcome: .naturalCompletion,
            startedAt: now.addingTimeInterval(-86_400)
        )
        let old = event(
            artist: "Old",
            title: "Song",
            listened: 180,
            duration: 200,
            outcome: .naturalCompletion,
            startedAt: now.addingTimeInterval(-90 * 86_400)
        )
        let profile = RecommendationPersonalizationProfile(events: [recent, old], now: now)

        XCTAssertGreaterThan(
            profile.adjustment(for: recent.identity).total,
            profile.adjustment(for: old.identity).total
        )
    }

    func testMoreLikeThisOutweighsLimitedPassiveNegativeNoise() {
        let target = identity("Blink-182", "Dammit")
        let skipped = event(
            artist: target.artist,
            title: target.title,
            listened: 8,
            duration: 200,
            outcome: .manualNext
        )
        let profile = RecommendationPersonalizationProfile(events: [skipped, skipped], now: now)
        var feedback = RecommendationFeedbackSnapshot()
        feedback.record(.moreLikeThis, identity: target)

        XCTAssertGreaterThan(
            RecommendationAdjustment(
                identity: target, feedback: feedback, personalization: profile
            ).combined,
            0
        )
    }

    func testLessLikeThisIsStrongerThanPassivePositiveHistory() {
        let target = identity("Sum 41", "Fat Lip")
        let plays = (0..<8).map { _ in
            event(
                artist: target.artist,
                title: target.title,
                listened: 190,
                duration: 200,
                outcome: .naturalCompletion
            )
        }
        let profile = RecommendationPersonalizationProfile(events: plays, now: now)
        var feedback = RecommendationFeedbackSnapshot()
        feedback.record(.lessLikeThis, identity: target)

        XCTAssertLessThan(
            RecommendationAdjustment(
                identity: target, feedback: feedback, personalization: profile
            ).combined,
            -0.25
        )
    }

    func testExplicitSignalsKeepTheirDirectionAtPassiveBounds() {
        let liked = identity("Liked", "Song")
        let disliked = identity("Disliked", "Song")
        let positiveHistory = (0..<20).map { index in
            event(
                artist: disliked.artist,
                title: index < 2 ? disliked.title : "Nearby \(index)",
                listened: 190, duration: 200,
                outcome: .naturalCompletion
            )
        }
        let events = Array(repeating: event(
            artist: liked.artist, title: liked.title, listened: 8,
            duration: 200, outcome: .manualNext
        ), count: 20) + positiveHistory
        let profile = RecommendationPersonalizationProfile(events: events, now: now)
        var feedback = RecommendationFeedbackSnapshot()
        feedback.record(.moreLikeThis, identity: liked)
        feedback.record(.lessLikeThis, identity: disliked)

        let likedAdjustment = RecommendationAdjustment(
            identity: liked, feedback: feedback, personalization: profile
        )
        let dislikedAdjustment = RecommendationAdjustment(
            identity: disliked, feedback: feedback, personalization: profile
        )
        let artistContext = RecommendationAdjustment(
            identity: identity(disliked.artist, "Other Song"),
            feedback: feedback, personalization: profile
        )

        XCTAssertEqual(likedAdjustment.passive.total, -0.12, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(dislikedAdjustment.passive.total, 0.09)
        XCTAssertLessThanOrEqual(dislikedAdjustment.passive.total, 0.10)
        XCTAssertGreaterThan(likedAdjustment.combined, 0)
        XCTAssertLessThan(dislikedAdjustment.combined, 0)
        XCTAssertLessThan(artistContext.combined, 0)
        XCTAssertLessThan(dislikedAdjustment.combined, artistContext.combined)
        XCTAssertEqual(feedback.scoreAdjustment(for: liked), 0.085, accuracy: 0.0001)
        XCTAssertEqual(feedback.scoreAdjustment(for: disliked), -0.43, accuracy: 0.0001)
    }

    func testNoExplicitFeedbackLeavesPassiveSignalUntouched() {
        let target = identity("Passive", "Song")
        let listeningEvent = event(
            artist: target.artist, title: target.title, listened: 190,
            duration: 200, outcome: .naturalCompletion
        )
        let profile = RecommendationPersonalizationProfile(events: [listeningEvent], now: now)
        let feedback = RecommendationFeedbackSnapshot()
        let adjustment = RecommendationAdjustment(
            identity: target, feedback: feedback, personalization: profile
        )
        XCTAssertEqual(adjustment.explicit, 0)
        XCTAssertEqual(adjustment.combined, profile.adjustment(for: target).total)
        XCTAssertEqual(
            RecommendationAdjustment(
                identity: identity("Unknown", "Discovery"),
                feedback: feedback, personalization: profile
            ).combined,
            0
        )
    }

    func testRadioInitialAndReservoirRankWithSamePreferenceContribution() async throws {
        let liked = identity("Liked Artist", "Liked Song")
        let profile = RecommendationPersonalizationProfile(
            events: Array(repeating: event(
                artist: liked.artist, title: liked.title, listened: 8,
                duration: 200, outcome: .manualNext
            ), count: 20),
            now: now
        )
        let stores = makeStores(profile: profile)
        stores.feedback.record(.moreLikeThis, identity: liked)
        let candidates = [
            candidate("Neutral Artist", "Neutral Song", match: 0.72),
            candidate(liked.artist, liked.title, match: 0.70)
        ]
        let radio = service(
            candidates: candidates,
            feedback: stores.feedback,
            personalization: stores.personalization
        )

        let initial = try await radio.rankedCandidates(
            for: seed(), excludingSongIdentities: []
        )
        let reservoir = radio.personalizedCandidates(candidates)
        XCTAssertEqual(initial.map(\.identity), reservoir.map {
            identity($0.artist, $0.title)
        })
        let adjustment = RecommendationAdjustment(
            identity: liked,
            feedback: stores.feedback.snapshot,
            personalization: stores.personalization.profile
        )
        let rankedLiked = try XCTUnwrap(initial.first { $0.identity == liked })
        XCTAssertEqual(rankedLiked.score, 0.70 + adjustment.combined, accuracy: 0.0001)
        XCTAssertEqual(initial.first?.identity, liked)
    }

    func testPlaylistUsesSharedPreferenceWithIndependentAnchorSupport() async throws {
        let target = identity("Target Artist", "Target Song")
        let stores = makeStores(profile: RecommendationPersonalizationProfile(
            events: Array(repeating: event(
                artist: target.artist, title: target.title, listened: 8,
                duration: 200, outcome: .manualNext
            ), count: 20),
            now: now
        ))
        stores.feedback.record(.moreLikeThis, identity: target)
        let similar = candidate(target.artist, target.title, match: 0.8)
        let playlist = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in [similar] },
            safeResolve: { _ in nil },
            officialResolve: { _ in nil },
            feedbackStore: stores.feedback,
            personalizationStore: stores.personalization,
            rejectionStore: PlaylistRejectionStore(
                defaults: UserDefaults(suiteName: UUID().uuidString)!
            ),
            cache: PlaylistRecommendationCache()
        )
        let firstSeed = seed()
        let secondSeed = RecommendationSeed(
            youtubeVideoID: "second",
            canonicalIdentity: identity("Second Artist", "Second Song"),
            youtubeTitle: "Second Artist - Second Song",
            youtubeChannel: "Second Artist"
        )
        func vibe(_ anchors: [RecommendationSeed]) -> PlaylistVibeProfile {
            PlaylistVibeProfile(
                representativeAnchors: anchors,
                existingIdentities: [],
                existingVideoIDs: []
            )
        }
        let oneCandidates = try await playlist.fetchAndRankCandidates(profile: vibe([firstSeed]))
        let twoCandidates = try await playlist.fetchAndRankCandidates(profile: vibe([firstSeed, secondSeed]))
        let one = try XCTUnwrap(oneCandidates.first)
        let two = try XCTUnwrap(twoCandidates.first)
        let shared = RecommendationAdjustment(
            identity: target,
            feedback: stores.feedback.snapshot,
            personalization: stores.personalization.profile
        )
        XCTAssertEqual(one.score, 0.8 + shared.combined, accuracy: 0.0001)
        XCTAssertEqual(two.score - one.score, 0.25, accuracy: 0.0001)
    }

    func testEqualInputsKeepDeterministicArtistOrder() async throws {
        let stores = makeStores(profile: .empty)
        let radio = service(
            candidates: [
                candidate("Z Artist", "Song", match: 0.8),
                candidate("A Artist", "Song", match: 0.8)
            ],
            feedback: stores.feedback,
            personalization: stores.personalization
        )
        let first = try await radio.rankedCandidates(for: seed(), excludingSongIdentities: [])
        let second = try await radio.rankedCandidates(for: seed(), excludingSongIdentities: [])
        XCTAssertEqual(first.map(\.identity), second.map(\.identity))
        XCTAssertEqual(first.map(\.track.artist), ["A Artist", "Z Artist"])
    }

    func testBlockedArtistOverridesStrongInferredAffinity() async throws {
        let target = identity("Blocked Artist", "Candidate")
        let profile = RecommendationPersonalizationProfile(
            events: (0..<10).map { _ in
                event(
                    artist: target.artist,
                    title: "Favorite",
                    listened: 190,
                    duration: 200,
                    outcome: .naturalCompletion
                )
            },
            now: now
        )
        let stores = makeStores(profile: profile)
        stores.feedback.record(.dontRecommendArtist, identity: target)
        let service = service(
            candidates: [candidate(target.artist, target.title, match: 1)],
            feedback: stores.feedback,
            personalization: stores.personalization
        )

        let ranked = try await service.rankedCandidates(
            for: seed(),
            excludingSongIdentities: []
        )

        XCTAssertTrue(ranked.isEmpty)
    }

    func testLastFMSimilarityRemainsDominantAndDiscoveryStaysEligible() async throws {
        let favoriteEvents = (0..<20).map { _ in
            event(
                artist: "Favorite Artist",
                title: "Favorite Song",
                listened: 190,
                duration: 200,
                outcome: .naturalCompletion
            )
        }
        let stores = makeStores(
            profile: RecommendationPersonalizationProfile(events: favoriteEvents, now: now)
        )
        let service = service(
            candidates: [
                candidate("Discovery Artist", "Great Match", match: 0.92),
                candidate("Favorite Artist", "Weak Match", match: 0.75)
            ],
            feedback: stores.feedback,
            personalization: stores.personalization
        )

        let ranked = try await service.rankedCandidates(
            for: seed(),
            excludingSongIdentities: []
        )

        XCTAssertEqual(ranked.map(\.track.artist), ["Discovery Artist", "Favorite Artist"])
        XCTAssertEqual(
            stores.personalization.profile.adjustment(
                for: identity("Discovery Artist", "Great Match")
            ).total,
            0
        )
    }

    func testMalformedHistoryFailsNeutral() {
        let malformed = RecommendationListeningEvent(
            identity: identity("", ""),
            listenedDuration: .nan,
            authoritativeDuration: -1,
            startedAt: now,
            completionOutcome: .manualNext,
            confirmedPlay: true
        )
        let profile = RecommendationPersonalizationProfile(events: [malformed], now: now)

        XCTAssertTrue(profile.isEmpty)
    }

    private func bucket(
        listened: TimeInterval,
        duration: TimeInterval?,
        outcome: ListeningHistoryCompletionOutcome? = nil
    ) -> RecommendationEngagementBucket {
        RecommendationPersonalizationProfile.engagementBucket(
            listenedDuration: listened,
            authoritativeDuration: duration,
            completionOutcome: outcome
        )
    }

    private func identity(_ artist: String, _ title: String) -> SongIdentity {
        SongIdentity(artist: artist, title: title)
    }

    private func event(
        artist: String,
        title: String,
        listened: TimeInterval,
        duration: TimeInterval?,
        outcome: ListeningHistoryCompletionOutcome?,
        startedAt: Date? = nil
    ) -> RecommendationListeningEvent {
        RecommendationListeningEvent(
            identity: identity(artist, title),
            listenedDuration: listened,
            authoritativeDuration: duration,
            startedAt: startedAt ?? now,
            completionOutcome: outcome,
            confirmedPlay: true
        )
    }

    private func candidate(
        _ artist: String,
        _ title: String,
        match: Double
    ) -> LastFMSimilarTrack {
        LastFMSimilarTrack(artist: artist, title: title, match: match, url: nil)
    }

    private func seed() -> RecommendationSeed {
        RecommendationSeed(
            youtubeVideoID: "seed",
            canonicalIdentity: identity("Seed Artist", "Seed Song"),
            youtubeTitle: "Seed Artist - Seed Song",
            youtubeChannel: "Seed Artist"
        )
    }

    private func makeStores(
        profile: RecommendationPersonalizationProfile
    ) -> (
        feedback: RecommendationFeedbackStore,
        personalization: RecommendationPersonalizationStore
    ) {
        let suite = "RecommendationPersonalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let feedback = RecommendationFeedbackStore(defaults: defaults, storageKey: "feedback")
        let personalization = RecommendationPersonalizationStore()
        personalization.update(profile)
        return (feedback, personalization)
    }

    private func service(
        candidates: [LastFMSimilarTrack],
        feedback: RecommendationFeedbackStore,
        personalization: RecommendationPersonalizationStore
    ) -> RecommendationService {
        RecommendationService(
            similarTracks: { _, _, _ in candidates },
            videoResolver: YouTubeRecommendationResolver(
                primarySearch: { _ in [] },
                dataAPISearch: { _ in [] }
            ),
            resolutionCache: PersonalizationTestResolutionCache(),
            feedbackStore: feedback,
            personalizationStore: personalization
        )
    }
}

@MainActor
private final class PersonalizationTestResolutionCache: YouTubeResolutionCaching {
    func peek(for identity: SongIdentity, now: Date) async -> YouTubeSearchResult? { nil }
    func result(for identity: SongIdentity, now: Date) async -> YouTubeSearchResult? { nil }

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
