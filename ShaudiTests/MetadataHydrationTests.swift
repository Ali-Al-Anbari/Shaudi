import AVFoundation
import MediaPlayer
import SwiftData
import XCTest
@testable import Shaudi

@MainActor
final class MetadataHydrationTests: XCTestCase {
    private enum TestFailure: Error { case unavailable }

    private func track(_ id: String, duration: TimeInterval? = nil) -> Track {
        Track(
            title: "Song \(id)",
            youtubeURL: URL(string: "https://www.youtube.com/watch?v=\(id)")!,
            youtubeVideoID: id, duration: duration
        )
    }

    private func metadata(
        duration: TimeInterval?,
        artwork: URL? = nil
    ) -> YouTubeMetadata {
        YouTubeMetadata(
            title: "Authoritative Title", channelTitle: "Authoritative Artist",
            thumbnailURL: artwork, duration: duration
        )
    }

    private func activate(
        _ manager: PlaybackManager,
        track: Track,
        requestID: UUID,
        player: AVPlayer? = nil
    ) {
        manager.seedQueueForTesting(tracks: [track], currentIndex: 0)
        manager.seedInterruptionStateForTesting(
            state: .playing, requestID: requestID, player: player
        )
    }

    func testConcurrentGeneralAndRecommendationCallersShareOneFetch() async {
        let recommendation = track("shared")
        let general = track("shared")
        let manager = PlaybackManager()
        let requestID = UUID()
        manager.seedRecommendationQueueForTesting(
            tracks: [recommendation], currentIndex: 0,
            identitiesByVideoID: ["shared": SongIdentity(artist: "Artist", title: "Song")]
        )
        manager.seedInterruptionStateForTesting(state: .playing, requestID: requestID)
        var calls = 0
        var pending: CheckedContinuation<YouTubeMetadata, Error>?
        manager.testMetadataProvider = { _ in
            calls += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        }

        manager.startMetadataHydrationForTesting(for: recommendation, requestID: requestID)
        while pending == nil { await Task.yield() }
        manager.startMetadataHydrationForTesting(for: general, requestID: requestID)
        manager.startMetadataHydrationForTesting(for: recommendation, requestID: requestID)
        XCTAssertEqual(calls, 1)
        pending?.resume(returning: metadata(duration: 180))
        await manager.waitForMetadataHydrationForTesting(videoID: "shared")
        XCTAssertEqual(recommendation.duration, 180)
        XCTAssertEqual(general.duration, 180)
        XCTAssertEqual(manager.currentPlayableTrack?.duration, 180)
    }

    func testValidMetadataUpdatesTrackPlaybackRangeNowPlayingAndArtwork() async {
        let song = track("active")
        let manager = PlaybackManager()
        let requestID = UUID()
        let item = AVPlayerItem(url: URL(string: "https://example.com/audio.m4a")!)
        let player = AVPlayer(playerItem: item)
        activate(manager, track: song, requestID: requestID, player: player)
        let artwork = URL(string: "https://example.com/cover.jpg")!
        manager.testMetadataProvider = { _ in
            self.metadata(duration: 205, artwork: artwork)
        }

        await manager.hydrateTrackDurationForTesting(for: song, requestID: requestID)
        XCTAssertEqual(song.duration, 205)
        XCTAssertEqual(song.thumbnailURL, artwork)
        XCTAssertEqual(manager.currentPlayableTrack?.duration, 205)
        XCTAssertEqual(manager.currentPlayableTrack?.thumbnailURL, artwork)
        XCTAssertEqual(item.forwardPlaybackEndTime.seconds, 205, accuracy: 0.01)
        XCTAssertEqual(
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double,
            205
        )
    }

    func testStaleResultPersistsOriginalTrackWithoutChangingCurrentPlayback() async throws {
        let first = track("first")
        let second = track("second")
        let container = try ModelContainer(
            for: Track.self, Playlist.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        container.mainContext.insert(first)
        try container.mainContext.save()
        let manager = PlaybackManager()
        let firstRequest = UUID()
        activate(manager, track: first, requestID: firstRequest)
        var pending: CheckedContinuation<YouTubeMetadata, Error>?
        manager.testMetadataProvider = { _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }

        manager.startMetadataHydrationForTesting(for: first, requestID: firstRequest)
        while pending == nil { await Task.yield() }
        activate(manager, track: second, requestID: UUID())
        pending?.resume(returning: metadata(duration: 190))
        await manager.waitForMetadataHydrationForTesting(videoID: "first")

        XCTAssertEqual(first.duration, 190)
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<Track>()).first?.duration,
            190
        )
        XCTAssertNil(second.duration)
        XCTAssertEqual(manager.currentPlayableTrack?.youtubeVideoID, "second")
        XCTAssertNil(manager.currentPlayableTrack?.duration)
    }

    func testFailureAndInvalidDurationCanRetry() async {
        let song = track("retry")
        let manager = PlaybackManager()
        let requestID = UUID()
        activate(manager, track: song, requestID: requestID)
        var calls = 0
        manager.testMetadataProvider = { _ in
            calls += 1
            if calls == 1 { throw TestFailure.unavailable }
            if calls == 2 { return self.metadata(duration: .nan) }
            return self.metadata(duration: 210)
        }

        await manager.hydrateTrackDurationForTesting(for: song, requestID: requestID)
        XCTAssertNil(song.duration)
        await manager.hydrateTrackDurationForTesting(for: song, requestID: requestID)
        XCTAssertNil(song.duration)
        await manager.hydrateTrackDurationForTesting(for: song, requestID: requestID)
        XCTAssertEqual(song.duration, 210)
        XCTAssertEqual(calls, 3)
    }

    func testTemporaryPlayerDurationNeverBecomesTrackDuration() {
        let song = track("stream")
        let manager = PlaybackManager()
        activate(manager, track: song, requestID: UUID())
        manager.temporaryValidatedUIDurationForTesting = 200

        XCTAssertEqual(manager.currentEffectivePlaybackDuration, 200)
        XCTAssertNil(song.duration)
    }

    func testABAJoinsInflightRequestAndAppliesToLatestA() async {
        let first = track("a")
        let second = track("b")
        let manager = PlaybackManager()
        let firstRequest = UUID()
        activate(manager, track: first, requestID: firstRequest)
        var calls = 0
        var pending: CheckedContinuation<YouTubeMetadata, Error>?
        manager.testMetadataProvider = { _ in
            calls += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        }

        manager.startMetadataHydrationForTesting(for: first, requestID: firstRequest)
        while pending == nil { await Task.yield() }
        activate(manager, track: second, requestID: UUID())
        let latestA = track("a")
        let latestRequest = UUID()
        activate(manager, track: latestA, requestID: latestRequest)
        manager.startMetadataHydrationForTesting(for: latestA, requestID: latestRequest)
        XCTAssertEqual(calls, 1)
        pending?.resume(returning: metadata(duration: 175))
        await manager.waitForMetadataHydrationForTesting(videoID: "a")

        XCTAssertEqual(first.duration, 175)
        XCTAssertEqual(latestA.duration, 175)
        XCTAssertNil(second.duration)
        XCTAssertEqual(manager.currentPlayableTrack?.youtubeVideoID, "a")
        XCTAssertEqual(manager.currentPlayableTrack?.duration, 175)

        let replayedA = track("a")
        let replayRequest = UUID()
        activate(manager, track: replayedA, requestID: replayRequest)
        manager.startMetadataHydrationForTesting(for: replayedA, requestID: replayRequest)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(replayedA.duration, 175)
        XCTAssertEqual(manager.currentPlayableTrack?.duration, 175)
    }
}
