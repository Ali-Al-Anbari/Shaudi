import AVFoundation
import SwiftData
import XCTest
@testable import Shaudi

@MainActor
final class PlaybackRecoveryTests: XCTestCase {
    private func track(
        _ id: String = "video000001",
        duration: TimeInterval = 215,
        start: TimeInterval? = nil,
        end: TimeInterval? = nil
    ) -> Track {
        Track(
            title: "Artist - Song",
            youtubeURL: URL(string: "https://www.youtube.com/watch?v=\(id)")!,
            youtubeVideoID: id,
            duration: duration,
            playbackStartTime: start,
            playbackEndTime: end
        )
    }

    private func signedURL(expiresAt: Date? = Date.now.addingTimeInterval(6 * 3600)) -> URL {
        let expiry = expiresAt.map { "?expire=\(Int($0.timeIntervalSince1970))" } ?? ""
        return URL(string: "https://rr.example.test/videoplayback\(expiry)")!
    }

    private func playerItem() -> (AVPlayer, AVPlayerItem) {
        let item = AVPlayerItem(url: URL(string: "https://example.invalid/audio.m4a")!)
        return (AVPlayer(playerItem: item), item)
    }

    private func seededManager(
        tracks: [Track],
        state: PlaybackManager.PlaybackState = .loading,
        origin: PlaybackOrigin = .library,
        cachedURLOnly: Bool = true,
        hasStarted: Bool = false,
        startTime: TimeInterval = 0
    ) -> (PlaybackManager, AVPlayerItem, UUID) {
        let manager = PlaybackManager()
        manager.seedQueueForTesting(tracks: tracks, currentIndex: 0)
        let (player, item) = playerItem()
        let requestID = UUID()
        manager.seedInterruptionStateForTesting(state: state, requestID: requestID, player: player)
        manager.configureRecoveryForTesting(
            requestID: requestID,
            origin: origin,
            cachedURLOnly: cachedURLOnly,
            hasStarted: hasStarted,
            startTime: startTime
        )
        manager.seedSignedStreamForTesting(videoID: tracks[0].youtubeVideoID, url: signedURL())
        return (manager, item, requestID)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected asynchronous recovery transition did not occur")
    }

    func testNonExpiredSignedURLIsReused() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = now.addingTimeInterval(6 * 3600)
        XCTAssertEqual(SignedStreamURLPolicy.expirationDate(in: signedURL(expiresAt: expiry))?.timeIntervalSince1970, TimeInterval(Int(expiry.timeIntervalSince1970)))
        XCTAssertNil(SignedStreamURLPolicy.rejection(resolvedAt: now, expiresAt: expiry, now: now.addingTimeInterval(60)))
    }

    func testExpiredAndNearExpiryURLsAreRejected() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(SignedStreamURLPolicy.rejection(resolvedAt: now.addingTimeInterval(-100), expiresAt: now.addingTimeInterval(-1), now: now), .expired)
        XCTAssertEqual(SignedStreamURLPolicy.rejection(resolvedAt: now.addingTimeInterval(-100), expiresAt: now.addingTimeInterval(14 * 60), now: now), .nearExpiry)
        XCTAssertNil(SignedStreamURLPolicy.rejection(resolvedAt: now, expiresAt: now.addingTimeInterval(16 * 60), now: now))
    }

    func testMissingOrMalformedExpiryUsesConservativeAgeFallback() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(SignedStreamURLPolicy.expirationDate(in: signedURL(expiresAt: nil)))
        XCTAssertNil(SignedStreamURLPolicy.expirationDate(in: URL(string: "https://rr.example.test/videoplayback?expire=bad")!))
        XCTAssertNil(SignedStreamURLPolicy.rejection(resolvedAt: now.addingTimeInterval(-3 * 3600), expiresAt: nil, now: now))
        XCTAssertEqual(SignedStreamURLPolicy.rejection(resolvedAt: now.addingTimeInterval(-4 * 3600), expiresAt: nil, now: now), .tooOld)
    }

    func testManagerEvictsUnsafeURLWithoutTouchingDurableVideoIDMapping() async throws {
        let identity = SongIdentity(artist: "Artist", title: "Song")
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("shaudi-recovery-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let durable = PersistentYouTubeResolutionCache(fileURL: fileURL)
        let learned = await durable.learn(identity, videoID: "video000001", metadata: YouTubeResolutionMetadata(title: "Song", channel: "Artist"), source: .library, now: .now)
        XCTAssertTrue(learned)

        let manager = PlaybackManager()
        manager.seedSignedStreamForTesting(videoID: "video000001", url: signedURL(expiresAt: .now.addingTimeInterval(60)))
        XCTAssertNil(manager.cachedStreamURLForTesting("video000001"))
        let durableResult = await durable.result(for: identity)
        XCTAssertEqual(durableResult?.youtubeVideoID, "video000001")
    }

    func testCachedStartupTimeoutEvictsAndFreshResolvesExactlyOnce() async {
        let song = track()
        let (manager, item, requestID) = seededManager(tracks: [song])
        manager.testStartupWatchdogDelay = 0.01
        var resolutions = 0
        var handoffs = 0
        manager.testStreamURLProvider = { _ in
            resolutions += 1
            return self.signedURL()
        }
        manager.testRecoveryPlaybackSink = { _, _, _, _ in handoffs += 1 }

        manager.startCachedWatchdogForTesting(item: item, requestID: requestID)
        await waitUntil { handoffs == 1 }

        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(manager.retriedRequestIDForTesting, requestID)
        XCTAssertEqual(manager.recoveryAttemptForTesting?.kind, "cachedStartup")
        XCTAssertEqual(manager.currentIndex, 0)
        XCTAssertTrue(manager.currentTrack === song)
    }

    func testFastOrCancelledCachedStartupWatchdogNeverRetries() async {
        let (manager, item, requestID) = seededManager(tracks: [track()])
        manager.testStartupWatchdogDelay = 0.01
        var resolutions = 0
        manager.testStreamURLProvider = { _ in resolutions += 1; return self.signedURL() }
        manager.startCachedWatchdogForTesting(item: item, requestID: requestID)
        manager.cancelCachedWatchdogForTesting() // The playing path performs this cancellation.
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(resolutions, 0)
        XCTAssertNil(manager.retriedRequestIDForTesting)
    }

    func testStaleAndCancelledRequestsCannotStartRecovery() async {
        let (manager, item, requestID) = seededManager(tracks: [track()])
        manager.testStartupWatchdogDelay = 0.01
        var resolutions = 0
        manager.testStreamURLProvider = { _ in resolutions += 1; return self.signedURL() }
        manager.startCachedWatchdogForTesting(item: item, requestID: requestID)
        manager.seedInterruptionStateForTesting(state: .loading, requestID: UUID())
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(resolutions, 0)

        manager.seedInterruptionStateForTesting(state: .loading, requestID: requestID)
        manager.startCachedWatchdogForTesting(item: item, requestID: requestID)
        manager.cancelCurrentRequestForTesting()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(resolutions, 0)
    }

    func testFreshRetryCannotRecursivelyRetryAndPreservesQueueOriginAndTrimStart() async {
        let song = track(start: 37, end: 180)
        let next = track("video000002")
        let (manager, item, requestID) = seededManager(tracks: [song, next], startTime: 37)
        var resolutions = 0
        var retryPosition: TimeInterval?
        manager.testStreamURLProvider = { _ in resolutions += 1; return self.signedURL() }
        manager.testRecoveryPlaybackSink = { _, position, _, _ in retryPosition = position }

        XCTAssertTrue(manager.beginRecoveryForTesting(item: item, requestID: requestID, midTrack: false))
        await waitUntil { retryPosition != nil }
        XCTAssertEqual(retryPosition, 37)
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(manager.queue.map(\.youtubeVideoID), [song.youtubeVideoID, next.youtubeVideoID])
        XCTAssertEqual(manager.currentIndex, 0)
        XCTAssertEqual(manager.playbackOriginForTesting, .library)

        let (secondPlayer, secondItem) = playerItem()
        manager.seedInterruptionStateForTesting(state: .loading, requestID: requestID, player: secondPlayer)
        XCTAssertFalse(manager.beginRecoveryForTesting(item: secondItem, requestID: requestID, midTrack: false))
        XCTAssertEqual(resolutions, 1)
    }

    func testMidTrackRecoveryResumesAtPriorAuthoritativePositionAndBoundary() async {
        let song = track(start: 25, end: 190)
        let (manager, item, requestID) = seededManager(tracks: [song], state: .playing, hasStarted: true)
        var retryPosition: TimeInterval?
        var shouldPlay = false
        manager.testStreamURLProvider = { _ in self.signedURL() }
        manager.testRecoveryPlaybackSink = { _, position, intent, _ in
            retryPosition = position
            shouldPlay = intent
        }

        XCTAssertTrue(manager.beginRecoveryForTesting(item: item, requestID: requestID, midTrack: true, currentPosition: 125))
        await waitUntil { retryPosition != nil }
        XCTAssertEqual(retryPosition, 125)
        XCTAssertTrue(shouldPlay)
        XCTAssertTrue(manager.currentTrack === song)
        let newItem = AVPlayerItem(url: signedURL())
        manager.applyCurrentEndTimeForTesting(to: newItem)
        XCTAssertEqual(newItem.forwardPlaybackEndTime.seconds, 190, accuracy: 0.01)
    }

    func testStallAfterGraceTriggersOneRecovery() async {
        let (manager, item, requestID) = seededManager(tracks: [track()], state: .playing, hasStarted: true)
        manager.testStallRecoveryDelay = 0.01
        var handoffs = 0
        manager.testStreamURLProvider = { _ in self.signedURL() }
        manager.testRecoveryPlaybackSink = { _, _, _, _ in handoffs += 1 }
        manager.triggerStallRecoveryForTesting(item: item, requestID: requestID)
        await waitUntil { handoffs == 1 }
        XCTAssertEqual(manager.recoveryAttemptForTesting?.kind, "midTrackStall")
        XCTAssertEqual(manager.currentIndex, 0)
    }

    func testFailedToEndAwayFromEOFRecoversButNearEOFDoesNotRestart() async {
        let (manager, item, requestID) = seededManager(tracks: [track()], state: .playing, hasStarted: true)
        var handoffs = 0
        manager.testStreamURLProvider = { _ in self.signedURL() }
        manager.testRecoveryPlaybackSink = { _, _, _, _ in handoffs += 1 }
        manager.triggerFailedToEndRecoveryForTesting(item: item, requestID: requestID, position: 100, effectiveEnd: 215)
        await waitUntil { handoffs == 1 }
        XCTAssertEqual(manager.recoveryAttemptForTesting?.kind, "midTrackFailedToEnd")

        let (otherManager, otherItem, otherRequestID) = seededManager(tracks: [track()], state: .playing, hasStarted: true)
        var nearEndResolutions = 0
        otherManager.testStreamURLProvider = { _ in nearEndResolutions += 1; return self.signedURL() }
        XCTAssertFalse(otherManager.beginRecoveryForTesting(item: otherItem, requestID: otherRequestID, midTrack: true, currentPosition: 214))
        XCTAssertEqual(nearEndResolutions, 0)
    }

    func testRecoveryResolutionFailureSurfacesFailureWithoutLoop() async {
        let (manager, item, requestID) = seededManager(tracks: [track()], state: .playing, hasStarted: true)
        var resolutions = 0
        manager.testStreamURLProvider = { _ in
            resolutions += 1
            throw URLError(.cannotConnectToHost)
        }
        XCTAssertTrue(manager.beginRecoveryForTesting(item: item, requestID: requestID, midTrack: true, currentPosition: 80))
        await waitUntil {
            if case .failed = manager.state { return true }
            return false
        }
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(manager.retriedRequestIDForTesting, requestID)
        XCTAssertEqual(manager.currentIndex, 0)
    }

    func testSecondMidTrackStallFailsWithoutAnotherResolutionOrQueueAdvance() async {
        let song = track()
        let (manager, item, requestID) = seededManager(tracks: [song, track("video000002")], state: .playing, hasStarted: true)
        manager.testStallRecoveryDelay = 0.01
        var resolutions = 0
        var handoffs = 0
        manager.testStreamURLProvider = { _ in resolutions += 1; return self.signedURL() }
        manager.testRecoveryPlaybackSink = { _, _, _, _ in handoffs += 1 }
        XCTAssertTrue(manager.beginRecoveryForTesting(item: item, requestID: requestID, midTrack: true, currentPosition: 80))
        await waitUntil { handoffs == 1 }

        let (freshPlayer, freshItem) = playerItem()
        manager.seedInterruptionStateForTesting(state: .playing, requestID: requestID, player: freshPlayer)
        manager.triggerStallRecoveryForTesting(item: freshItem, requestID: requestID)
        await waitUntil {
            if case .failed = manager.state { return true }
            return false
        }
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(manager.currentIndex, 0)
        XCTAssertTrue(manager.currentTrack === song)
    }

    func testSecondFailedToEndAwayFromEOFDoesNotLoop() async {
        let (manager, item, requestID) = seededManager(tracks: [track()], state: .playing, hasStarted: true)
        var resolutions = 0
        var handoffs = 0
        manager.testStreamURLProvider = { _ in resolutions += 1; return self.signedURL() }
        manager.testRecoveryPlaybackSink = { _, _, _, _ in handoffs += 1 }
        XCTAssertTrue(manager.beginRecoveryForTesting(item: item, requestID: requestID, midTrack: true, currentPosition: 80))
        await waitUntil { handoffs == 1 }

        let (freshPlayer, freshItem) = playerItem()
        manager.seedInterruptionStateForTesting(state: .playing, requestID: requestID, player: freshPlayer)
        manager.triggerFailedToEndRecoveryForTesting(item: freshItem, requestID: requestID, position: 90, effectiveEnd: 215)
        if case .failed = manager.state {} else { XCTFail("Expected terminal playback failure") }
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(manager.currentIndex, 0)
    }

    func testInterruptionWithoutResumeWhileRecoveryResolvesPreservesPause() async {
        let (manager, item, requestID) = seededManager(tracks: [track()], state: .playing, hasStarted: true)
        var resumedIntent: Bool?
        manager.testStreamURLProvider = { _ in
            try await Task.sleep(for: .milliseconds(40))
            return self.signedURL()
        }
        manager.testRecoveryPlaybackSink = { _, _, shouldPlay, _ in resumedIntent = shouldPlay }
        XCTAssertTrue(manager.beginRecoveryForTesting(item: item, requestID: requestID, midTrack: true, currentPosition: 80))
        manager.handleAudioSessionInterruption(type: .began)
        XCTAssertTrue(manager.wasPlayingBeforeInterruption)
        manager.handleAudioSessionInterruption(type: .ended)
        await waitUntil { resumedIntent != nil }
        XCTAssertEqual(resumedIntent, false)
        XCTAssertEqual(manager.state, .loading) // The test sink stops before item creation.
    }

    func testMeaningfulNetworkChangeEvictsOnlySpeculativeURLs() {
        let current = track("video000001")
        let (manager, _, _) = seededManager(tracks: [current], state: .playing, hasStarted: true)
        let currentPlayer = manager.currentPlayerForTesting
        manager.seedSignedStreamForTesting(videoID: current.youtubeVideoID, url: signedURL(), speculative: true)
        manager.seedSignedStreamForTesting(videoID: "lookahead01", url: signedURL(), speculative: true)
        manager.seedSignedStreamForTesting(videoID: "prepared001", url: signedURL(), speculative: true)
        manager.seedSignedStreamForTesting(videoID: "foreground1", url: signedURL())
        manager.protectPreparedVideoForTesting("prepared001")

        manager.changeNetworkRouteForTesting(to: .wifi)
        manager.changeNetworkRouteForTesting(to: .cellular)
        XCTAssertNil(manager.cachedStreamURLForTesting("lookahead01"))
        XCTAssertNotNil(manager.cachedStreamURLForTesting(current.youtubeVideoID))
        XCTAssertNotNil(manager.cachedStreamURLForTesting("prepared001"))
        XCTAssertNotNil(manager.cachedStreamURLForTesting("foreground1"))
        XCTAssertTrue(manager.currentPlayerForTesting === currentPlayer)
        XCTAssertEqual(manager.retriedRequestIDForTesting, nil)
    }

    func testUnrelatedNetworkChangesDoNotFlushSpeculativeURL() {
        XCTAssertFalse(PlaybackNetworkRoute.shouldInvalidateSpeculativeURLs(from: .wifi, to: .other))
        XCTAssertFalse(PlaybackNetworkRoute.shouldInvalidateSpeculativeURLs(from: .cellular, to: .cellular))
        XCTAssertTrue(PlaybackNetworkRoute.shouldInvalidateSpeculativeURLs(from: .unavailable, to: .wifi))
        XCTAssertTrue(PlaybackNetworkRoute.shouldInvalidateSpeculativeURLs(from: .wifi, to: .cellular))
    }

    func testPreparedNextStillHandsOffSamePrerolledItem() {
        let current = track("video000001")
        let next = track("video000002", duration: 180)
        let manager = PlaybackManager()
        manager.seedQueueForTesting(tracks: [current, next], currentIndex: 0)
        let (preparedPlayer, preparedItem) = manager.seedPreparedNextForTesting(track: next, queueIndex: 1, url: signedURL())
        let taken = manager.takePreparedNextForTesting(queueIndex: 1, track: next)
        XCTAssertTrue(taken?.0 === preparedPlayer)
        XCTAssertTrue(taken?.1 === preparedItem)
        XCTAssertEqual(preparedItem.forwardPlaybackEndTime.seconds, 180, accuracy: 0.01)
    }

    func testRecoveryDoesNotDuplicateListeningHistoryOrManualQueue() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Track.self, Playlist.self, ListeningHistoryEntry.self, configurations: configuration)
        let context = container.mainContext
        let current = track()
        let manual = track("video000002")
        let (manager, item, requestID) = seededManager(tracks: [current, manual], state: .playing, hasStarted: true)
        manager.seedQueueForTesting(tracks: [current, manual], currentIndex: 0, manualQueueCount: 1)
        manager.configureListeningHistory(modelContext: context)
        let originalPlayer = try XCTUnwrap(manager.currentPlayerForTesting)
        manager.confirmListeningHistoryForTesting(player: originalPlayer, requestID: requestID)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ListeningHistoryEntry>()).count, 1)

        var handoffs = 0
        manager.testStreamURLProvider = { _ in self.signedURL() }
        manager.testRecoveryPlaybackSink = { _, _, _, _ in handoffs += 1 }
        XCTAssertTrue(manager.beginRecoveryForTesting(item: item, requestID: requestID, midTrack: true, currentPosition: 75))
        await waitUntil { handoffs == 1 }
        let (resumedPlayer, _) = playerItem()
        manager.confirmListeningHistoryForTesting(player: resumedPlayer, requestID: requestID)

        XCTAssertEqual(try context.fetch(FetchDescriptor<ListeningHistoryEntry>()).count, 1)
        XCTAssertEqual(manager.currentIndex, 0)
        XCTAssertEqual(manager.manualQueueCount, 1)
        XCTAssertEqual(manager.queue.map(\.youtubeVideoID), [current.youtubeVideoID, manual.youtubeVideoID])
    }
}
