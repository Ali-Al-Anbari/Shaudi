//
//  ExperimentalTrackPlayer.swift
//  Shaudi
//

import AVFoundation
import Combine
import Foundation
import YouTubeKit

@MainActor
final class ExperimentalTrackPlayer: ObservableObject {
    enum PlaybackState {
        case idle
        case resolving
        case playing
        case failed(String)
    }

    @Published private(set) var state: PlaybackState = .idle

    var isResolving: Bool {
        if case .resolving = state {
            return true
        }

        return false
    }

    var canStop: Bool {
        switch state {
        case .resolving, .playing:
            return true
        case .idle, .failed:
            return false
        }
    }

    private var player: AVPlayer?
    private var playbackTask: Task<Void, Never>?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlStatusObservation: NSKeyValueObservation?

    func play(videoID: String) {
        stop()

        let trimmedVideoID = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVideoID.isEmpty else {
            state = .failed("This legacy track does not have a YouTube video ID.")
            return
        }

        state = .resolving

        playbackTask = Task { [weak self] in
            do {
                let streams = try await YouTube(
                    videoID: trimmedVideoID,
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
                    self?.state = .failed(
                        "YouTube did not provide an audio-only stream this iPhone can play."
                    )
                    return
                }

                guard let self else {
                    return
                }

                do {
                    try activateAudioSession()
                } catch {
                    state = .failed("The audio session could not start: \(error.localizedDescription)")
                    return
                }

                try Task.checkCancellation()
                startPlayback(with: stream.url)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                self?.state = .failed(
                    "YouTube stream extraction failed: \(Self.errorMessage(for: error))"
                )
            }
        }
    }

    func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        itemStatusObservation = nil
        timeControlStatusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        state = .idle

        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func activateAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback)
        try audioSession.setActive(true)
    }

    private func startPlayback(with streamURL: URL) {
        let item = AVPlayerItem(url: streamURL)
        let player = AVPlayer(playerItem: item)
        self.player = player

        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) {
            [weak self, weak item] _, _ in
            Task { @MainActor in
                guard
                    let self,
                    let item,
                    self.player?.currentItem === item,
                    item.status == .failed
                else {
                    return
                }

                self.state = .failed(
                    "AVPlayer could not play the resolved stream: "
                        + (item.error?.localizedDescription ?? "Unknown playback error.")
                )
            }
        }

        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new]) {
            [weak self, weak player] _, _ in
            Task { @MainActor in
                guard let self, let player, self.player === player else {
                    return
                }

                if player.timeControlStatus == .playing {
                    self.state = .playing
                }
            }
        }

        player.play()
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
