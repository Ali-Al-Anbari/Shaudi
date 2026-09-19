import XCTest
import AVFoundation
@testable import Shaudi

/// Targeted deterministic tests for end-of-song natural playback completion,
/// near-EOF error/stall fallbacks, completion gate idempotency, and duration hydration.
@MainActor
final class PlaybackCompletionTests: XCTestCase {

    private func makeTrack(
        id: String = UUID().uuidString,
        title: String = "Test Title",
        duration: TimeInterval? = 215.0
    ) -> Track {
        Track(
            title: title,
            youtubeURL: URL(string: "https://www.youtube.com/watch?v=\(id)")!,
            youtubeVideoID: id,
            duration: duration
        )
    }

    private func makePlayerItem() -> (AVPlayer, AVPlayerItem) {
        let url = URL(string: "https://example.com/audio.m4a")!
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        return (player, item)
    }

    private func makeManager(
        tracks: [Track],
        currentIndex: Int = 0,
        manualQueueCount: Int = 0
    ) -> PlaybackManager {
        let manager = PlaybackManager()
        manager.seedQueueForTesting(
            tracks: tracks,
            currentIndex: currentIndex,
            manualQueueCount: manualQueueCount
        )
        return manager
    }

    // MARK: - 1. Normal didPlayToEnd advances exactly once

    func testNormalDidPlayToEndAdvancesExactlyOnce() {
        let t1 = makeTrack(id: "t1")
        let t2 = makeTrack(id: "t2")
        let manager = makeManager(tracks: [t1, t2], currentIndex: 0)
        let (player, item) = makePlayerItem()
        let requestID = UUID()

        manager.seedInterruptionStateForTesting(state: .playing, requestID: requestID, player: player)

        manager.triggerPlaybackCompletionForTesting(for: item, requestID: requestID, source: .normalEnd)

        XCTAssertEqual(manager.currentIndex, 1, "Playback should advance to index 1 on normal completion")
        XCTAssertEqual(manager.completedPlaybackRequestIDForTesting, requestID, "Completion gate should record requestID")
    }

    // MARK: - 2. Boundary callback + didPlayToEnd both firing advances exactly once

    func testBoundaryAndDidPlayToEndBothFiringAdvancesExactlyOnce() {
        let t1 = makeTrack(id: "t1")
        let t2 = makeTrack(id: "t2")
        let t3 = makeTrack(id: "t3")
        let manager = makeManager(tracks: [t1, t2, t3], currentIndex: 0)
        let (player, item) = makePlayerItem()
        let requestID = UUID()

        manager.seedInterruptionStateForTesting(state: .playing, requestID: requestID, player: player)

        // First event: boundary observer fires
        manager.triggerPlaybackCompletionForTesting(for: item, requestID: requestID, source: .boundary)
        XCTAssertEqual(manager.currentIndex, 1, "First event should advance to index 1")

        // Second event: didPlayToEnd fires for the same item and requestID
        manager.triggerPlaybackCompletionForTesting(for: item, requestID: requestID, source: .normalEnd)
        XCTAssertEqual(manager.currentIndex, 1, "Duplicate event must be dropped by completion gate, not double-advance to index 2")
    }

    // MARK: - 3. Failed-to-end within near-EOF tolerance counts as completion

    func testFailedToEndNearEOFCountsAsCompletion() {
        let t1 = makeTrack(id: "t1", duration: 215.0)
        let t2 = makeTrack(id: "t2")
        let manager = makeManager(tracks: [t1, t2], currentIndex: 0)
        let (player, item) = makePlayerItem()
        let requestID = UUID()

        manager.seedInterruptionStateForTesting(state: .playing, requestID: requestID, player: player)

        // Stream failed at 214.5s (within 2.0s of 215.0s)
        manager.triggerFailedToEndForTesting(
            for: item,
            requestID: requestID,
            currentPosition: 214.5,
            effectiveEnd: 215.0
        )

        XCTAssertEqual(manager.currentIndex, 1, "Near-EOF failure should count as natural completion and advance")
        XCTAssertEqual(manager.completedPlaybackRequestIDForTesting, requestID, "Completion gate should be locked")
    }

    // MARK: - 4. Failed-to-end in middle of song does NOT count as natural completion

    func testFailedToEndInMiddleOfSongDoesNotAdvance() {
        let t1 = makeTrack(id: "t1", duration: 215.0)
        let t2 = makeTrack(id: "t2")
        let manager = makeManager(tracks: [t1, t2], currentIndex: 0)
        let (player, item) = makePlayerItem()
        let requestID = UUID()

        manager.seedInterruptionStateForTesting(state: .playing, requestID: requestID, player: player)

        // Stream failed at 90.0s (far away from 215.0s)
        manager.triggerFailedToEndForTesting(
            for: item,
            requestID: requestID,
            currentPosition: 90.0,
            effectiveEnd: 215.0
        )

        XCTAssertEqual(manager.currentIndex, 0, "Mid-song failure must not advance as natural completion")
        XCTAssertNil(manager.completedPlaybackRequestIDForTesting, "Completion gate must remain unlocked")
    }

    // MARK: - 5. Temporary stall away from EOF does NOT advance

    func testTemporaryStallAwayFromEOFDoesNotAdvance() {
        let t1 = makeTrack(id: "t1", duration: 215.0)
        let t2 = makeTrack(id: "t2")
        let manager = makeManager(tracks: [t1, t2], currentIndex: 0)
        let (player, item) = makePlayerItem()
        let requestID = UUID()

        manager.seedInterruptionStateForTesting(state: .playing, requestID: requestID, player: player)

        // Stalled at 100.0s
        manager.triggerStalledForTesting(
            for: item,
            requestID: requestID,
            currentPosition: 100.0,
            effectiveEnd: 215.0,
            simulatedRecovery: false
        )

        XCTAssertEqual(manager.currentIndex, 0, "Mid-song stall must not trigger completion fallback")
        XCTAssertNil(manager.completedPlaybackRequestIDForTesting)
    }

    // MARK: - 6. Temporary stall near EOF that recovers does NOT falsely advance

    func testTemporaryStallNearEOFThatRecoversDoesNotAdvance() {
        let t1 = makeTrack(id: "t1", duration: 215.0)
        let t2 = makeTrack(id: "t2")
        let manager = makeManager(tracks: [t1, t2], currentIndex: 0)
        let (player, item) = makePlayerItem()
        let requestID = UUID()

        manager.seedInterruptionStateForTesting(state: .playing, requestID: requestID, player: player)

        // Stalled near EOF (214.2s) but recovers during grace period
        manager.triggerStalledForTesting(
            for: item,
            requestID: requestID,
            currentPosition: 214.2,
            effectiveEnd: 215.0,
            simulatedRecovery: true
        )

        XCTAssertEqual(manager.currentIndex, 0, "Stall that recovers before grace period expires must not advance")
        XCTAssertNil(manager.completedPlaybackRequestIDForTesting)
    }

    // MARK: - 7. Unrecovered near-EOF stall advances exactly once

    func testUnrecoveredNearEOFStallAdvancesExactlyOnce() {
        let t1 = makeTrack(id: "t1", duration: 215.0)
        let t2 = makeTrack(id: "t2")
        let manager = makeManager(tracks: [t1, t2], currentIndex: 0)
        let (player, item) = makePlayerItem()
        let requestID = UUID()

        manager.seedInterruptionStateForTesting(state: .playing, requestID: requestID, player: player)

        // Stalled near EOF (214.0s) and fails to recover
        manager.triggerStalledForTesting(
            for: item,
            requestID: requestID,
            currentPosition: 214.0,
            effectiveEnd: 215.0,
            simulatedRecovery: false
        )

        XCTAssertEqual(manager.currentIndex, 1, "Unrecovered near-EOF stall should trigger completion fallback")
        XCTAssertEqual(manager.completedPlaybackRequestIDForTesting, requestID)
    }

    // MARK: - 8. New playback request resets completion gate

    func testNewPlaybackRequestResetsCompletionGate() {
        let t1 = makeTrack(id: "t1")
        let t2 = makeTrack(id: "t2")
        let manager = makeManager(tracks: [t1, t2], currentIndex: 0)
        let (player1, item1) = makePlayerItem()
        let request1 = UUID()

        manager.seedInterruptionStateForTesting(state: .playing, requestID: request1, player: player1)
        manager.triggerPlaybackCompletionForTesting(for: item1, requestID: request1, source: .normalEnd)

        XCTAssertEqual(manager.completedPlaybackRequestIDForTesting, request1)
        XCTAssertEqual(manager.currentIndex, 1)

        // Next track begins with a fresh request ID
        let (player2, item2) = makePlayerItem()
        let request2 = UUID()
        manager.seedInterruptionStateForTesting(state: .playing, requestID: request2, player: player2)

        // Completion gate should allow request 2 to complete
        manager.triggerPlaybackCompletionForTesting(for: item2, requestID: request2, source: .normalEnd)
        XCTAssertEqual(manager.completedPlaybackRequestIDForTesting, request2, "New request should complete normally")
    }

    // MARK: - 9. Stale completion event from old item/request cannot advance current playback

    func testStaleCompletionFromOldRequestCannotAdvanceCurrentPlayback() {
        let t1 = makeTrack(id: "t1")
        let t2 = makeTrack(id: "t2")
        let manager = makeManager(tracks: [t1, t2], currentIndex: 1)
        let (_, oldItem) = makePlayerItem()
        let (currentPlayer, _) = makePlayerItem()
        let oldRequestID = UUID()
        let currentRequestID = UUID()

        manager.seedInterruptionStateForTesting(state: .playing, requestID: currentRequestID, player: currentPlayer)

        // Stale event fired for old item and old requestID
        manager.triggerPlaybackCompletionForTesting(for: oldItem, requestID: oldRequestID, source: .normalEnd)

        XCTAssertEqual(manager.currentIndex, 1, "Stale completion event must be dropped")
        XCTAssertNil(manager.completedPlaybackRequestIDForTesting, "Current request must not be marked completed by old event")
    }

    // MARK: - 10. Nil Track.duration gets hydrated from authoritative metadata when available

    func testNilTrackDurationGetsHydratedFromAuthoritativeMetadata() async {
        let track = makeTrack(id: "video123", duration: nil)
        let manager = PlaybackManager()
        let requestID = UUID()

        manager.testMetadataProvider = { videoID in
            XCTAssertEqual(videoID, "video123")
            return YouTubeMetadata(
                title: "Hydrated Title",
                channelTitle: "Artist",
                thumbnailURL: nil,
                duration: 185.0
            )
        }

        XCTAssertNil(track.duration, "Initially duration is nil")

        await manager.hydrateTrackDurationForTesting(for: track, requestID: requestID)

        XCTAssertEqual(track.duration, 185.0, "Track.duration must be updated from authoritative metadata")
    }

    // MARK: - 11. Obviously implausible AVPlayerItem duration is NOT persisted as authoritative Track.duration

    func testObviouslyImplausibleAVPlayerItemDurationIsNotPersisted() {
        let manager = PlaybackManager()
        let track = makeTrack(id: "video456", duration: nil)

        // Double duration / wild duration tests
        XCTAssertFalse(manager.isPlausibleItemDuration(nil), "nil is not plausible")
        XCTAssertFalse(manager.isPlausibleItemDuration(.infinity), "infinity is not plausible")
        XCTAssertFalse(manager.isPlausibleItemDuration(-5), "negative is not plausible")
        XCTAssertFalse(manager.isPlausibleItemDuration(100_000), "durations > 24h are not plausible for songs")

        let seekableRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 200, preferredTimescale: 600)
        )
        // Item duration roughly double the seekable range
        XCTAssertFalse(
            manager.isPlausibleItemDuration(450, seekableRanges: [seekableRange]),
            "Stream duration > 1.8x seekable end should be rejected as implausible"
        )

        // Ensure Track.duration was never set
        XCTAssertNil(track.duration, "Track.duration must remain nil when item duration is implausible")
    }

    // MARK: - 12. Hydrated Track.duration restores valid effective playback duration

    func testHydratedTrackDurationRestoresValidEffectivePlaybackDuration() async {
        let track = makeTrack(id: "video789", duration: nil)
        let manager = makeManager(tracks: [track], currentIndex: 0)
        let requestID = UUID()

        XCTAssertNil(manager.currentEffectivePlaybackDuration, "Effective duration should be nil before hydration")

        manager.testMetadataProvider = { _ in
            YouTubeMetadata(
                title: "Song",
                channelTitle: "Artist",
                thumbnailURL: nil,
                duration: 240.0
            )
        }

        await manager.hydrateTrackDurationForTesting(for: track, requestID: requestID)

        XCTAssertEqual(manager.currentEffectivePlaybackDuration, 240.0, "Hydrated duration restores currentEffectivePlaybackDuration")
    }

    // MARK: - 13. Repeat-one still repeats correctly

    func testRepeatOneStillRepeatsCorrectly() {
        let t1 = makeTrack(id: "t1")
        let t2 = makeTrack(id: "t2")
        let manager = makeManager(tracks: [t1, t2], currentIndex: 0)
        let (player, item) = makePlayerItem()
        let requestID = UUID()

        manager.setRepeatModeForTesting(.one)
        manager.seedInterruptionStateForTesting(state: .playing, requestID: requestID, player: player)

        manager.triggerPlaybackCompletionForTesting(for: item, requestID: requestID, source: .normalEnd)

        XCTAssertEqual(manager.currentIndex, 0, "Repeat-one must not advance to next track (remains at index 0)")
        XCTAssertEqual(manager.completedPlaybackRequestIDForTesting, requestID)
    }

    // MARK: - 14. Manual queue and normal auto-advance remain intact

    func testManualQueueAndNormalAutoAdvanceRemainIntact() {
        let t0 = makeTrack(id: "t0")
        let t1 = makeTrack(id: "t1")
        let manual1 = makeTrack(id: "manual1")

        // Seed queue with [t0, manual1, t1] where manualQueueCount = 1
        let manager = makeManager(tracks: [t0, manual1, t1], currentIndex: 0, manualQueueCount: 1)
        let (player, item) = makePlayerItem()
        let requestID = UUID()

        manager.seedInterruptionStateForTesting(state: .playing, requestID: requestID, player: player)

        manager.triggerPlaybackCompletionForTesting(for: item, requestID: requestID, source: .normalEnd)

        XCTAssertEqual(manager.currentIndex, 1, "Auto-advance should advance into manual item at index 1")
        XCTAssertEqual(manager.manualQueueCount, 0, "Advancing into manual item should consume 1 manual slot")
    }
}
