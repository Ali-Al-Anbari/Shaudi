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
            feedback.scoreAdjustment(for: target) + profile.adjustment(for: target).total,
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
            feedback.scoreAdjustment(for: target) + profile.adjustment(for: target).total,
            -0.25
        )
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
