import SwiftData
import XCTest
@testable import Shaudi

@MainActor
final class PlaylistRecommendationPoolTests: XCTestCase {
    // SwiftData models must not outlive the container that owns their context.
    private var retainedContainers: [ModelContainer] = []

    private func fixture() throws -> (ModelContainer, Playlist, Track) {
        let container = try ModelContainer(
            for: Track.self, Playlist.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let seed = Track(
            title: "Seed Song",
            youtubeURL: URL(string: "https://www.youtube.com/watch?v=seed0000001")!,
            youtubeVideoID: "seed0000001",
            channelTitle: "Seed Artist",
            authoritativeRecommendationTitle: "Seed Song",
            authoritativeRecommendationArtist: "Seed Artist"
        )
        let playlist = Playlist(name: "Pool Test", tracks: [seed])
        container.mainContext.insert(seed)
        container.mainContext.insert(playlist)
        try container.mainContext.save()
        retainedContainers.append(container)
        return (container, playlist, seed)
    }

    private func recommendation(_ batch: Int, _ index: Int) -> ResolvedRecommendation {
        let artist = "Artist \(batch) \(index)"
        let title = "Song \(batch) \(index)"
        return ResolvedRecommendation(
            artist: artist, title: title, match: 0.8,
            youtubeResult: YouTubeSearchResult(
                youtubeVideoID: "v\(batch)-\(index)",
                title: "\(artist) - \(title)",
                channelTitle: artist,
                thumbnailURL: URL(string: "https://example.test/art/\(batch)/\(index).jpg"),
                duration: 180
            )
        )
    }

    private func candidates(_ batch: Int) -> [LastFMSimilarTrack] {
        (1...5).map { index in
            LastFMSimilarTrack(
                artist: "Artist \(batch) \(index)",
                title: "Song \(batch) \(index)",
                match: 0.8,
                url: nil
            )
        }
    }

    private func service(
        feedback: RecommendationFeedbackStore? = nil,
        rejection: PlaylistRejectionStore? = nil,
        similar: @escaping PlaylistRecommendationService.SimilarTracksOperation
    ) -> PlaylistRecommendationService {
        PlaylistRecommendationService(
            similarTracks: similar,
            safeResolve: { item in
                let numbers = item.title.split(separator: " ").compactMap { Int($0) }
                guard numbers.count == 2 else { return nil }
                return self.recommendation(numbers[0], numbers[1])
            },
            officialResolve: { _ in nil },
            feedbackStore: feedback ?? RecommendationFeedbackStore(
                defaults: UserDefaults(suiteName: UUID().uuidString)!
            ),
            personalizationStore: .shared,
            rejectionStore: rejection ?? PlaylistRejectionStore(
                defaults: UserDefaults(suiteName: UUID().uuidString)!
            ),
            cache: PlaylistRecommendationCache()
        )
    }

    private func ids(_ result: PlaylistRecommendationResult) -> [String] {
        result.visibleRecommendations.map(\.youtubeResult.youtubeVideoID)
    }

    func testEmptyPoolGeneratesFivePersistsAndNewContextLoadsWithoutNetwork() async throws {
        let (container, playlist, _) = try fixture()
        var calls = 0
        let engine = service { _, _, _, _ in
            calls += 1
            return self.candidates(1)
        }
        let generated = try await engine.generateIfPoolEmpty(for: playlist)
        XCTAssertEqual(ids(generated), (1...5).map { "v1-\($0)" })
        XCTAssertNotNil(playlist.recommendationPoolData)
        XCTAssertEqual(calls, 1)

        let secondContext = ModelContext(container)
        let restoredPlaylist = try XCTUnwrap(secondContext.fetch(FetchDescriptor<Playlist>()).first)
        let freshEngine = service { _, _, _, _ in
            calls += 1
            return self.candidates(2)
        }
        XCTAssertEqual(ids(freshEngine.savedPool(for: restoredPlaylist)), ids(generated))
        let reopened = try await freshEngine.generateIfPoolEmpty(for: restoredPlaylist)
        XCTAssertEqual(ids(reopened), ids(generated))
        XCTAssertEqual(calls, 1)
    }

    func testRepeatedOpenAndNormalPlaybackStatsDoNotGenerateWithSavedPool() async throws {
        let (_, playlist, seed) = try fixture()
        var calls = 0
        let engine = service { _, _, _, _ in
            calls += 1
            return self.candidates(1)
        }
        _ = try await engine.generateIfPoolEmpty(for: playlist)
        let membership = PlaylistRecommendationMembershipSignature.value(for: playlist.tracksInPlaybackOrder)
        seed.playCount += 1
        seed.totalListenedDuration += 30
        seed.lastPlayedAt = .now
        XCTAssertEqual(PlaylistRecommendationMembershipSignature.value(for: playlist.tracksInPlaybackOrder), membership)
        for _ in 0..<4 { _ = try await engine.generateIfPoolEmpty(for: playlist) }
        XCTAssertEqual(calls, 1)
    }

    func testAddingAndRejectingRemoveOnlyOneAndPartialPoolsNeverTopUp() async throws {
        let (_, playlist, _) = try fixture()
        var batch = 0
        let rejection = PlaylistRejectionStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let engine = service(rejection: rejection) { _, _, _, _ in
            batch += 1
            return self.candidates(batch)
        }
        let first = try await engine.generateIfPoolEmpty(for: playlist)
        let originalIDs = ids(first)
        let afterAdd = try engine.removeSavedRecommendation(
            first.visibleRecommendations[0], from: playlist, reason: "addedToPlaylist"
        )
        XCTAssertEqual(ids(afterAdd), Array(originalIDs.dropFirst()))
        XCTAssertEqual(batch, 1)
        XCTAssertFalse(rejection.isRejected(first.visibleRecommendations[0].songIdentity, for: String(describing: playlist.persistentModelID)))
        _ = try await engine.generateIfPoolEmpty(for: playlist)
        XCTAssertEqual(batch, 1)

        let afterReject = try engine.removeSavedRecommendation(
            first.visibleRecommendations[1], from: playlist, reason: "rejected", reject: true
        )
        XCTAssertEqual(ids(afterReject), Array(originalIDs.dropFirst(2)))
        XCTAssertTrue(rejection.isRejected(first.visibleRecommendations[1].songIdentity, for: String(describing: playlist.persistentModelID)))
        for item in first.visibleRecommendations[2...3] {
            _ = try engine.removeSavedRecommendation(item, from: playlist, reason: "addedToPlaylist")
        }
        XCTAssertEqual(ids(engine.savedPool(for: playlist)), [originalIDs[4]])
        _ = try await engine.generateIfPoolEmpty(for: playlist)
        XCTAssertEqual(batch, 1)

        _ = try engine.removeSavedRecommendation(first.visibleRecommendations[4], from: playlist, reason: "addedToPlaylist")
        let second = try await engine.generateIfPoolEmpty(for: playlist)
        XCTAssertEqual(batch, 2)
        XCTAssertEqual(ids(second), (1...5).map { "v2-\($0)" })
    }

    func testSavedPoolValidationRemovesBlockedAndPlaylistMembersWithoutTopUp() async throws {
        let (_, playlist, _) = try fixture()
        let feedback = RecommendationFeedbackStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        var calls = 0
        let engine = service(feedback: feedback) { _, _, _, _ in
            calls += 1
            return self.candidates(1)
        }
        let first = try await engine.generateIfPoolEmpty(for: playlist)
        feedback.record(.dontRecommendArtist, identity: first.visibleRecommendations[0].songIdentity)
        let added = Track(
            title: first.visibleRecommendations[1].title,
            youtubeURL: URL(string: "https://www.youtube.com/watch?v=v1-2")!,
            youtubeVideoID: "v1-2",
            channelTitle: first.visibleRecommendations[1].artist,
            authoritativeRecommendationTitle: first.visibleRecommendations[1].title,
            authoritativeRecommendationArtist: first.visibleRecommendations[1].artist
        )
        playlist.tracks.append(added)
        let valid = engine.savedPool(for: playlist)
        XCTAssertEqual(ids(valid), ["v1-3", "v1-4", "v1-5"])
        XCTAssertEqual(ids(engine.savedPool(for: playlist)), ids(valid))
        _ = try await engine.generateIfPoolEmpty(for: playlist)
        XCTAssertEqual(calls, 1)
    }

    func testZeroValidSavedRecommendationsRegenerates() async throws {
        let (_, playlist, _) = try fixture()
        var batch = 0
        let engine = service { _, _, _, _ in
            batch += 1
            return self.candidates(batch)
        }
        let first = try await engine.generateIfPoolEmpty(for: playlist)
        for item in first.visibleRecommendations {
            _ = try engine.removeSavedRecommendation(item, from: playlist, reason: "rejected", reject: true)
        }
        XCTAssertTrue(engine.savedPool(for: playlist).visibleRecommendations.isEmpty)
        let regenerated = try await engine.generateIfPoolEmpty(for: playlist)
        XCTAssertEqual(batch, 2)
        XCTAssertEqual(ids(regenerated), (1...5).map { "v2-\($0)" })
    }

    func testUnusableSavedIdentityIsDiscardedBeforeGeneration() async throws {
        let (_, playlist, _) = try fixture()
        var calls = 0
        let engine = service { _, _, _, _ in
            calls += 1
            return self.candidates(3)
        }
        let empty = engine.savedPool(for: playlist)
        let invalid = ResolvedRecommendation(
            artist: "", title: "", match: 0.5,
            youtubeResult: YouTubeSearchResult(
                youtubeVideoID: "invalid", title: "Unknown", channelTitle: "Unknown", thumbnailURL: nil
            )
        )
        let result = PlaylistRecommendationResult(
            visibleRecommendations: [invalid], spareResolved: [], deferredCandidates: []
        )
        _ = try engine.saveExplicitExpansion(result, for: playlist, expectedCurrent: empty)
        XCTAssertTrue(engine.savedPool(for: playlist).visibleRecommendations.isEmpty)
        XCTAssertEqual(calls, 0)
        let replacement = try await engine.generateIfPoolEmpty(for: playlist)
        XCTAssertEqual(replacement.visibleRecommendations.count, 5)
        XCTAssertEqual(calls, 1)
    }

    func testRefreshReplacesWithoutFeedbackAndOldSongsRemainEligibleLater() async throws {
        let (_, playlist, _) = try fixture()
        let feedback = RecommendationFeedbackStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let rejection = PlaylistRejectionStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        var suppliedBatch = 1
        let engine = service(feedback: feedback, rejection: rejection) { _, _, _, _ in
            self.candidates(suppliedBatch)
        }
        let old = try await engine.generateIfPoolEmpty(for: playlist)
        suppliedBatch = 2
        let replacement = try await engine.refreshPool(for: playlist)
        XCTAssertEqual(ids(replacement), (1...5).map { "v2-\($0)" })
        XCTAssertEqual(ids(engine.savedPool(for: playlist)), ids(replacement))
        for item in old.visibleRecommendations {
            XCTAssertFalse(rejection.isRejected(item.songIdentity, for: String(describing: playlist.persistentModelID)))
            XCTAssertTrue(feedback.snapshot.allowsAutomaticRecommendation(item.songIdentity))
        }
        suppliedBatch = 1
        let oldAgain = try await engine.refreshPool(for: playlist)
        XCTAssertEqual(ids(oldAgain), ids(old))
    }

    func testRefreshFailureKeepsOldPool() async throws {
        let (_, playlist, _) = try fixture()
        var returnCandidates = true
        let engine = service { _, _, _, _ in
            returnCandidates ? self.candidates(1) : []
        }
        let old = try await engine.generateIfPoolEmpty(for: playlist)
        returnCandidates = false
        do {
            _ = try await engine.refreshPool(for: playlist)
            XCTFail("An empty refresh must keep the old pool")
        } catch PlaylistRecommendationService.PoolError.noNewRecommendations {}
        XCTAssertEqual(ids(engine.savedPool(for: playlist)), ids(old))
    }

    func testConcurrentEmptyPoolRequestsShareOneGeneration() async throws {
        let (_, playlist, _) = try fixture()
        var calls = 0
        let engine = service { _, _, _, _ in
            calls += 1
            try await Task.sleep(for: .milliseconds(30))
            return self.candidates(1)
        }
        async let first = engine.generateIfPoolEmpty(for: playlist)
        async let second = engine.generateIfPoolEmpty(for: playlist)
        let results = try await [first, second]
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(ids(results[0]), ids(results[1]))
    }

    func testPlaylistMutationDuringGenerationCannotRestoreStaleRecommendation() async throws {
        let (_, playlist, _) = try fixture()
        var pending: CheckedContinuation<[LastFMSimilarTrack], Error>?
        var calls = 0
        let engine = service { _, _, _, _ in
            calls += 1
            if calls == 1 {
                return try await withCheckedThrowingContinuation { pending = $0 }
            }
            return self.candidates(2)
        }
        let request = Task { try await engine.generateIfPoolEmpty(for: playlist) }
        while pending == nil { await Task.yield() }
        let added = Track(
            title: "Song 1 1",
            youtubeURL: URL(string: "https://www.youtube.com/watch?v=v1-1")!,
            youtubeVideoID: "v1-1",
            channelTitle: "Artist 1 1",
            authoritativeRecommendationTitle: "Song 1 1",
            authoritativeRecommendationArtist: "Artist 1 1"
        )
        playlist.tracks.append(added)
        pending?.resume(returning: candidates(1))
        let result = try await request.value
        XCTAssertEqual(ids(result), (1...5).map { "v2-\($0)" })
        XCTAssertFalse(ids(engine.savedPool(for: playlist)).contains("v1-1"))
        XCTAssertGreaterThan(calls, 1)
    }

    func testRefreshCannotBeOverwrittenByOlderAutomaticGeneration() async throws {
        let (_, playlist, _) = try fixture()
        var oldContinuation: CheckedContinuation<[LastFMSimilarTrack], Error>?
        var calls = 0
        let engine = service { _, _, _, _ in
            calls += 1
            if calls == 1 {
                return try await withCheckedThrowingContinuation { oldContinuation = $0 }
            }
            return self.candidates(2)
        }
        let older = Task { try await engine.generateIfPoolEmpty(for: playlist) }
        while oldContinuation == nil { await Task.yield() }
        let refreshed = try await engine.refreshPool(for: playlist)
        XCTAssertEqual(ids(refreshed), (1...5).map { "v2-\($0)" })
        oldContinuation?.resume(returning: candidates(1))
        do {
            _ = try await older.value
            XCTFail("Older automatic request must be discarded")
        } catch is CancellationError {}
        XCTAssertEqual(ids(engine.savedPool(for: playlist)), ids(refreshed))
        XCTAssertEqual(calls, 2)
    }
}
