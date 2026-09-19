import XCTest
import AVFoundation
@testable import Shaudi

/// Targeted unit tests for audio interruption handling (Bug 2).
@MainActor
final class AudioInterruptionTests: XCTestCase {

    private func makeTrack(id: String = UUID().uuidString) -> Track {
        Track(
            title: "Track \(id)",
            youtubeURL: URL(string: "https://www.youtube.com/watch?v=\(id)")!,
            youtubeVideoID: id
        )
    }

    private func makeManager(
        tracks: [Track],
        currentIndex: Int = 0
    ) -> PlaybackManager {
        let manager = PlaybackManager()
        manager.seedQueueForTesting(
            tracks: tracks,
            currentIndex: currentIndex,
            manualQueueCount: 0
        )
        return manager
    }

    // MARK: - 1. Interruption begins while playing remembers resume intent

    func testInterruptionBeginsWhilePlayingRemembersResumeIntent() {
        let track = makeTrack(id: "t1")
        let manager = makeManager(tracks: [track])
        let requestID = UUID()
        manager.seedInterruptionStateForTesting(state: .playing, requestID: requestID)

        manager.handleAudioSessionInterruption(type: .began)

        XCTAssertTrue(manager.isAudioInterrupted, "Interruption should be marked as active")
        XCTAssertTrue(manager.wasPlayingBeforeInterruption, "Resume intent should be recorded when interrupted while playing")
        XCTAssertEqual(manager.activeInterruptionContext?.requestID, requestID, "Interruption context must capture current request ID")
    }

    // MARK: - 2. Interruption begins while already paused does not create resume intent

    func testInterruptionBeginsWhilePausedDoesNotCreateResumeIntent() {
        let track = makeTrack(id: "t1")
        let manager = makeManager(tracks: [track])
        let requestID = UUID()
        manager.seedInterruptionStateForTesting(state: .paused, requestID: requestID)

        manager.handleAudioSessionInterruption(type: .began)

        XCTAssertTrue(manager.isAudioInterrupted, "Interruption should be marked as active")
        XCTAssertFalse(manager.wasPlayingBeforeInterruption, "No resume intent should be recorded when already paused")
    }

    // MARK: - 3. Interruption end + shouldResume resumes playback intent

    func testInterruptionEndWithShouldResumeResumesPlaybackIntent() {
        let track = makeTrack(id: "t1")
        let manager = makeManager(tracks: [track])
        let requestID = UUID()
        let player = AVPlayer()
        manager.seedInterruptionStateForTesting(
            state: .paused,
            requestID: requestID,
            wasPlayingBeforeInterruption: true,
            player: player
        )

        manager.handleAudioSessionInterruption(type: .ended, options: [.shouldResume])

        XCTAssertFalse(manager.isAudioInterrupted, "Interruption should no longer be active")
        XCTAssertFalse(manager.wasPlayingBeforeInterruption, "Resume intent should be consumed")
        XCTAssertEqual(manager.state, .loading, "Manager should transition to loading on resume")
    }

    // MARK: - 4. Interruption end without shouldResume does not auto-resume

    func testInterruptionEndWithoutShouldResumeDoesNotAutoResume() {
        let track = makeTrack(id: "t1")
        let manager = makeManager(tracks: [track])
        let requestID = UUID()
        let player = AVPlayer()
        manager.seedInterruptionStateForTesting(
            state: .paused,
            requestID: requestID,
            wasPlayingBeforeInterruption: true,
            player: player
        )

        manager.handleAudioSessionInterruption(type: .ended, options: [])

        XCTAssertFalse(manager.isAudioInterrupted, "Interruption should no longer be active")
        XCTAssertFalse(manager.wasPlayingBeforeInterruption, "Resume intent should be cleared")
        XCTAssertEqual(manager.state, .paused, "Manager should remain paused when shouldResume is false")
    }

    // MARK: - 5. Manual pause during interruption cancels automatic resume

    func testManualPauseDuringInterruptionCancelsAutoResume() {
        let track = makeTrack(id: "t1")
        let manager = makeManager(tracks: [track])
        let requestID = UUID()
        let player = AVPlayer()
        manager.seedInterruptionStateForTesting(
            state: .playing,
            requestID: requestID,
            player: player
        )

        manager.handleAudioSessionInterruption(type: .began)
        XCTAssertTrue(manager.wasPlayingBeforeInterruption, "Precondition: resume intent recorded")

        // User explicitly pauses during the call
        manager.pause()

        XCTAssertFalse(manager.isAudioInterrupted, "Manual pause should clear interruption context")
        XCTAssertFalse(manager.wasPlayingBeforeInterruption, "Manual pause should clear resume intent")

        // Interruption ends with shouldResume
        manager.handleAudioSessionInterruption(type: .ended, options: [.shouldResume])

        XCTAssertEqual(manager.state, .paused, "Manager must remain paused because user manually paused")
    }

    // MARK: - 6. Stop/track change during interruption cancels automatic resume

    func testStopDuringInterruptionCancelsAutoResume() {
        let track = makeTrack(id: "t1")
        let manager = makeManager(tracks: [track])
        let requestID = UUID()
        let player = AVPlayer()
        manager.seedInterruptionStateForTesting(
            state: .playing,
            requestID: requestID,
            player: player
        )

        manager.handleAudioSessionInterruption(type: .began)
        XCTAssertTrue(manager.wasPlayingBeforeInterruption)

        // User stops playback during the call
        manager.stop()

        XCTAssertFalse(manager.isAudioInterrupted)
        XCTAssertFalse(manager.wasPlayingBeforeInterruption)

        // Interruption ends
        manager.handleAudioSessionInterruption(type: .ended, options: [.shouldResume])
        XCTAssertEqual(manager.state, .idle, "Manager must remain idle after stop")
    }

    func testTrackChangeDuringInterruptionDoesNotResumeOldTrack() {
        let t1 = makeTrack(id: "t1")
        let t2 = makeTrack(id: "t2")
        let manager = makeManager(tracks: [t1, t2], currentIndex: 0)
        let oldRequestID = UUID()
        let player = AVPlayer()
        manager.seedInterruptionStateForTesting(
            state: .playing,
            requestID: oldRequestID,
            player: player
        )

        manager.handleAudioSessionInterruption(type: .began)
        XCTAssertEqual(manager.activeInterruptionContext?.requestID, oldRequestID)

        // Track changes to new request ID
        let newRequestID = UUID()
        manager.seedInterruptionStateForTesting(
            state: .paused,
            requestID: newRequestID,
            player: player
        )

        // Interruption ends with shouldResume for the old context
        manager.handleAudioSessionInterruption(type: .ended, options: [.shouldResume])

        XCTAssertFalse(manager.isAudioInterrupted)
        XCTAssertEqual(manager.state, .paused, "Old interruption context must not resume new request ID")
    }

    // MARK: - 7. Interruption does not create early-skip behavior

    func testInterruptionDoesNotCreateEarlySkipBehavior() {
        let t1 = makeTrack(id: "t1")
        let t2 = makeTrack(id: "t2")
        let manager = makeManager(tracks: [t1, t2], currentIndex: 0)
        let requestID = UUID()
        manager.seedInterruptionStateForTesting(state: .playing, requestID: requestID)

        manager.handleAudioSessionInterruption(type: .began)

        XCTAssertEqual(manager.currentIndex, 0, "Current index must not change during interruption")
        XCTAssertEqual(manager.currentTrack?.youtubeVideoID, "t1", "Track must not change or skip")
        XCTAssertEqual(manager.state, .paused, "State should be paused, not failed or advancing")
    }

    // MARK: - 8. Playback state/UI does not remain falsely "playing" while interrupted

    func testPlaybackStateDoesNotRemainFalselyPlayingWhileInterrupted() {
        let track = makeTrack(id: "t1")
        let manager = makeManager(tracks: [track])
        let requestID = UUID()
        manager.seedInterruptionStateForTesting(state: .playing, requestID: requestID)

        // Interruption begins
        manager.handleAudioSessionInterruption(type: .began)

        XCTAssertNotEqual(manager.state, .playing, "State must not remain .playing while interrupted")
        XCTAssertEqual(manager.state, .paused, "State must be .paused so UI shows play button")
    }
}
