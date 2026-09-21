//
//  TrackDetailView.swift
//  Shaudi
//

import SwiftData
import SwiftUI

struct TrackDetailView: View {
    @EnvironmentObject private var playbackManager: PlaybackManager

    let track: Track
    let queue: [Track]
    let playbackOrigin: PlaybackOrigin

    @Query(sort: \Playlist.dateCreated, order: .reverse)
    private var playlists: [Playlist]

    @Query(sort: \Track.dateAdded, order: .reverse)
    private var libraryTracks: [Track]

    @State private var isShowingEdit = false
    @State private var isShowingTrimEditor = false

    var body: some View {
        Form {
            if track.thumbnailURL != nil || track.displayArtist != nil || track.duration != nil {
                Section("YouTube Metadata") {
                    YouTubeMetadataView(
                        title: track.title,
                        channelTitle: track.displayArtist,
                        thumbnailURL: track.thumbnailURL,
                        duration: track.duration
                    )

                    if let metadataLastRefreshed = track.metadataLastRefreshed {
                        LabeledContent(
                            "Last Refreshed",
                            value: metadataLastRefreshed.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                }
            }

            Section("Track") {
                Text(track.displayTitle)
                    .font(ShaudiTheme.scriptFont(size: 28, relativeTo: .title2))
                    .foregroundStyle(ShaudiTheme.accent)
                    .lineLimit(2)

                LabeledContent("YouTube URL", value: track.youtubeURL.absoluteString)
                LabeledContent(
                    "Date Added",
                    value: track.dateAdded.formatted(date: .abbreviated, time: .shortened)
                )
            }

            Section("Playback") {
                if let currentTrack = playbackManager.currentTrack {
                    LabeledContent("Current Track", value: currentTrack.displayTitle)
                }

                playbackControls

                if
                    playbackManager.currentTrack != nil,
                    let metrics = playbackManager.startupMetrics
                {
                    startupTiming(metrics)
                }
            }

            Section("Playlists") {
                if playlists.isEmpty {
                    Text("No playlists available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(playlists) { playlist in
                        Button {
                            toggleMembership(in: playlist)
                        } label: {
                            HStack {
                                Text(playlist.name)
                                    .foregroundStyle(.primary)

                                Spacer()

                                if isInPlaylist(playlist) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ShaudiTheme.canvas)
        .tint(ShaudiTheme.accent)
        .navigationTitle(track.displayTitle)
        .toolbar {
            Menu {
                Button {
                    isShowingEdit = true
                } label: {
                    Label("Edit Track", systemImage: "pencil")
                }

                Button {
                    isShowingTrimEditor = true
                } label: {
                    Label("Trim Song", systemImage: "scissors")
                }
            } label: {
                Label("Track Actions", systemImage: "ellipsis.circle")
            }
        }
        .sheet(isPresented: $isShowingEdit) {
            TrackEditorView(
                title: "Edit Track",
                actionTitle: "Save",
                initialTrackTitle: track.title,
                initialYouTubeURL: track.youtubeURL
            ) { request in
                let isChangingVideo = request.youtubeVideo.id != track.youtubeVideoID

                if isChangingVideo,
                   libraryTracks.contains(where: {
                       $0 !== track && $0.youtubeVideoID == request.youtubeVideo.id
                   }) {
                    return "This YouTube video is already represented by another Library track."
                }

                if track.youtubeURL != request.youtubeVideo.url {
                    guard let metadata = request.metadata else {
                        return "Fetch the YouTube metadata before changing this URL."
                    }

                    track.youtubeURL = request.youtubeVideo.url
                    track.youtubeVideoID = request.youtubeVideo.id
                    track.channelTitle = metadata.channelTitle
                    track.thumbnailURL = metadata.thumbnailURL
                    track.duration = metadata.duration
                    track.metadataLastRefreshed = .now
                    track.playbackStartTime = nil
                    track.playbackEndTime = nil
                    track.authoritativeRecommendationTitle = nil
                    track.authoritativeRecommendationArtist = nil
                }

                track.title = request.title
                return nil
            }
        }
        .sheet(isPresented: $isShowingTrimEditor) {
            TrackTrimEditorView(track: track)
        }
    }

    @ViewBuilder
    private var playbackControls: some View {
        if playbackManager.isCurrentTrack(track) {
            switch playbackManager.state {
            case .idle:
                playButton("Play Track")

            case .resolving:
                HStack {
                    ProgressView()
                    Text("Resolving audio stream…")
                }
                stopButton

            case .loading:
                HStack {
                    ProgressView()
                    Text("Preparing player…")
                }
                stopButton

            case .playing:
                Label("Playing", systemImage: "speaker.wave.2.fill")
                stopButton

            case .paused:
                Label("Paused", systemImage: "pause.fill")
                stopButton

            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                playButton("Retry")
                stopButton
            }
        } else {
            playButton(playbackManager.currentTrack == nil ? "Play Track" : "Play This Track")

            if let currentTrack = playbackManager.currentTrack {
                Text("Playback continues for \(currentTrack.displayTitle).")
                    .foregroundStyle(.secondary)
            }
        }

        if playbackManager.currentTrack != nil {
            queueControls

            HStack(spacing: 12) {
                Button {
                    playbackManager.playNext(track)
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .buttonStyle(.bordered)
                .tint(ShaudiTheme.accent)

                Button {
                    playbackManager.addToQueue(track)
                } label: {
                    Label("Add to Queue", systemImage: "text.badge.plus.fill")
                }
                .buttonStyle(.bordered)
                .tint(ShaudiTheme.accent)
            }
        }
    }

    private func playButton(_ title: String) -> some View {
        Button(title) {
            playbackManager.play(track, in: queue, origin: playbackOrigin)
        }
        .buttonStyle(.borderedProminent)
        .tint(ShaudiTheme.accent)
    }

    private var queueControls: some View {
        HStack {
            Button {
                playbackManager.previousTrack()
            } label: {
                Label("Previous", systemImage: "backward.fill")
                    .labelStyle(.iconOnly)
            }
            .disabled(!playbackManager.hasPreviousTrack)
            .font(.headline)
            .foregroundStyle(ShaudiTheme.accent)
            .frame(width: 44, height: 44)
            .background(ShaudiTheme.accent.opacity(0.12), in: Circle())

            Spacer()

            switch playbackManager.state {
            case .playing:
                Button {
                    playbackManager.pause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .labelStyle(.iconOnly)
                }
                .font(.title3)
                .foregroundStyle(ShaudiTheme.accent)
                .frame(width: 50, height: 50)
                .background(ShaudiTheme.accent.opacity(0.18), in: Circle())

            case .paused:
                Button {
                    playbackManager.resume()
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .labelStyle(.iconOnly)
                }
                .font(.title3)
                .foregroundStyle(ShaudiTheme.accent)
                .frame(width: 50, height: 50)
                .background(ShaudiTheme.accent.opacity(0.18), in: Circle())

            case .idle, .resolving, .loading, .failed:
                Image(systemName: "play.fill")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Play unavailable")
                    .frame(width: 50, height: 50)
            }

            Spacer()

            Button {
                playbackManager.nextTrack()
            } label: {
                Label("Next", systemImage: "forward.fill")
                    .labelStyle(.iconOnly)
            }
            .disabled(!playbackManager.hasNextTrack)
            .font(.headline)
            .foregroundStyle(ShaudiTheme.accent)
            .frame(width: 44, height: 44)
            .background(ShaudiTheme.accent.opacity(0.12), in: Circle())
        }
        .buttonStyle(.borderless)
    }

    private var stopButton: some View {
        Button("Stop", role: .destructive) {
            playbackManager.stop()
        }
    }

    private func startupTiming(_ metrics: PlaybackManager.StartupMetrics) -> some View {
        DisclosureGroup("Startup Timing (Temporary)") {
            LabeledContent("Stream Source", value: metrics.streamSource)
            LabeledContent(
                "Stream Resolution",
                value: streamResolutionValue(metrics)
            )
            LabeledContent("Player Start", value: metrics.playerStartTime.map(formatTime) ?? "—")
            LabeledContent("Total Start", value: metrics.totalStartTime.map(formatTime) ?? "—")
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        String(format: "%.3f s", time)
    }

    private func streamResolutionValue(_ metrics: PlaybackManager.StartupMetrics) -> String {
        if let time = metrics.streamResolutionTime {
            return formatTime(time)
        }

        return metrics.streamSource == "In-memory cache" ? "Cache hit" : "—"
    }

    private func isInPlaylist(_ playlist: Playlist) -> Bool {
        track.playlists.contains { $0 === playlist }
    }

    private func toggleMembership(in playlist: Playlist) {
        if let index = track.playlists.firstIndex(where: { $0 === playlist }) {
            track.playlists.remove(at: index)
        } else {
            track.playlists.append(playlist)
        }
    }
}
