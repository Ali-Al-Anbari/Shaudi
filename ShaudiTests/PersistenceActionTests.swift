import SwiftData
import XCTest
@testable import Shaudi

@MainActor
final class PersistenceActionTests: XCTestCase {
    private enum SimulatedFailure: Error { case save }

    // Callers keep the container alive through their final ModelContext operation.
    private func context() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Track.self,
            Playlist.self
        ])

        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )

        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        return (container, container.mainContext)
    }

    private func recommendation(id: String = "phase3video") -> ResolvedRecommendation {
        ResolvedRecommendation(
            artist: "Canonical Artist", title: "Canonical Song", match: 0.9,
            youtubeResult: YouTubeSearchResult(
                youtubeVideoID: id, title: "Misleading Upload",
                channelTitle: "Uploader", thumbnailURL: URL(string: "https://example.com/art.jpg"),
                duration: 321
            )
        )
    }

    private func tracks(_ context: ModelContext) throws -> [Track] {
        try context.fetch(FetchDescriptor<Track>())
    }

    func testPickerOpenCancelAndRecommendationQueueActionsRemainTransient() throws {
        let (container, modelContext) = try context()
        defer { withExtendedLifetime(container) {} }
        let item = recommendation()
        let pickerTrack = TrackPersistence.transientTrack(for: item)
        XCTAssertNil(pickerTrack.modelContext)
        XCTAssertTrue(try tracks(modelContext).isEmpty)

        // Dismissing the picker makes no persistence call.
        XCTAssertTrue(try tracks(modelContext).isEmpty)

        let manager = PlaybackManager()
        manager.seedQueueForTesting(tracks: [TrackPersistence.transientTrack(for: recommendation(id: "now"))], currentIndex: 0)
        let next = TrackPersistence.transientTrack(for: item)
        manager.playNext(next)
        XCTAssertNil(next.modelContext)
        XCTAssertEqual(manager.manualQueueCount, 1)
        XCTAssertTrue(try tracks(modelContext).isEmpty)

        let queued = TrackPersistence.transientTrack(for: recommendation(id: "queued"))
        manager.addToQueue(queued)
        XCTAssertNil(queued.modelContext)
        XCTAssertEqual(manager.manualQueueCount, 2)
        XCTAssertEqual(manager.upcomingQueueTracks.map(\.youtubeVideoID), ["phase3video", "queued"])
        XCTAssertTrue(try tracks(modelContext).isEmpty)
    }

    func testConfirmedPickerAndQuickAddPromoteAndReuseWithMetadata() throws {
        let (container, modelContext) = try context()
        let first = Playlist(name: "First")
        let second = Playlist(name: "Second")
        modelContext.insert(first)
        modelContext.insert(second)
        let item = recommendation()
        let transient = TrackPersistence.transientTrack(for: item)
        transient.playbackStartTime = 5
        transient.playbackEndTime = 200

        let saved = try TrackPersistence.promoteOrReuse(
            transientTrack: transient, playableTrack: nil, in: modelContext,
            targetPlaylist: first, existingLibraryTracks: []
        )
        XCTAssertEqual(first.tracks.count, 1)
        XCTAssertEqual(saved.youtubeVideoID, "phase3video")
        XCTAssertEqual(saved.title, "Canonical Song")
        XCTAssertEqual(saved.channelTitle, "Canonical Artist")
        XCTAssertEqual(saved.thumbnailURL, item.youtubeResult.thumbnailURL)
        XCTAssertEqual(saved.duration, 321)
        XCTAssertEqual(saved.playbackStartTime, 5)
        XCTAssertEqual(saved.playbackEndTime, 200)
        XCTAssertEqual(saved.persistedAuthoritativeRecommendationIdentity, item.songIdentity)

        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in [] }, safeResolve: { _ in nil }
        )
        let reused = try XCTUnwrap(service.addRecommendation(
            item, to: second, in: modelContext, existingLibraryTracks: []
        ))
        XCTAssertTrue(reused === saved)
        XCTAssertEqual(try tracks(modelContext).count, 1)
        XCTAssertEqual(second.tracks.count, 1)
        XCTAssertNil(service.addRecommendation(
            item, to: second, in: modelContext, existingLibraryTracks: []
        ))
        XCTAssertEqual(second.tracks.count, 1)
        let reloaded = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<Track>()).first
        )
        XCTAssertEqual(reloaded.persistedAuthoritativeRecommendationIdentity, item.songIdentity)
    }

    func testOpeningPickerDoesNotEnrichExistingLibraryTrack() throws {
        let (container, modelContext) = try context()
        defer { withExtendedLifetime(container) {} }
        let existing = Track(
            title: "User Title", youtubeURL: URL(string: "https://www.youtube.com/watch?v=phase3video")!,
            youtubeVideoID: "phase3video", channelTitle: "Original Uploader"
        )
        modelContext.insert(existing)
        try modelContext.save()

        let pickerTrack = TrackPersistence.transientTrack(for: recommendation())
        XCTAssertNil(pickerTrack.modelContext)
        XCTAssertNil(existing.persistedAuthoritativeRecommendationIdentity)
        XCTAssertEqual(try tracks(modelContext).count, 1)
    }

    func testFailedCreationReportsFailureAndLeavesRecommendationAndLibraryIntact() throws {
        let (container, modelContext) = try context()
        defer { withExtendedLifetime(container) {} }
        let playlist = Playlist(name: "Target")
        modelContext.insert(playlist)
        let item = recommendation()
        let service = PlaylistRecommendationService(
            similarTracks: { _, _, _, _ in [] }, safeResolve: { _ in nil }
        )
        let visible = PlaylistRecommendationResult(
            visibleRecommendations: [item], spareResolved: [], deferredCandidates: []
        )
        TrackPersistence.saveOverride = { _ in throw SimulatedFailure.save }
        defer { TrackPersistence.saveOverride = nil }

        XCTAssertNil(service.addRecommendation(
            item, to: playlist, in: modelContext, existingLibraryTracks: []
        ))
        XCTAssertEqual(visible.visibleRecommendations.count, 1)
        XCTAssertTrue(playlist.tracks.isEmpty)
        XCTAssertTrue(try tracks(modelContext).isEmpty)
        let pickerTrack = TrackPersistence.transientTrack(for: item)
        XCTAssertThrowsError(try TrackPersistence.promoteOrReuse(
            track: pickerTrack, in: modelContext, targetPlaylist: playlist
        ))
        XCTAssertTrue(playlist.tracks.isEmpty)
        XCTAssertTrue(try tracks(modelContext).isEmpty)
        XCTAssertNil(pickerTrack.modelContext)
        TrackPersistence.saveOverride = nil
        XCTAssertNoThrow(try TrackPersistence.promoteOrReuse(
            track: pickerTrack, in: modelContext, targetPlaylist: playlist
        ))
        XCTAssertEqual(playlist.tracks.count, 1)
        XCTAssertEqual(try tracks(modelContext).count, 1)
    }

    func testFailedReuseRestoresExistingTrackAndMembership() throws {
        let (container, modelContext) = try context()
        defer { withExtendedLifetime(container) {} }
        let existing = Track(
            title: "User Title", youtubeURL: URL(string: "https://www.youtube.com/watch?v=phase3video")!,
            youtubeVideoID: "phase3video", channelTitle: "Original Uploader"
        )
        modelContext.insert(existing)
        let playlist = Playlist(name: "Target")
        modelContext.insert(playlist)
        try modelContext.save()
        TrackPersistence.saveOverride = { _ in throw SimulatedFailure.save }
        defer { TrackPersistence.saveOverride = nil }

        XCTAssertThrowsError(try TrackPersistence.promoteOrReuse(
            recommendation: recommendation(), in: modelContext,
            targetPlaylist: playlist, existingLibraryTracks: [existing]
        ))
        XCTAssertTrue(playlist.tracks.isEmpty)
        XCTAssertEqual(existing.title, "User Title")
        XCTAssertNil(existing.persistedAuthoritativeRecommendationIdentity)
        XCTAssertEqual(try tracks(modelContext).count, 1)
        XCTAssertTrue(try tracks(modelContext).first === existing)
    }

    func testSearchStyleTransientTrackOnlyPersistsAfterConfirmation() throws {
        let (container, modelContext) = try context()
        defer { withExtendedLifetime(container) {} }
        let playable = PlayableTrack(
            youtubeVideoID: "searchvideo", title: "Search Song",
            channelTitle: "Search Artist", thumbnailURL: nil, duration: 180
        )
        let transient = PlaybackManager().makeTransientTrack(from: playable)
        XCTAssertNil(transient.modelContext)
        XCTAssertTrue(try tracks(modelContext).isEmpty)
        let saved = try TrackPersistence.promoteOrReuse(
            transientTrack: transient, playableTrack: nil, in: modelContext
        )
        XCTAssertEqual(saved.youtubeVideoID, "searchvideo")
        XCTAssertEqual(try tracks(modelContext).count, 1)
    }
}
