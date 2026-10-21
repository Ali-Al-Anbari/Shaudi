import Foundation
import XCTest
@testable import Shaudi

@MainActor
final class ListenBrainzRadioFallbackTests: XCTestCase {
    func testHighConfidenceRecordingCallsListenBrainzOnce() async throws {
        var musicBrainzCalls = 0
        var listenBrainzCalls = 0
        let mbid = UUID()
        let recordings = try JSONDecoder().decode([ListenBrainzSimilarRecording].self, from: Data("""
        [{"recording_mbid":"f802669f-45aa-4ec6-8221-26a73739e440",
          "recording_name":"R.I.P.","artist_credit_name":"Playboi Carti","score":60}]
        """.utf8))
        let fallback = RadioListenBrainzFallback(
            recordingLookup: { _, _ in
                musicBrainzCalls += 1
                return MusicBrainzRecordingIdentity(
                    recordingMBID: mbid, artistMBID: UUID(), searchScore: 100,
                    confidence: "high", source: "musicbrainz-search", resolvedAt: .now
                )
            },
            similarLookup: { requested in
                listenBrainzCalls += 1
                XCTAssertEqual(requested, mbid)
                return recordings
            }
        )
        let candidates = try await fallback.candidates(for: seed(), baseMatch: 0.5, limit: 50)
        XCTAssertEqual(candidates.map(\.title), ["R.I.P."])
        XCTAssertEqual(musicBrainzCalls, 1)
        XCTAssertEqual(listenBrainzCalls, 1)
    }

    func testNoMusicBrainzMatchAndLowConfidenceSeedSkipListenBrainz() async throws {
        var musicBrainzCalls = 0
        var listenBrainzCalls = 0
        let fallback = RadioListenBrainzFallback(
            recordingLookup: { _, _ in musicBrainzCalls += 1; return nil },
            similarLookup: { _ in listenBrainzCalls += 1; return [] }
        )
        let noMatch = try await fallback.candidates(for: seed(), baseMatch: 0.5, limit: 50)
        XCTAssertTrue(noMatch.isEmpty)
        let lowConfidence = RecommendationSeed(
            youtubeVideoID: "unknown0001", rawTitle: "Silly Watch",
            displayedArtist: nil, sourceChannel: nil, userArtistOverride: nil
        )
        let skipped = try await fallback.candidates(for: lowConfidence, baseMatch: 0.5, limit: 50)
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(musicBrainzCalls, 1)
        XCTAssertEqual(listenBrainzCalls, 0)
    }

    func testEnoughLastFMCandidatesNeverCallsSecondarySource() async throws {
        var fallbackCalls = 0
        let service = makeService(
            similar: { _, _, _ in [
                self.candidate("A", "One"),
                self.candidate("B", "Two"),
                self.candidate("C", "Three")
            ] },
            fallback: { _, _ in fallbackCalls += 1; return [] }
        )
        let ranked = try await service.rankedCandidates(for: seed(), excludingSongIdentities: [])
        XCTAssertEqual(ranked.count, 3)
        XCTAssertEqual(fallbackCalls, 0)
    }

    func testEmptyLastFMActivatesFallbackOnceAndUsesExistingPipeline() async throws {
        var fallbackCalls = 0
        let service = makeService(
            similar: { _, _, _ in [] },
            fallback: { _, _ in
                fallbackCalls += 1
                return [self.candidate("Playboi Carti", "R.I.P.")]
            }
        )
        let batch = try await service.recommendations(
            for: seed(), excludingVideoIDs: [], excludingSongIdentities: [],
            context: resolutionContext()
        )
        XCTAssertEqual(fallbackCalls, 1)
        XCTAssertEqual(batch.recommendations.map(\.title), ["R.I.P."])
    }

    func testPartialLastFMCandidatesStayAndCrossProviderDuplicatesAreRemoved() async throws {
        var baseMatch: Double?
        let service = makeService(
            similar: { _, _, _ in [self.candidate("Artist A", "Song A")] },
            fallback: { _, base in
                baseMatch = base
                return [
                    self.candidate("artist a", "Song A"),
                    self.candidate("Artist B", "Song B"),
                    self.candidate("Artist C", "Song C")
                ]
            }
        )
        let ranked = try await service.rankedCandidates(for: seed(), excludingSongIdentities: [])
        XCTAssertEqual(ranked.count, 3)
        XCTAssertEqual(ranked.filter { $0.identity == SongIdentity(artist: "Artist A", title: "Song A") }.count, 1)
        XCTAssertEqual(baseMatch, 0.98)
    }

    func testBlockedAndSeenArtistsRemainFiltered() async throws {
        let feedback = RecommendationFeedbackStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        feedback.record(.dontRecommendArtist, identity: SongIdentity(artist: "Blocked", title: "Any"))
        let service = makeService(
            similar: { _, _, _ in [] },
            fallback: { _, _ in [
                self.candidate("Blocked", "Bad"),
                self.candidate("Seen", "Old"),
                self.candidate("Allowed", "Fresh")
            ] },
            feedback: feedback
        )
        let ranked = try await service.rankedCandidates(
            for: seed(),
            excludingSongIdentities: [SongIdentity(artist: "Seen", title: "Old")]
        )
        XCTAssertEqual(ranked.map(\.identity), [SongIdentity(artist: "Allowed", title: "Fresh")])
    }

    func testLessLikeThisRemainsScorePenaltyAndFallbackFailureIsFinite() async throws {
        let feedback = RecommendationFeedbackStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        feedback.record(.lessLikeThis, identity: SongIdentity(artist: "Disliked", title: "Song"))
        let service = makeService(
            similar: { _, _, _ in [] },
            fallback: { _, _ in [
                self.candidate("Disliked", "Song"), self.candidate("Neutral", "Song")
            ] },
            feedback: feedback
        )
        let ranked = try await service.rankedCandidates(for: seed(), excludingSongIdentities: [])
        XCTAssertEqual(ranked.map(\.track.artist), ["Neutral", "Disliked"])

        var calls = 0
        let failing = makeService(
            similar: { _, _, _ in [self.candidate("LastFM", "Good")] },
            fallback: { _, _ in calls += 1; throw URLError(.timedOut) }
        )
        let retained = try await failing.rankedCandidates(for: seed(), excludingSongIdentities: [])
        XCTAssertEqual(retained.map(\.track.artist), ["LastFM"])
        XCTAssertEqual(calls, 1)
    }

    func testCancelledFallbackDoesNotReturnCandidates() async throws {
        let service = makeService(
            similar: { _, _, _ in [] },
            fallback: { _, _ in
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return [self.candidate("Late", "Song")]
            }
        )
        let task = Task {
            try await service.rankedCandidates(for: seed(), excludingSongIdentities: [])
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    private func seed() -> RecommendationSeed {
        RecommendationSeed(
            youtubeVideoID: "sillywatch1",
            canonicalIdentity: SongIdentity(artist: "Lil Uzi Vert", title: "Silly Watch"),
            youtubeTitle: "Lil Uzi Vert - Silly Watch", youtubeChannel: "Lil Uzi Vert"
        )
    }

    private func makeService(
        similar: @escaping (String, String, Int) async throws -> [LastFMSimilarTrack],
        fallback: @escaping RecommendationService.ListenBrainzFallbackOperation,
        feedback: RecommendationFeedbackStore? = nil
    ) -> RecommendationService {
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { query in
                guard query.contains("R.I.P.") else { return [] }
                return [YouTubeSearchResult(
                    youtubeVideoID: "cartirip0001", title: "Playboi Carti - R.I.P.",
                    channelTitle: "Playboi Carti", thumbnailURL: nil
                )]
            },
            dataAPISearch: { _ in [] }
        )
        return RecommendationService(
            similarTracks: similar,
            topTracks: { _, _ in [] },
            videoResolver: resolver,
            resolutionCache: MemoryYouTubeResolutionCache(),
            feedbackStore: feedback ?? RecommendationFeedbackStore(
                defaults: UserDefaults(suiteName: UUID().uuidString)!
            ),
            personalizationStore: RecommendationPersonalizationStore(),
            listenBrainzFallback: fallback
        )
    }

    private func resolutionContext() -> RecommendationResolutionContext {
        RecommendationResolutionContext(
            sessionID: UUID(), epochID: UUID(), upcomingCount: 0
        )
    }
}
