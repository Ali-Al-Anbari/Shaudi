//
//  PlaybackManager.swift
//  Shaudi
//

import AVFoundation
import Combine
import Foundation
#if os(iOS)
import MediaPlayer
import UIKit
#endif
import YouTubeKit

private final class WeakReference<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}

struct PlayableTrack: Identifiable, Hashable {
    let youtubeVideoID: String
    let title: String
    let channelTitle: String?
    let thumbnailURL: URL?
    let duration: TimeInterval?

    var id: String {
        youtubeVideoID
    }

    init(
        youtubeVideoID: String,
        title: String,
        channelTitle: String?,
        thumbnailURL: URL?,
        duration: TimeInterval?
    ) {
        self.youtubeVideoID = youtubeVideoID
        self.title = title
        self.channelTitle = channelTitle
        self.thumbnailURL = thumbnailURL
        self.duration = duration
    }

    init(track: Track) {
        self.init(
            youtubeVideoID: track.youtubeVideoID,
            title: track.title,
            channelTitle: track.channelTitle,
            thumbnailURL: track.thumbnailURL,
            duration: track.duration
        )
    }
}

@MainActor
final class PlaybackManager: ObservableObject {
    private let streamLookaheadCount = 10

    enum PlaybackState {
        case idle
        case resolving
        case loading
        case playing
        case paused
        case failed(String)
    }

    struct StartupMetrics {
        let videoID: String
        var streamSource: String
        var streamResolutionTime: TimeInterval? = nil
        var playerStartTime: TimeInterval? = nil
        var totalStartTime: TimeInterval? = nil
    }

    private enum StreamResolutionError: Error {
        case noPlayableStream
    }

    private enum StreamResolutionSource: String {
        case foreground = "normal foreground extraction"
        case preResolution = "pre-resolution"
        case lookahead = "lookahead"
        case memoryCache = "in-memory cache"
    }

    private struct StreamDiagnostics {
        let fileExtension: String
        let audioBitrate: Int?
    }

    // The auxiliary player drives loading/preroll and becomes the current player on handoff.
    private struct PreparedNextPlayback {
        let preparationID: UUID
        let queueIndex: Int
        let track: Track
        let videoID: String
        let streamURL: URL
        let item: AVPlayerItem
        let player: AVPlayer
        let preparationStartedAt: TimeInterval
        var readyAt: TimeInterval?
    }

    @Published private(set) var currentTrack: Track?
    @Published private(set) var currentPlayableTrack: PlayableTrack?
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var startupMetrics: StartupMetrics?
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int?

    private var player: AVPlayer?
    private var playbackTask: Task<Void, Never>?
    private var preResolutionTask: Task<Void, Never>?
    private var lookaheadTask: Task<Void, Never>?
    private var nextItemPrerollTask: Task<Void, Never>?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var nextItemStatusObservation: NSKeyValueObservation?
    private var playbackEndObserver: NSObjectProtocol?
    private var playbackBoundaryObserver: Any?
    private var activeRequestID: UUID?
    private var activePreResolutionID: UUID?
    private var activeLookaheadID: UUID?
    private var preparedNextVideoID: String?
    private var preparedNextPlayback: PreparedNextPlayback?
    private var resolvedStreamCache: [String: URL] = [:]
    private var resolvedStreamDiagnostics: [String: StreamDiagnostics] = [:]
    private var inFlightResolutions: [String: Task<URL, Error>] = [:]
#if os(iOS)
    private var remoteCommandTargets: [Any] = []
    private var artworkTask: Task<Void, Never>?
    private var cachedArtworkURL: URL?
    private var cachedArtwork: MPMediaItemArtwork?
#endif

    init() {
#if os(iOS)
        configureRemoteCommands()
#endif
    }

    var hasPreviousTrack: Bool {
        guard let currentIndex else {
            return false
        }

        return currentIndex > queue.startIndex
    }

    var hasNextTrack: Bool {
        guard let currentIndex else {
            return false
        }

        return queue.indices.contains(currentIndex + 1)
    }

    func play(_ track: Track, in orderedQueue: [Track]) {
        cancelUpcomingPreResolutionObservation()

        if let selectedIndex = orderedQueue.firstIndex(where: { $0 === track }) {
            queue = orderedQueue
            currentIndex = selectedIndex
        } else {
            queue = [track]
            currentIndex = queue.startIndex
        }

#if os(iOS)
        updateRemoteQueueCommands()
#endif
        startCurrentQueueTrack()
    }

    func play(_ track: Track) {
        play(track, in: [track])
    }

    func play(_ track: PlayableTrack) {
        cancelUpcomingPreResolutionObservation()
        queue = []
        currentIndex = nil
#if os(iOS)
        updateRemoteQueueCommands()
#endif
        startPlaybackContext(track, persistentTrack: nil)
    }

    func nextTrack() {
        advanceToNextTrack(reason: "Next")
    }

    func previousTrack() {
        guard let currentIndex, currentIndex > queue.startIndex else {
            return
        }

        let requestedAt = currentTime
        let previousIndex = currentIndex - 1
        let videoID = queue[previousIndex].youtubeVideoID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        log("Previous requested for \(videoID)")
        cancelUpcomingPreResolutionObservation()
        self.currentIndex = previousIndex
#if os(iOS)
        updateRemoteQueueCommands()
#endif
        startCurrentQueueTrack(requestStartedAt: requestedAt)
    }

    private func advanceToNextTrack(reason: String) {
        guard let currentIndex, queue.indices.contains(currentIndex + 1) else {
            return
        }

        let requestedAt = currentTime
        let nextIndex = currentIndex + 1
        let nextTrack = queue[nextIndex]
        let videoID = nextTrack.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
        log("\(reason) advance requested for \(videoID)")

        let preparedPlayback = takePreparedNextPlayback(
            queueIndex: nextIndex,
            track: nextTrack,
            videoID: videoID
        )
        cancelUpcomingPreResolutionObservation()
        self.currentIndex = nextIndex
#if os(iOS)
        updateRemoteQueueCommands()
#endif
        startCurrentQueueTrack(
            preparedPlayback: preparedPlayback,
            requestStartedAt: requestedAt
        )
    }

    private func startCurrentQueueTrack(
        preparedPlayback: PreparedNextPlayback? = nil,
        requestStartedAt: TimeInterval? = nil
    ) {
        guard let currentIndex, queue.indices.contains(currentIndex) else {
            stop()
            return
        }

        let track = queue[currentIndex]
        startPlaybackContext(
            PlayableTrack(track: track),
            persistentTrack: track,
            preparedPlayback: preparedPlayback,
            requestStartedAt: requestStartedAt
        )
    }

    private func startPlaybackContext(
        _ playableTrack: PlayableTrack,
        persistentTrack: Track?,
        preparedPlayback: PreparedNextPlayback? = nil,
        requestStartedAt: TimeInterval? = nil
    ) {
        invalidateCurrentRequest()
        clearPlayer()

        let requestID = UUID()
        let requestStartedAt = requestStartedAt ?? currentTime
        let videoID = playableTrack.youtubeVideoID
            .trimmingCharacters(in: .whitespacesAndNewlines)

        activeRequestID = requestID
        currentTrack = persistentTrack
        currentPlayableTrack = playableTrack
#if os(iOS)
        publishNowPlaying(playableTrack, requestID: requestID)
#endif

        guard !videoID.isEmpty else {
            if let preparedPlayback {
                discard(preparedPlayback)
            }
            startupMetrics = nil
            state = .failed("This legacy track does not have a YouTube video ID.")
#if os(iOS)
            clearNowPlaying()
#endif
            return
        }

        if
            let preparedPlayback,
            preparedPlayback.queueIndex == currentIndex,
            preparedPlayback.track === persistentTrack,
            preparedPlayback.videoID == videoID
        {
            let wasFullyPrepared = preparedPlayback.readyAt != nil
            startupMetrics = StartupMetrics(
                videoID: videoID,
                streamSource: wasFullyPrepared
                    ? "Prepared next item"
                    : "Cached URL, item preparation in progress"
            )
            state = .loading

            if wasFullyPrepared {
                log("Using prepared item for \(videoID)")
            } else {
                log("Using cached URL but unprepared item for \(videoID)")
            }

            startPlayback(
                with: preparedPlayback.item,
                player: preparedPlayback.player,
                videoID: videoID,
                requestID: requestID,
                requestStartedAt: requestStartedAt,
                playerPreparationStartedAt: requestStartedAt,
                usedCachedStream: true
            )
            return
        }

        if let preparedPlayback {
            discard(preparedPlayback)
        }

        if let cachedURL = resolvedStreamCache[videoID] {
            startupMetrics = StartupMetrics(
                videoID: videoID,
                streamSource: "In-memory cache"
            )
            state = .loading
            log("Cache hit for \(videoID); skipping YouTubeKit resolution")
            log("Using cached URL but unprepared item for \(videoID)")
            logSelectedStream(
                videoID: videoID,
                diagnostics: resolvedStreamDiagnostics[videoID],
                source: .memoryCache
            )
            startPlayback(
                with: cachedURL,
                videoID: videoID,
                requestID: requestID,
                requestStartedAt: requestStartedAt,
                playerPreparationStartedAt: currentTime,
                usedCachedStream: true
            )
        } else {
            let isJoiningInFlightResolution = inFlightResolutions[videoID] != nil
            startupMetrics = StartupMetrics(
                videoID: videoID,
                streamSource: isJoiningInFlightResolution
                    ? "In-flight pre-resolution"
                    : "Fresh YouTubeKit resolution"
            )
            if isJoiningInFlightResolution {
                log("Waiting for pre-resolution; next item is not prepared for \(videoID)")
            } else {
                log("Using normal foreground extraction for \(videoID)")
            }
            resolveAndStartPlayback(
                videoID: videoID,
                requestID: requestID,
                requestStartedAt: requestStartedAt,
                isJoiningInFlightResolution: isJoiningInFlightResolution
            )
        }
    }

    func pause() {
        guard case .playing = state else {
            return
        }

        player?.pause()
        state = .paused
#if os(iOS)
        synchronizeNowPlayingPlaybackState()
#endif
    }

    func resume() {
        guard case .paused = state, let player else {
            return
        }

        state = .loading
        player.play()
#if os(iOS)
        synchronizeNowPlayingPlaybackState()
#endif
    }

    func stop() {
        cancelUpcomingPreResolutionObservation()
        invalidateCurrentRequest()
        clearPlayer()
        queue = []
        currentIndex = nil
        currentTrack = nil
        currentPlayableTrack = nil
        state = .idle
#if os(iOS)
        updateRemoteQueueCommands()
        clearNowPlaying()
#endif

        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func isCurrentTrack(_ track: Track) -> Bool {
        currentTrack === track
    }

    func isCurrentPlayable(_ youtubeVideoID: String) -> Bool {
        currentPlayableTrack?.youtubeVideoID == youtubeVideoID
    }

    private func resolveAndStartPlayback(
        videoID: String,
        requestID: UUID,
        requestStartedAt: TimeInterval,
        isJoiningInFlightResolution: Bool = false
    ) {
        state = .resolving
        let resolutionStartedAt = currentTime
        let resolutionTask = resolutionTask(for: videoID, source: .foreground)

        playbackTask = Task { [weak self] in
            do {
                let streamURL = try await resolutionTask.value

                try Task.checkCancellation()

                guard let self, isActive(requestID) else {
                    return
                }

                let resolutionFinishedAt = currentTime
                let resolutionTime = resolutionFinishedAt - resolutionStartedAt

                updateMetrics { metrics in
                    metrics.streamResolutionTime = resolutionTime
                }
                logTiming("Stream resolution", seconds: resolutionTime, videoID: videoID)

                playbackTask = nil
                state = .loading
                if isJoiningInFlightResolution {
                    log("Using cached URL but unprepared item for \(videoID)")
                }
                startPlayback(
                    with: streamURL,
                    videoID: videoID,
                    requestID: requestID,
                    requestStartedAt: requestStartedAt,
                    playerPreparationStartedAt: resolutionFinishedAt,
                    usedCachedStream: isJoiningInFlightResolution
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self, isActive(requestID), !Task.isCancelled else {
                    return
                }

                playbackTask = nil
                if case StreamResolutionError.noPlayableStream = error {
                    state = .failed(
                        "YouTube did not provide an audio-only stream this iPhone can play."
                    )
                } else {
                    state = .failed(
                        "YouTube stream extraction failed: \(Self.errorMessage(for: error))"
                    )
                }
            }
        }
    }

    private func resolutionTask(
        for videoID: String,
        source: StreamResolutionSource
    ) -> Task<URL, Error> {
        if let existingTask = inFlightResolutions[videoID] {
            return existingTask
        }

        let task = Task { @MainActor [weak self] () throws -> URL in
            guard let self else {
                throw CancellationError()
            }

            defer {
                inFlightResolutions[videoID] = nil
            }

            let streams = try await YouTube(
                videoID: videoID,
                methods: [.local],
                audioOnlyM4AIsSufficient: true
            ).streams

            try Task.checkCancellation()

            let nativeAudioStreams = streams
                .filterAudioOnly()
                .filter(\.isNativelyPlayable)
            let stream = nativeAudioStreams
                .filter { $0.fileExtension == .m4a }
                .highestAudioBitrateStream()
                ?? nativeAudioStreams.highestAudioBitrateStream()

            guard let stream else {
                throw StreamResolutionError.noPlayableStream
            }

            let diagnostics = StreamDiagnostics(
                fileExtension: stream.fileExtension.rawValue,
                audioBitrate: stream.bitrate ?? stream.averageBitrate
            )
            logSelectedStream(videoID: videoID, diagnostics: diagnostics, source: source)
            resolvedStreamDiagnostics[videoID] = diagnostics
            resolvedStreamCache[videoID] = stream.url
            return stream.url
        }

        inFlightResolutions[videoID] = task
        return task
    }

    private func beginPreResolvingNextTrack() {
        guard
            let currentIndex,
            queue.indices.contains(currentIndex + 1)
        else {
            return
        }

        let nextIndex = currentIndex + 1
        let nextTrack = queue[nextIndex]
        let videoID = nextTrack.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard preparedNextVideoID != videoID else {
            return
        }

        cancelUpcomingPreResolutionObservation()
        preparedNextVideoID = videoID
        let preResolutionID = UUID()
        activePreResolutionID = preResolutionID

        guard !videoID.isEmpty else {
            activePreResolutionID = nil
            beginLookaheadFill(from: currentIndex)
            return
        }

        if let cachedURL = resolvedStreamCache[videoID] {
            log("Pre-resolution cache already available for \(videoID) (\(nextTrack.title))")
            beginPreparingNextItem(
                with: cachedURL,
                track: nextTrack,
                queueIndex: nextIndex,
                videoID: videoID,
                preparationID: preResolutionID
            )
            return
        }

        let wasAlreadyInFlight = inFlightResolutions[videoID] != nil
        let resolutionTask = resolutionTask(for: videoID, source: .preResolution)
        let startedAt = currentTime

        if wasAlreadyInFlight {
            log("Pre-resolution already in progress for \(videoID) (\(nextTrack.title))")
        } else {
            log("Pre-resolution started for \(videoID) (\(nextTrack.title))")
        }

        preResolutionTask = Task { [weak self] in
            do {
                let streamURL = try await resolutionTask.value
                try Task.checkCancellation()

                guard
                    let self,
                    activePreResolutionID == preResolutionID,
                    isExpectedNextTrack(nextTrack, at: nextIndex, videoID: videoID)
                else {
                    return
                }

                let elapsedTime = currentTime - startedAt
                log(
                    "Pre-resolution completed for \(videoID) in "
                        + "\(String(format: "%.3f", elapsedTime)) s"
                )
                preResolutionTask = nil
                beginPreparingNextItem(
                    with: streamURL,
                    track: nextTrack,
                    queueIndex: nextIndex,
                    videoID: videoID,
                    preparationID: preResolutionID
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self, activePreResolutionID == preResolutionID else {
                    return
                }

                let reason: String
                if case StreamResolutionError.noPlayableStream = error {
                    reason = "no natively playable audio-only stream was available"
                } else {
                    reason = Self.errorMessage(for: error)
                }

                log(
                    "Pre-resolution failed for \(videoID): "
                        + reason
                )
                activePreResolutionID = nil
                preResolutionTask = nil
                beginLookaheadFill(from: nextIndex - 1)
            }
        }
    }

    private func cancelUpcomingPreResolutionObservation() {
        activePreResolutionID = nil
        preResolutionTask?.cancel()
        preResolutionTask = nil
        preparedNextVideoID = nil
        discardPreparedNextPlayback()
        cancelLookaheadFill()
    }

    private func beginPreparingNextItem(
        with streamURL: URL,
        track: Track,
        queueIndex: Int,
        videoID: String,
        preparationID: UUID
    ) {
        guard
            activePreResolutionID == preparationID,
            isExpectedNextTrack(track, at: queueIndex, videoID: videoID)
        else {
            return
        }

        discardPreparedNextPlayback()

        let preparationStartedAt = currentTime
        let asset = AVURLAsset(url: streamURL)
        let item = AVPlayerItem(
            asset: asset,
            automaticallyLoadedAssetKeys: [.isPlayable, .duration]
        )
        applyAuthoritativeEndTime(to: item, trackDuration: track.duration)

        let preparationPlayer = AVPlayer(playerItem: item)
        preparedNextPlayback = PreparedNextPlayback(
            preparationID: preparationID,
            queueIndex: queueIndex,
            track: track,
            videoID: videoID,
            streamURL: streamURL,
            item: item,
            player: preparationPlayer,
            preparationStartedAt: preparationStartedAt,
            readyAt: nil
        )
        log("Next-item preparation started for \(videoID)")

        let managerReference = WeakReference(self)
        let itemReference = WeakReference(item)
        nextItemStatusObservation = item.observe(\.status, options: [.initial, .new]) {
            [managerReference, itemReference] _, _ in
            Task { @MainActor in
                guard
                    let self = managerReference.value,
                    let item = itemReference.value
                else {
                    return
                }

                self.handleNextItemStatus(
                    preparationPlayer,
                    item: item,
                    preparationID: preparationID,
                    videoID: videoID
                )
            }
        }

        beginLookaheadFill(from: queueIndex - 1)
    }

    private func beginLookaheadFill(from anchorIndex: Int) {
        guard
            currentIndex == anchorIndex,
            queue.indices.contains(anchorIndex)
        else {
            return
        }

        let firstLookaheadIndex = anchorIndex + 2
        let finalLookaheadIndex = min(
            anchorIndex + streamLookaheadCount,
            queue.count - 1
        )
        guard firstLookaheadIndex <= finalLookaheadIndex else {
            return
        }

        cancelLookaheadFill()

        let lookaheadID = UUID()
        activeLookaheadID = lookaheadID
        let candidates = (firstLookaheadIndex...finalLookaheadIndex).map { queueIndex in
            let track = queue[queueIndex]
            return (
                queueIndex: queueIndex,
                track: track,
                videoID: track.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        log("Lookahead fill started from index \(anchorIndex)")

        lookaheadTask = Task { [weak self] in
            defer {
                if let self, activeLookaheadID == lookaheadID {
                    activeLookaheadID = nil
                    lookaheadTask = nil
                }
            }

            for candidate in candidates {
                guard
                    let self,
                    !Task.isCancelled,
                    isActiveLookahead(
                        lookaheadID,
                        anchorIndex: anchorIndex,
                        candidate: candidate
                    )
                else {
                    return
                }

                let videoID = candidate.videoID
                let offset = candidate.queueIndex - anchorIndex
                guard !videoID.isEmpty else {
                    log("Lookahead resolution failed for unavailable video ID at +\(offset)")
                    continue
                }

                if resolvedStreamCache[videoID] != nil {
                    log("Lookahead cache hit for \(videoID) at +\(offset)")
                    continue
                }

                let joinedExistingResolution = inFlightResolutions[videoID] != nil
                if joinedExistingResolution {
                    log("Lookahead joined existing resolution for \(videoID) at +\(offset)")
                } else {
                    log("Lookahead resolving \(videoID) at +\(offset)")
                }

                let startedAt = currentTime
                let resolutionTask = resolutionTask(for: videoID, source: .lookahead)

                do {
                    _ = try await resolutionTask.value

                    guard
                        !Task.isCancelled,
                        isActiveLookahead(
                            lookaheadID,
                            anchorIndex: anchorIndex,
                            candidate: candidate
                        )
                    else {
                        return
                    }

                    let elapsedTime = currentTime - startedAt
                    log(
                        "Lookahead resolved \(videoID) at +\(offset) in "
                            + "\(String(format: "%.3f", elapsedTime)) s"
                    )
                } catch {
                    guard
                        !Task.isCancelled,
                        isActiveLookahead(
                            lookaheadID,
                            anchorIndex: anchorIndex,
                            candidate: candidate
                        )
                    else {
                        return
                    }

                    log("Lookahead resolution failed for \(videoID) at +\(offset)")
                }
            }
        }
    }

    private func isActiveLookahead(
        _ lookaheadID: UUID,
        anchorIndex: Int,
        candidate: (queueIndex: Int, track: Track, videoID: String)
    ) -> Bool {
        guard
            activeLookaheadID == lookaheadID,
            currentIndex == anchorIndex,
            queue.indices.contains(candidate.queueIndex)
        else {
            return false
        }

        let queuedTrack = queue[candidate.queueIndex]
        return queuedTrack === candidate.track
            && queuedTrack.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
                == candidate.videoID
    }

    private func cancelLookaheadFill() {
        let hadActiveLookahead = activeLookaheadID != nil
        activeLookaheadID = nil
        lookaheadTask?.cancel()
        lookaheadTask = nil

        if hadActiveLookahead {
            log("Lookahead cancelled")
        }
    }

    private func handleNextItemStatus(
        _ preparationPlayer: AVPlayer,
        item: AVPlayerItem,
        preparationID: UUID,
        videoID: String
    ) {
        guard
            activePreResolutionID == preparationID,
            let preparedNextPlayback,
            preparedNextPlayback.preparationID == preparationID,
            preparedNextPlayback.player === preparationPlayer,
            preparedNextPlayback.item === item
        else {
            return
        }

        switch item.status {
        case .readyToPlay:
            beginPrerollingNextItem(
                preparationPlayer,
                item: item,
                preparationID: preparationID,
                videoID: videoID
            )

        case .failed:
            handlePreparedNextItemFailure(
                item,
                preparationID: preparationID,
                videoID: videoID
            )

        case .unknown:
            break

        @unknown default:
            break
        }
    }

    private func beginPrerollingNextItem(
        _ preparationPlayer: AVPlayer,
        item: AVPlayerItem,
        preparationID: UUID,
        videoID: String
    ) {
        guard nextItemPrerollTask == nil else {
            return
        }

        nextItemPrerollTask = Task { [weak self] in
            let finished = await preparationPlayer.preroll(atRate: 1)

            guard
                let self,
                !Task.isCancelled,
                activePreResolutionID == preparationID,
                var preparedNextPlayback,
                preparedNextPlayback.preparationID == preparationID,
                preparedNextPlayback.player === preparationPlayer,
                preparedNextPlayback.item === item
            else {
                return
            }

            nextItemPrerollTask = nil

            if item.status == .failed {
                handlePreparedNextItemFailure(
                    item,
                    preparationID: preparationID,
                    videoID: videoID
                )
                return
            }

            guard finished else {
                log("Next-item preparation did not finish for \(videoID)")
                return
            }

            let readyAt = currentTime
            preparedNextPlayback.readyAt = readyAt
            self.preparedNextPlayback = preparedNextPlayback
            let preparationTime = readyAt - preparedNextPlayback.preparationStartedAt
            log(
                "Next-item preparation ready for \(videoID) in "
                    + "\(String(format: "%.3f", preparationTime)) s"
            )
        }
    }

    private func handlePreparedNextItemFailure(
        _ item: AVPlayerItem,
        preparationID: UUID,
        videoID: String
    ) {
        guard
            let preparedNextPlayback,
            preparedNextPlayback.preparationID == preparationID,
            preparedNextPlayback.item === item
        else {
            return
        }

        logPlayerItemFailureDiagnostics(for: item, videoID: videoID)

        if resolvedStreamCache[videoID] == preparedNextPlayback.streamURL {
            resolvedStreamCache.removeValue(forKey: videoID)
            resolvedStreamDiagnostics.removeValue(forKey: videoID)
            log("Next-item preparation failed for \(videoID); cached URL evicted")
        } else {
            log("Next-item preparation failed for \(videoID); stale item discarded")
        }

        activePreResolutionID = nil
        preResolutionTask = nil
        discardPreparedNextPlayback()
    }

    private func isExpectedNextTrack(
        _ track: Track,
        at queueIndex: Int,
        videoID: String
    ) -> Bool {
        guard
            let currentIndex,
            queueIndex == currentIndex + 1,
            queue.indices.contains(queueIndex)
        else {
            return false
        }

        let queuedTrack = queue[queueIndex]
        return queuedTrack === track
            && queuedTrack.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines) == videoID
    }

    private func takePreparedNextPlayback(
        queueIndex: Int,
        track: Track,
        videoID: String
    ) -> PreparedNextPlayback? {
        guard
            let preparedNextPlayback,
            preparedNextPlayback.queueIndex == queueIndex,
            preparedNextPlayback.track === track,
            preparedNextPlayback.videoID == videoID
        else {
            return nil
        }

        self.preparedNextPlayback = nil
        nextItemStatusObservation = nil
        nextItemPrerollTask?.cancel()
        nextItemPrerollTask = nil
        preparedNextPlayback.player.cancelPendingPrerolls()
        activePreResolutionID = nil
        preparedNextVideoID = nil
        return preparedNextPlayback
    }

    private func discardPreparedNextPlayback() {
        guard let preparedNextPlayback else {
            nextItemStatusObservation = nil
            nextItemPrerollTask?.cancel()
            nextItemPrerollTask = nil
            return
        }

        self.preparedNextPlayback = nil
        nextItemStatusObservation = nil
        nextItemPrerollTask?.cancel()
        nextItemPrerollTask = nil
        discard(preparedNextPlayback)
    }

    private func discard(_ preparedPlayback: PreparedNextPlayback) {
        preparedPlayback.player.cancelPendingPrerolls()
        preparedPlayback.player.pause()
        preparedPlayback.player.replaceCurrentItem(with: nil)
    }

    private func startPlayback(
        with streamURL: URL,
        videoID: String,
        requestID: UUID,
        requestStartedAt: TimeInterval,
        playerPreparationStartedAt: TimeInterval,
        usedCachedStream: Bool
    ) {
        let item = AVPlayerItem(url: streamURL)
        let player = AVPlayer(playerItem: item)
        startPlayback(
            with: item,
            player: player,
            videoID: videoID,
            requestID: requestID,
            requestStartedAt: requestStartedAt,
            playerPreparationStartedAt: playerPreparationStartedAt,
            usedCachedStream: usedCachedStream
        )
    }

    private func startPlayback(
        with item: AVPlayerItem,
        player: AVPlayer,
        videoID: String,
        requestID: UUID,
        requestStartedAt: TimeInterval,
        playerPreparationStartedAt: TimeInterval,
        usedCachedStream: Bool
    ) {
        guard isActive(requestID) else {
            return
        }

        do {
            try activateAudioSession()
        } catch {
            state = .failed("The audio session could not start: \(error.localizedDescription)")
            return
        }

        let managerReference = WeakReference(self)
        let itemReference = WeakReference(item)
        let trackDuration = currentPlayableTrack?.duration
        let authoritativeDuration = validDuration(trackDuration)

        applyAuthoritativeEndTime(to: item, trackDuration: trackDuration)

        self.player = player

        if let authoritativeDuration {
            let boundaryTime = CMTime(seconds: authoritativeDuration, preferredTimescale: 600)
            playbackBoundaryObserver = player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: boundaryTime)],
                queue: .main
            ) { [managerReference, itemReference] in
                Task { @MainActor in
                    guard
                        let self = managerReference.value,
                        let item = itemReference.value
                    else {
                        return
                    }

                    self.handlePlaybackCompletion(for: item, requestID: requestID)
                }
            }
        }

        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [managerReference, itemReference] _ in
            Task { @MainActor in
                guard
                    let self = managerReference.value,
                    let item = itemReference.value
                else {
                    return
                }

                self.handlePlaybackCompletion(for: item, requestID: requestID)
            }
        }

        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) {
            [managerReference] _, _ in
            Task { @MainActor in
                guard
                    let self = managerReference.value,
                    self.isActive(requestID),
                    let item = self.player?.currentItem
                else {
                    return
                }

                switch item.status {
                case .readyToPlay:
                    self.logDurationDiagnostics(
                        for: item,
                        videoID: videoID,
                        trackDuration: trackDuration,
                        requestID: requestID
                    )
#if os(iOS)
                    self.synchronizeNowPlayingPlaybackState()
#endif

                case .failed:
                    self.handlePlayerFailure(
                        item,
                        videoID: videoID,
                        requestID: requestID,
                        requestStartedAt: requestStartedAt,
                        usedCachedStream: usedCachedStream
                    )

                case .unknown:
                    break

                @unknown default:
                    break
                }
            }
        }

        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new]) {
            [managerReference] _, _ in
            Task { @MainActor in
                guard
                    let self = managerReference.value,
                    self.isActive(requestID),
                    let player = self.player
                else {
                    return
                }

#if os(iOS)
                self.synchronizeNowPlayingPlaybackState()
#endif

                guard player.timeControlStatus == .playing else {
                    return
                }

                self.state = .playing
                self.recordPlaybackStarted(
                    videoID: videoID,
                    requestStartedAt: requestStartedAt,
                    playerPreparationStartedAt: playerPreparationStartedAt
                )
                self.beginPreResolvingNextTrack()
            }
        }

        player.play()
#if os(iOS)
        synchronizeNowPlayingPlaybackState()
#endif
    }

    private func handlePlayerFailure(
        _ item: AVPlayerItem,
        videoID: String,
        requestID: UUID,
        requestStartedAt: TimeInterval,
        usedCachedStream: Bool
    ) {
        guard isActive(requestID) else {
            return
        }

        let error = item.error
        logPlayerItemFailureDiagnostics(for: item, videoID: videoID)

        let failedDuringPreparation = startupMetrics?.totalStartTime == nil
        resolvedStreamCache.removeValue(forKey: videoID)
        resolvedStreamDiagnostics.removeValue(forKey: videoID)
        cancelUpcomingPreResolutionObservation()
        clearPlayer()

        if usedCachedStream && failedDuringPreparation {
            log("Cached stream failed during preparation for \(videoID); evicting and resolving once")
            updateMetrics { metrics in
                metrics.streamSource = "Fresh resolution after cached URL failure"
                metrics.streamResolutionTime = nil
                metrics.playerStartTime = nil
                metrics.totalStartTime = nil
            }
            resolveAndStartPlayback(
                videoID: videoID,
                requestID: requestID,
                requestStartedAt: requestStartedAt
            )
            return
        }

        state = .failed(
            "AVPlayer could not play the resolved stream: "
                + (error?.localizedDescription ?? "Unknown playback error.")
        )
#if os(iOS)
        synchronizeNowPlayingPlaybackState()
#endif
    }

#if os(iOS)
    private func publishNowPlaying(_ track: PlayableTrack, requestID: UUID) {
        artworkTask?.cancel()
        artworkTask = nil

        var information: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0,
            MPNowPlayingInfoPropertyPlaybackRate: 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1
        ]

        if let channelTitle = track.channelTitle, !channelTitle.isEmpty {
            information[MPMediaItemPropertyArtist] = channelTitle
        }

        if let duration = intendedPlaybackDuration(for: track) {
            information[MPMediaItemPropertyPlaybackDuration] = duration
        }

        if
            let thumbnailURL = track.thumbnailURL,
            thumbnailURL == cachedArtworkURL,
            let cachedArtwork
        {
            information[MPMediaItemPropertyArtwork] = cachedArtwork
        }

        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        nowPlayingCenter.nowPlayingInfo = information
        nowPlayingCenter.playbackState = .paused

        guard
            let thumbnailURL = track.thumbnailURL,
            information[MPMediaItemPropertyArtwork] == nil
        else {
            return
        }

        artworkTask = Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: thumbnailURL)
                try Task.checkCancellation()

                guard
                    let httpResponse = response as? HTTPURLResponse,
                    (200..<300).contains(httpResponse.statusCode),
                    let image = UIImage(data: data),
                    let self,
                    self.isActive(requestID)
                else {
                    return
                }

                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                cachedArtworkURL = thumbnailURL
                cachedArtwork = artwork

                var currentInformation = nowPlayingCenter.nowPlayingInfo ?? [:]
                currentInformation[MPMediaItemPropertyArtwork] = artwork
                nowPlayingCenter.nowPlayingInfo = currentInformation
            } catch {
                // Artwork is optional and must never interrupt audio playback.
            }
        }
    }

    private func synchronizeNowPlayingPlaybackState() {
        guard currentPlayableTrack != nil else {
            return
        }

        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        var information = nowPlayingCenter.nowPlayingInfo ?? [:]

        if let player {
            let elapsedTime = player.currentTime().seconds
            if elapsedTime.isFinite, elapsedTime >= 0 {
                information[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
            }

            if let intendedDuration = intendedPlaybackDuration(for: currentPlayableTrack) {
                information[MPMediaItemPropertyPlaybackDuration] = intendedDuration
            } else if let playerDuration = validDuration(player.currentItem?.duration.seconds) {
                information[MPMediaItemPropertyPlaybackDuration] = playerDuration
            }

            let playbackRate = player.timeControlStatus == .playing ? player.rate : 0
            information[MPNowPlayingInfoPropertyPlaybackRate] = playbackRate
            nowPlayingCenter.playbackState = playbackRate > 0 ? .playing : .paused
        } else {
            information[MPNowPlayingInfoPropertyPlaybackRate] = 0
            nowPlayingCenter.playbackState = .paused
        }

        nowPlayingCenter.nowPlayingInfo = information
    }

    private func clearNowPlaying() {
        artworkTask?.cancel()
        artworkTask = nil

        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        nowPlayingCenter.playbackState = .stopped
        nowPlayingCenter.nowPlayingInfo = nil
    }

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        updateRemoteQueueCommands()

        remoteCommandTargets = [
            commandCenter.playCommand.addTarget { [weak self] _ in
                guard let self else {
                    return .noSuchContent
                }

                return self.handleRemotePlayCommand()
            },
            commandCenter.pauseCommand.addTarget { [weak self] _ in
                guard let self else {
                    return .noSuchContent
                }

                return self.handleRemotePauseCommand()
            },
            commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
                guard let self else {
                    return .noSuchContent
                }

                return self.handleRemoteTogglePlayPauseCommand()
            },
            commandCenter.nextTrackCommand.addTarget { [weak self] _ in
                guard let self else {
                    return .noSuchContent
                }

                return self.handleRemoteNextCommand()
            },
            commandCenter.previousTrackCommand.addTarget { [weak self] _ in
                guard let self else {
                    return .noSuchContent
                }

                return self.handleRemotePreviousCommand()
            }
        ]
    }

    private func updateRemoteQueueCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.nextTrackCommand.isEnabled = hasNextTrack
        commandCenter.previousTrackCommand.isEnabled = hasPreviousTrack
    }

    private func handleRemotePlayCommand() -> MPRemoteCommandHandlerStatus {
        guard currentPlayableTrack != nil else {
            return .noSuchContent
        }

        switch state {
        case .paused:
            resume()
        case .failed, .idle:
            restartCurrentPlayback()
        case .resolving, .loading, .playing:
            break
        }

        return .success
    }

    private func handleRemotePauseCommand() -> MPRemoteCommandHandlerStatus {
        guard currentPlayableTrack != nil else {
            return .noSuchContent
        }

        switch state {
        case .playing:
            pause()
            return .success
        case .paused:
            return .success
        case .idle, .resolving, .loading, .failed:
            return .commandFailed
        }
    }

    private func handleRemoteTogglePlayPauseCommand() -> MPRemoteCommandHandlerStatus {
        guard currentPlayableTrack != nil else {
            return .noSuchContent
        }

        switch state {
        case .playing:
            pause()
        case .paused:
            resume()
        case .failed, .idle:
            restartCurrentPlayback()
        case .resolving, .loading:
            return .commandFailed
        }

        return .success
    }

    private func handleRemoteNextCommand() -> MPRemoteCommandHandlerStatus {
        guard currentPlayableTrack != nil else {
            return .noSuchContent
        }

        guard hasNextTrack else {
            return .commandFailed
        }

        nextTrack()
        return .success
    }

    private func handleRemotePreviousCommand() -> MPRemoteCommandHandlerStatus {
        guard currentPlayableTrack != nil else {
            return .noSuchContent
        }

        guard hasPreviousTrack else {
            return .commandFailed
        }

        previousTrack()
        return .success
    }

#endif

    private func restartCurrentPlayback() {
        if currentTrack != nil {
            startCurrentQueueTrack()
        } else if let currentPlayableTrack {
            startPlaybackContext(currentPlayableTrack, persistentTrack: nil)
        }
    }

    private func intendedPlaybackDuration(for track: PlayableTrack?) -> TimeInterval? {
        validDuration(track?.duration)
    }

    private func validDuration(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite, duration > 0 else {
            return nil
        }

        return duration
    }

    private func applyAuthoritativeEndTime(
        to item: AVPlayerItem,
        trackDuration: TimeInterval?
    ) {
        guard let authoritativeDuration = validDuration(trackDuration) else {
            return
        }

        item.forwardPlaybackEndTime = CMTime(
            seconds: authoritativeDuration,
            preferredTimescale: 600
        )
    }

    private func handlePlaybackCompletion(for item: AVPlayerItem, requestID: UUID) {
        guard isActive(requestID), player?.currentItem === item else {
            return
        }

        if hasNextTrack {
            advanceToNextTrack(reason: "Natural")
        } else {
            log("Final item completed; stopping playback")
            stop()
        }
    }

    private func logDurationDiagnostics(
        for item: AVPlayerItem,
        videoID: String,
        trackDuration: TimeInterval?,
        requestID: UUID
    ) {
        let itemDuration = validDuration(item.duration.seconds)
        let seekableRanges = seekableTimeRangesDescription(for: item)

        Task { [weak self] in
            let assetTime = try? await item.asset.load(.duration)

            guard
                let self,
                isActive(requestID),
                player?.currentItem === item
            else {
                return
            }

            let assetDuration = assetTime.flatMap { self.validDuration($0.seconds) }
            log(
                "Duration diagnostics for \(videoID): "
                    + "Track.duration=\(durationDescription(trackDuration)), "
                    + "AVPlayerItem.duration=\(durationDescription(itemDuration)), "
                    + "asset.duration=\(durationDescription(assetDuration)), "
                    + "seekableTimeRanges=\(seekableRanges)"
            )

            if
                let trackDuration = validDuration(trackDuration),
                let itemDuration,
                abs(itemDuration - trackDuration) > 2
            {
                log(
                    "Duration mismatch for \(videoID); using Track.duration "
                        + "\(durationDescription(trackDuration)) as the playback boundary"
                )
            }
        }
    }

    private func seekableTimeRangesDescription(for item: AVPlayerItem) -> String {
        let ranges = item.seekableTimeRanges.compactMap { value -> String? in
            let range = value.timeRangeValue
            let start = range.start.seconds
            let duration = range.duration.seconds
            guard start.isFinite, duration.isFinite, duration >= 0 else {
                return nil
            }

            return String(format: "%.3f...%.3f s", start, start + duration)
        }

        return ranges.isEmpty ? "none" : "[\(ranges.joined(separator: ", "))]"
    }

    private func durationDescription(_ duration: TimeInterval?) -> String {
        guard let duration else {
            return "unavailable"
        }

        return String(format: "%.3f s", duration)
    }

    private func logSelectedStream(
        videoID: String,
        diagnostics: StreamDiagnostics?,
        source: StreamResolutionSource
    ) {
        let fileExtension = diagnostics?.fileExtension ?? "unavailable"
        let audioBitrate = diagnostics?.audioBitrate.map { "\($0) bps" } ?? "unavailable"

        log(
            "Selected audio stream for \(videoID): "
                + "source=\(source.rawValue), "
                + "itag=unavailable, "
                + "fileExtension=\(fileExtension), "
                + "audioBitrate=\(audioBitrate)"
        )
    }

    private func logPlayerItemFailureDiagnostics(
        for item: AVPlayerItem,
        videoID: String
    ) {
        if let error = item.error as NSError? {
            log(
                "AVPlayerItem failed for \(videoID): "
                    + "domain=\(Self.redactedDiagnosticText(error.domain)), "
                    + "code=\(error.code), "
                    + "description=\(Self.redactedDiagnosticText(error.localizedDescription))"
            )

            if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                log(
                    "AVPlayerItem underlying error for \(videoID): "
                        + "domain=\(Self.redactedDiagnosticText(underlyingError.domain)), "
                        + "code=\(underlyingError.code), "
                        + "description="
                        + Self.redactedDiagnosticText(underlyingError.localizedDescription)
                )
            }
        } else {
            log("AVPlayerItem failed for \(videoID): error unavailable")
        }

        guard let errorLog = item.errorLog(), !errorLog.events.isEmpty else {
            log("AVPlayerItem error log for \(videoID): no events")
            return
        }

        for (index, event) in errorLog.events.enumerated() {
            let comment = event.errorComment.map(Self.redactedDiagnosticText) ?? "unavailable"
            let uriHost = event.uri.flatMap { URLComponents(string: $0)?.host } ?? "unavailable"
            log(
                "AVPlayerItem error log event \(index + 1) for \(videoID): "
                    + "statusCode=\(event.errorStatusCode), "
                    + "domain=\(Self.redactedDiagnosticText(event.errorDomain)), "
                    + "comment=\(comment), "
                    + "uriHost=\(uriHost)"
            )
        }
    }

    private func recordPlaybackStarted(
        videoID: String,
        requestStartedAt: TimeInterval,
        playerPreparationStartedAt: TimeInterval
    ) {
        guard startupMetrics?.totalStartTime == nil else {
            return
        }

        let playbackStartedAt = currentTime
        let playerStartTime = playbackStartedAt - playerPreparationStartedAt
        let totalStartTime = playbackStartedAt - requestStartedAt
        let streamSource = startupMetrics?.streamSource ?? "unknown"

        updateMetrics { metrics in
            metrics.playerStartTime = playerStartTime
            metrics.totalStartTime = totalStartTime
        }
        logTiming("Player preparation/start", seconds: playerStartTime, videoID: videoID)
        logTiming("Total startup", seconds: totalStartTime, videoID: videoID)
        if streamSource == "Prepared next item" {
            log(
                "Prepared transition for \(videoID): "
                    + "\(String(format: "%.3f", totalStartTime)) s"
            )
        } else {
            log(
                "Transition to \(videoID) reached playing in "
                    + "\(String(format: "%.3f", totalStartTime)) s "
                    + "(source: \(streamSource))"
            )
        }
    }

    private func activateAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback)
        try audioSession.setActive(true)
    }

    private func invalidateCurrentRequest() {
        activeRequestID = nil
        playbackTask?.cancel()
        playbackTask = nil
    }

    private func clearPlayer() {
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
            self.playbackEndObserver = nil
        }

        itemStatusObservation = nil
        timeControlStatusObservation = nil

        if let playbackBoundaryObserver {
            player?.removeTimeObserver(playbackBoundaryObserver)
            self.playbackBoundaryObserver = nil
        }

        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func isActive(_ requestID: UUID) -> Bool {
        activeRequestID == requestID
    }

    private func updateMetrics(_ update: (inout StartupMetrics) -> Void) {
        guard var metrics = startupMetrics else {
            return
        }

        update(&metrics)
        startupMetrics = metrics
    }

    private var currentTime: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func logTiming(_ label: String, seconds: TimeInterval, videoID: String) {
        log("\(label) for \(videoID): \(String(format: "%.3f", seconds)) s")
    }

    private func log(_ message: String) {
        print("[Playback] \(message)")
    }

    private static func errorMessage(for error: Error) -> String {
        if
            let localizedError = error as? LocalizedError,
            let description = localizedError.errorDescription,
            !description.isEmpty
        {
            return description
        }

        return error.localizedDescription
    }

    private static func redactedDiagnosticText(_ text: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"\b[A-Za-z][A-Za-z0-9+.-]*://[^\s<>\"']+"#
        ) else {
            return "unavailable"
        }

        var redactedText = text
        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = expression.matches(in: text, range: fullRange)

        for match in matches.reversed() {
            guard
                let textRange = Range(match.range, in: redactedText),
                let originalRange = Range(match.range, in: text)
            else {
                continue
            }

            let uri = String(text[originalRange])
            let host = URLComponents(string: uri)?.host
            let replacement = host.map { "<URI host=\($0)>" } ?? "<URI redacted>"
            redactedText.replaceSubrange(textRange, with: replacement)
        }

        return redactedText
    }
}
