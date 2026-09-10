//
//  PlaybackManager.swift
//  Shaudi
//

import AVFoundation
import Combine
import Foundation
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

    func play(_ track: Track) {
        invalidateCurrentRequest()
        clearPlayer()

        let requestID = UUID()
        let requestStartedAt = currentTime
        let videoID = track.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)

        activeRequestID = requestID
        currentTrack = track

        guard !videoID.isEmpty else {
            startupMetrics = nil
            state = .failed("This legacy track does not have a YouTube video ID.")
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
    }

    func resume() {
        guard case .paused = state, let player else {
            return
        }

        state = .loading
        player.play()
    }

    func stop() {
        invalidateCurrentRequest()
        clearPlayer()
        currentTrack = nil
        state = .idle

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
                    let player = self.player,
                    player.timeControlStatus == .playing
                else {
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
