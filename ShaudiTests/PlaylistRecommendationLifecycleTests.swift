import SwiftData
import XCTest
@testable import Shaudi

@MainActor
final class PlaylistRecommendationLifecycleTests: XCTestCase {
    private func track(_ id: String, artist: String = "Seed", title: String = "Seed Song") -> Track {
        Track(
            title: title, youtubeURL: URL(string: "https://www.youtube.com/watch?v=\(id)")!,
            youtubeVideoID: id, channelTitle: artist,
            authoritativeRecommendationTitle: title,
            authoritativeRecommendationArtist: artist
        )
    }

    private func resolved(_ id: String, artist: String, title: String) -> ResolvedRecommendation {
        ResolvedRecommendation(
            artist: artist, title: title, match: 0.8,
            youtubeResult: YouTubeSearchResult(
                youtubeVideoID: id, title: "\(artist) - \(title)",
                channelTitle: artist, thumbnailURL: nil, duration: nil
            )
        )
    }

    private func candidate(_ artist: String, _ title: String) -> ScoredPlaylistCandidate {
        ScoredPlaylistCandidate(
            track: LastFMSimilarTrack(artist: artist, title: title, match: 0.8, url: nil),
            identity: SongIdentity(artist: artist, title: title),
            score: 0.8, supportingAnchorCount: 1
        )
    }

    private func service(
        feedback: RecommendationFeedbackStore? = nil,
        similar: @escaping PlaylistRecommendationService.SimilarTracksOperation = { _, _, _, _ in [] },
        safe: @escaping PlaylistRecommendationService.SafeResolverOperation = { _ in nil },
        official: @escaping PlaylistRecommendationService.OfficialResolverOperation = { _ in nil }
    ) -> PlaylistRecommendationService {
        PlaylistRecommendationService(
            similarTracks: similar, safeResolve: safe, officialResolve: official,
            feedbackStore: feedback ?? RecommendationFeedbackStore(
                defaults: UserDefaults(suiteName: UUID().uuidString)!
            ),
            personalizationStore: .shared,
            rejectionStore: PlaylistRejectionStore(
                defaults: UserDefaults(suiteName: UUID().uuidString)!
            ),
            cache: PlaylistRecommendationCache()
        )
    }

    func testRequestTokenRejectsOlderGenerationAndDismissedView() {
        var request = PlaylistRecommendationRequestState()
        let old = request.begin(signature: ["a"])
        let newer = request.begin(signature: ["a"])
        XCTAssertFalse(request.matches(old, signature: ["a"]))
        XCTAssertTrue(request.matches(newer, signature: ["a"]))
        XCTAssertFalse(request.matches(newer, signature: ["a", "b"]))
        request.invalidate()
        XCTAssertFalse(request.matches(newer, signature: ["a"]))
    }

    func testSignatureDetectsReplacementAndCanonicalIdentityEdit() throws {
        let engine = service()
        let container = try ModelContainer(
            for: Track.self, Playlist.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let first = track("same", artist: "Artist A", title: "Song")
        let replacement = track("same", artist: "Artist A", title: "Song")
        context.insert(first)
        context.insert(replacement)
        try context.save()
        let original = engine.trackSignature(for: [first])
        XCTAssertNotEqual(original, engine.trackSignature(for: [replacement]))
        first.authoritativeRecommendationArtist = "Artist B"
        XCTAssertNotEqual(original, engine.trackSignature(for: [first]))
    }

    func testCacheFiltersBlockedRejectedAndDuplicateItemsWithoutNetwork() async throws {
        let feedback = RecommendationFeedbackStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        var calls = 0
        let engine = service(feedback: feedback, similar: { _, _, _, _ in
            calls += 1
            return []
        })
        let tracks = [track("seed")]
        let blocked = resolved("blocked", artist: "Blocked", title: "Bad")
        let rejected = resolved("rejected", artist: "Rejected", title: "No")
        let valid = resolved("valid", artist: "Allowed", title: "Yes")
        engine.cache.set(
            playlistID: "p", trackSignature: engine.trackSignature(for: tracks),
            result: PlaylistRecommendationResult(
                visibleRecommendations: [blocked, rejected, valid, valid],
                spareResolved: [resolved("seed", artist: "Seed", title: "Seed Song")],
                deferredCandidates: []
            )
        )
        feedback.record(.dontRecommendArtist, identity: blocked.songIdentity)
        engine.rejectionStore.reject(rejected.songIdentity, videoID: "rejected", for: "p")

        let result = try await engine.recommendations(for: tracks, playlistID: "p")
        XCTAssertEqual(result.visibleRecommendations.map(\.youtubeResult.youtubeVideoID), ["valid"])
        XCTAssertTrue(result.spareResolved.isEmpty)
        XCTAssertEqual(calls, 0)
    }

    func testSpareAndDeferredCandidatesUseCurrentAdmissionRules() async throws {
        var officialCalls = 0
        let engine = service(official: { candidate in
            officialCalls += 1
            return self.resolved("official", artist: candidate.artist, title: candidate.title)
        })
        let tracks = [track("seed")]
        let visible = resolved("visible", artist: "Visible", title: "Song")
        let rejected = resolved("rejected", artist: "Rejected", title: "Song")
        let allowedSpare = resolved("spare", artist: "Spare", title: "Song")
        engine.rejectionStore.reject(rejected.songIdentity, videoID: "rejected", for: "p")
        let initial = PlaylistRecommendationResult(
            visibleRecommendations: [visible],
            spareResolved: [rejected, allowedSpare, allowedSpare],
            deferredCandidates: [
                candidate("Seed", "Seed Song"),
                candidate("Deferred", "Song"),
                candidate("Deferred", "Song")
            ]
        )
        let afterReject = engine.rejectRecommendation(
            visible, from: initial, playlistID: "p", currentTracks: tracks
        )
        XCTAssertEqual(afterReject.visibleRecommendations.map(\.youtubeResult.youtubeVideoID), ["spare"])
        XCTAssertEqual(afterReject.deferredCandidates.count, 1)
        XCTAssertEqual(officialCalls, 0)

        let found = try await engine.findMore(for: tracks, playlistID: "p", currentResult: afterReject)
        XCTAssertEqual(found.visibleRecommendations.map(\.youtubeResult.youtubeVideoID), ["spare", "official"])
        XCTAssertEqual(officialCalls, 1)
    }

    func testMembershipChangeDuringGenerationDiscardsResultAndCacheWrite() async throws {
        var pending: CheckedContinuation<[LastFMSimilarTrack], Error>?
        var currentTracks = [track("seed")]
        let engine = service(
            similar: { _, _, _, _ in
                try await withCheckedThrowingContinuation { pending = $0 }
            },
            safe: { item in self.resolved("candidate", artist: item.artist, title: item.title) }
        )
        let task = Task {
            try await engine.recommendations(
                for: currentTracks, playlistID: "p",
                currentTracks: { currentTracks }
            )
        }
        while pending == nil { await Task.yield() }
        currentTracks.append(track("candidate", artist: "New", title: "Song"))
        pending?.resume(returning: [LastFMSimilarTrack(artist: "New", title: "Song", match: 0.8, url: nil)])
        do {
            _ = try await task.value
            XCTFail("Stale result should be discarded")
        } catch is CancellationError {}
        XCTAssertNil(engine.cache.get(playlistID: "p", trackSignature: engine.trackSignature(for: currentTracks)))
    }

    func testFindMoreAfterNewGenerationOrDismissalCannotWriteCache() async throws {
        var pending: CheckedContinuation<ResolvedRecommendation?, Error>?
        let tracks = [track("seed")]
        let engine = service(official: { _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        })
        let initial = PlaylistRecommendationResult(
            visibleRecommendations: [], spareResolved: [],
            deferredCandidates: [candidate("Other", "Song")]
        )
        var request = PlaylistRecommendationRequestState()
        let id = request.begin(signature: engine.trackSignature(for: tracks))
        let task = Task {
            try await engine.findMore(
                for: tracks, playlistID: "p", currentResult: initial,
                isCurrent: { request.matches(id, signature: engine.trackSignature(for: tracks)) }
            )
        }
        while pending == nil { await Task.yield() }
        request.invalidate()
        pending?.resume(returning: resolved("other", artist: "Other", title: "Song"))
        do {
            _ = try await task.value
            XCTFail("Dismissed Find More should be discarded")
        } catch is CancellationError {}
        XCTAssertNil(engine.cache.get(playlistID: "p", trackSignature: engine.trackSignature(for: tracks)))

        pending = nil
        let olderID = request.begin(signature: engine.trackSignature(for: tracks))
        let olderTask = Task {
            try await engine.findMore(
                for: tracks, playlistID: "p", currentResult: initial,
                isCurrent: { request.matches(olderID, signature: engine.trackSignature(for: tracks)) }
            )
        }
        while pending == nil { await Task.yield() }
        let newerID = request.begin(signature: engine.trackSignature(for: tracks))
        pending?.resume(returning: resolved("other", artist: "Other", title: "Song"))
        do {
            _ = try await olderTask.value
            XCTFail("Older Find More should be discarded")
        } catch is CancellationError {}
        XCTAssertTrue(request.matches(newerID, signature: engine.trackSignature(for: tracks)))
        XCTAssertNil(engine.cache.get(playlistID: "p", trackSignature: engine.trackSignature(for: tracks)))
    }

    func testFindMoreMembershipChangeWhileAwaitingDiscardsResult() async throws {
        var pending: CheckedContinuation<ResolvedRecommendation?, Error>?
        var currentTracks = [track("seed")]
        let engine = service(official: { _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        })
        let initial = PlaylistRecommendationResult(
            visibleRecommendations: [], spareResolved: [],
            deferredCandidates: [candidate("Other", "Song")]
        )
        let task = Task {
            try await engine.findMore(
                for: currentTracks, playlistID: "p", currentResult: initial,
                currentTracks: { currentTracks }
            )
        }
        while pending == nil { await Task.yield() }
        currentTracks.append(track("other", artist: "Other", title: "Song"))
        pending?.resume(returning: resolved("other", artist: "Other", title: "Song"))
        do {
            _ = try await task.value
            XCTFail("Changed playlist must invalidate Find More")
        } catch is CancellationError {}
        XCTAssertNil(engine.cache.get(playlistID: "p", trackSignature: engine.trackSignature(for: currentTracks)))
    }

    func testOlderGenerationWithSamePlaylistStateCannotReplaceNewRequest() async throws {
        var pending: CheckedContinuation<[LastFMSimilarTrack], Error>?
        let tracks = [track("seed")]
        let engine = service(
            similar: { _, _, _, _ in
                try await withCheckedThrowingContinuation { pending = $0 }
            },
            safe: { item in self.resolved("other", artist: item.artist, title: item.title) }
        )
        var request = PlaylistRecommendationRequestState()
        let oldID = request.begin(signature: engine.trackSignature(for: tracks))
        let task = Task {
            try await engine.recommendations(
                for: tracks, playlistID: "p",
                isCurrent: { request.matches(oldID, signature: engine.trackSignature(for: tracks)) }
            )
        }
        while pending == nil { await Task.yield() }
        let newID = request.begin(signature: engine.trackSignature(for: tracks))
        pending?.resume(returning: [
            LastFMSimilarTrack(artist: "Other", title: "Song", match: 0.8, url: nil)
        ])
        do {
            _ = try await task.value
            XCTFail("Older generation must be discarded")
        } catch is CancellationError {}
        XCTAssertTrue(request.matches(newID, signature: engine.trackSignature(for: tracks)))
        XCTAssertNil(engine.cache.get(playlistID: "p", trackSignature: engine.trackSignature(for: tracks)))
    }

    func testCurrentMembershipExcludesResolvedCandidateAndOfficialFallbackIsExplicit() async throws {
        var officialCalls = 0
        let engine = service(
            similar: { _, _, _, _ in
                [LastFMSimilarTrack(artist: "Other", title: "Song", match: 0.8, url: nil)]
            },
            safe: { _ in nil },
            official: { _ in
                officialCalls += 1
                return self.resolved("already", artist: "Other", title: "Song")
            }
        )
        let tracks = [track("seed"), track("already", artist: "Other", title: "Song")]
        let result = try await engine.recommendations(for: tracks)
        XCTAssertEqual(officialCalls, 0)
        let initial = PlaylistRecommendationResult(
            visibleRecommendations: [], spareResolved: [],
            deferredCandidates: [candidate("Other", "Song")]
        )
        let found = try await engine.findMore(for: tracks, playlistID: nil, currentResult: initial)
        XCTAssertTrue(found.visibleRecommendations.isEmpty)
        XCTAssertEqual(officialCalls, 0)
        XCTAssertTrue(result.visibleRecommendations.isEmpty)
    }
}
