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

    @Published private(set) var currentTrack: Track?
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var startupMetrics: StartupMetrics?

    private var player: AVPlayer?
    private var playbackTask: Task<Void, Never>?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var activeRequestID: UUID?
    private var resolvedStreamCache: [String: URL] = [:]
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

    func play(_ track: Track) {
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
            startPlayback(
                with: cachedURL,
                videoID: videoID,
                requestID: requestID,
                requestStartedAt: requestStartedAt,
                playerPreparationStartedAt: currentTime,
                usedCachedStream: true
            )
        } else {
            startupMetrics = StartupMetrics(
                videoID: videoID,
                streamSource: "Fresh YouTubeKit resolution"
            )
            resolveAndStartPlayback(
                videoID: videoID,
                requestID: requestID,
                requestStartedAt: requestStartedAt
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
        invalidateCurrentRequest()
        clearPlayer()
        currentTrack = nil
        state = .idle
#if os(iOS)
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
        requestStartedAt: TimeInterval
    ) {
        state = .resolving
        let resolutionStartedAt = currentTime

        playbackTask = Task { [weak self] in
            do {
                let streams = try await YouTube(
                    videoID: videoID,
                    methods: [.local]
                ).streams

                try Task.checkCancellation()

                guard let self, isActive(requestID) else {
                    return
                }

                let nativeAudioStreams = streams
                    .filterAudioOnly()
                    .filter(\.isNativelyPlayable)
                let stream = nativeAudioStreams
                    .filter { $0.fileExtension == .m4a }
                    .highestAudioBitrateStream()
                    ?? nativeAudioStreams.highestAudioBitrateStream()
                let resolutionFinishedAt = currentTime
                let resolutionTime = resolutionFinishedAt - resolutionStartedAt

                updateMetrics { metrics in
                    metrics.streamResolutionTime = resolutionTime
                }
                logTiming("Stream resolution", seconds: resolutionTime, videoID: videoID)

                guard let stream else {
                    playbackTask = nil
                    state = .failed(
                        "YouTube did not provide an audio-only stream this iPhone can play."
                    )
                    return
                }

                resolvedStreamCache[videoID] = stream.url
                playbackTask = nil
                state = .loading
                startPlayback(
                    with: stream.url,
                    videoID: videoID,
                    requestID: requestID,
                    requestStartedAt: requestStartedAt,
                    playerPreparationStartedAt: resolutionFinishedAt,
                    usedCachedStream: false
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self, isActive(requestID), !Task.isCancelled else {
                    return
                }

                playbackTask = nil
                state = .failed(
                    "YouTube stream extraction failed: \(Self.errorMessage(for: error))"
                )
            }
        }
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
        self.player = player

        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) {
            [managerReference] _, _ in
            Task { @MainActor in
                guard
                    let self = managerReference.value,
                    self.isActive(requestID),
                    let item = self.player?.currentItem,
                    item.status == .failed
                else {
                    return
                }

                self.handlePlayerFailure(
                    item.error,
                    videoID: videoID,
                    requestID: requestID,
                    requestStartedAt: requestStartedAt,
                    usedCachedStream: usedCachedStream
                )
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
            }
        }

        player.play()
#if os(iOS)
        synchronizeNowPlayingPlaybackState()
#endif
    }

    private func handlePlayerFailure(
        _ error: Error?,
        videoID: String,
        requestID: UUID,
        requestStartedAt: TimeInterval,
        usedCachedStream: Bool
    ) {
        guard isActive(requestID) else {
            return
        }

        let failedDuringPreparation = startupMetrics?.totalStartTime == nil
        resolvedStreamCache.removeValue(forKey: videoID)
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

        if let duration = validDuration(track.duration) {
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

            if let playerDuration = validDuration(player.currentItem?.duration.seconds) {
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

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false

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
            }
        ]
    }

    private func handleRemotePlayCommand() -> MPRemoteCommandHandlerStatus {
        guard let track = currentTrack else {
            return .noSuchContent
        }

        switch state {
        case .paused:
            resume()
        case .failed, .idle:
            play(track)
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
        guard let track = currentTrack else {
            return .noSuchContent
        }

        switch state {
        case .playing:
            pause()
        case .paused:
            resume()
        case .failed, .idle:
            play(track)
        case .resolving, .loading:
            return .commandFailed
        }

        return .success
    }

    private func validDuration(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite, duration > 0 else {
            return nil
        }

        return duration
    }
#endif

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
        itemStatusObservation = nil
        timeControlStatusObservation = nil
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
}
