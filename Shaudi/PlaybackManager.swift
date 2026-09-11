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

@MainActor
final class PlaybackManager: ObservableObject {
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
        case memoryCache = "in-memory cache"
    }

    private struct StreamDiagnostics {
        let fileExtension: String
        let audioBitrate: Int?
    }

    @Published private(set) var currentTrack: Track?
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var startupMetrics: StartupMetrics?
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int?

    private var player: AVPlayer?
    private var playbackTask: Task<Void, Never>?
    private var preResolutionTask: Task<Void, Never>?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var playbackEndObserver: NSObjectProtocol?
    private var playbackBoundaryObserver: Any?
    private var activeRequestID: UUID?
    private var activePreResolutionID: UUID?
    private var preparedNextVideoID: String?
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

    func nextTrack() {
        guard let currentIndex, queue.indices.contains(currentIndex + 1) else {
            return
        }

        cancelUpcomingPreResolutionObservation()
        self.currentIndex = currentIndex + 1
#if os(iOS)
        updateRemoteQueueCommands()
#endif
        startCurrentQueueTrack()
    }

    func previousTrack() {
        guard let currentIndex, currentIndex > queue.startIndex else {
            return
        }

        cancelUpcomingPreResolutionObservation()
        self.currentIndex = currentIndex - 1
#if os(iOS)
        updateRemoteQueueCommands()
#endif
        startCurrentQueueTrack()
    }

    private func startCurrentQueueTrack() {
        guard let currentIndex, queue.indices.contains(currentIndex) else {
            stop()
            return
        }

        let track = queue[currentIndex]
        invalidateCurrentRequest()
        clearPlayer()

        let requestID = UUID()
        let requestStartedAt = currentTime
        let videoID = track.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)

        activeRequestID = requestID
        currentTrack = track
#if os(iOS)
        publishNowPlaying(track, requestID: requestID)
#endif

        guard !videoID.isEmpty else {
            startupMetrics = nil
            state = .failed("This legacy track does not have a YouTube video ID.")
#if os(iOS)
            clearNowPlaying()
#endif
            return
        }

        if let cachedURL = resolvedStreamCache[videoID] {
            startupMetrics = StartupMetrics(
                videoID: videoID,
                streamSource: "In-memory cache"
            )
            state = .loading
            log("Cache hit for \(videoID); skipping YouTubeKit resolution")
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
                methods: [.local]
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

        let nextTrack = queue[currentIndex + 1]
        let videoID = nextTrack.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !videoID.isEmpty, preparedNextVideoID != videoID else {
            return
        }

        cancelUpcomingPreResolutionObservation()
        preparedNextVideoID = videoID

        if resolvedStreamCache[videoID] != nil {
            log("Pre-resolution cache already available for \(videoID) (\(nextTrack.title))")
            return
        }

        let wasAlreadyInFlight = inFlightResolutions[videoID] != nil
        let resolutionTask = resolutionTask(for: videoID, source: .preResolution)
        let preResolutionID = UUID()
        let startedAt = currentTime
        activePreResolutionID = preResolutionID

        if wasAlreadyInFlight {
            log("Pre-resolution already in progress for \(videoID) (\(nextTrack.title))")
        } else {
            log("Pre-resolution started for \(videoID) (\(nextTrack.title))")
        }

        preResolutionTask = Task { [weak self] in
            do {
                _ = try await resolutionTask.value
                try Task.checkCancellation()

                guard let self, activePreResolutionID == preResolutionID else {
                    return
                }

                let elapsedTime = currentTime - startedAt
                log(
                    "Pre-resolution completed for \(videoID) in "
                        + "\(String(format: "%.3f", elapsedTime)) s"
                )
                activePreResolutionID = nil
                preResolutionTask = nil
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
            }
        }
    }

    private func cancelUpcomingPreResolutionObservation() {
        activePreResolutionID = nil
        preResolutionTask?.cancel()
        preResolutionTask = nil
        preparedNextVideoID = nil
    }

    private func startPlayback(
        with streamURL: URL,
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

        let item = AVPlayerItem(url: streamURL)
        let player = AVPlayer(playerItem: item)
        let managerReference = WeakReference(self)
        let itemReference = WeakReference(item)
        let trackDuration = currentTrack?.duration
        let authoritativeDuration = validDuration(trackDuration)

        if let authoritativeDuration {
            item.forwardPlaybackEndTime = CMTime(
                seconds: authoritativeDuration,
                preferredTimescale: 600
            )
        }

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
    private func publishNowPlaying(_ track: Track, requestID: UUID) {
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
        guard currentTrack != nil else {
            return
        }

        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        var information = nowPlayingCenter.nowPlayingInfo ?? [:]

        if let player {
            let elapsedTime = player.currentTime().seconds
            if elapsedTime.isFinite, elapsedTime >= 0 {
                information[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
            }

            if let intendedDuration = intendedPlaybackDuration(for: currentTrack) {
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
        guard currentTrack != nil else {
            return .noSuchContent
        }

        switch state {
        case .paused:
            resume()
        case .failed, .idle:
            startCurrentQueueTrack()
        case .resolving, .loading, .playing:
            break
        }

        return .success
    }

    private func handleRemotePauseCommand() -> MPRemoteCommandHandlerStatus {
        guard currentTrack != nil else {
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
        guard currentTrack != nil else {
            return .noSuchContent
        }

        switch state {
        case .playing:
            pause()
        case .paused:
            resume()
        case .failed, .idle:
            startCurrentQueueTrack()
        case .resolving, .loading:
            return .commandFailed
        }

        return .success
    }

    private func handleRemoteNextCommand() -> MPRemoteCommandHandlerStatus {
        guard currentTrack != nil else {
            return .noSuchContent
        }

        guard hasNextTrack else {
            return .commandFailed
        }

        nextTrack()
        return .success
    }

    private func handleRemotePreviousCommand() -> MPRemoteCommandHandlerStatus {
        guard currentTrack != nil else {
            return .noSuchContent
        }

        guard hasPreviousTrack else {
            return .commandFailed
        }

        previousTrack()
        return .success
    }

#endif

    private func intendedPlaybackDuration(for track: Track?) -> TimeInterval? {
        validDuration(track?.duration)
    }

    private func validDuration(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite, duration > 0 else {
            return nil
        }

        return duration
    }

    private func handlePlaybackCompletion(for item: AVPlayerItem, requestID: UUID) {
        guard isActive(requestID), player?.currentItem === item else {
            return
        }

        if hasNextTrack {
            nextTrack()
        } else {
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

        updateMetrics { metrics in
            metrics.playerStartTime = playerStartTime
            metrics.totalStartTime = totalStartTime
        }
        logTiming("Player preparation/start", seconds: playerStartTime, videoID: videoID)
        logTiming("Total startup", seconds: totalStartTime, videoID: videoID)
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
