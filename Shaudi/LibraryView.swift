//
//  LibraryView.swift
//  Shaudi
//

import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Track.dateAdded, order: .reverse)
    private var tracks: [Track]

    @State private var isShowingNewTrack = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(tracks) { track in
                    NavigationLink {
                        TrackDetailView(track: track, queue: tracks)
                    } label: {
                        Text(track.title)
                    }
                }
                .onDelete(perform: deleteTracks)
            }
            .navigationTitle("Library")
            .toolbar {
                Button {
                    isShowingNewTrack = true
                } label: {
                    Label("New Track", systemImage: "plus")
                }
            }
            .sheet(isPresented: $isShowingNewTrack) {
                TrackEditorView(
                    title: "New Track",
                    actionTitle: "Create"
                ) { request in
                    guard !tracks.contains(where: { $0.youtubeVideoID == request.youtubeVideo.id }) else {
                        return "This YouTube video is already in Library."
                    }

                    guard let metadata = request.metadata else {
                        return "Fetch the YouTube metadata before creating this track."
                    }

                    modelContext.insert(
                        Track(
                            title: metadata.title,
                            youtubeURL: request.youtubeVideo.url,
                            youtubeVideoID: request.youtubeVideo.id,
                            channelTitle: metadata.channelTitle,
                            thumbnailURL: metadata.thumbnailURL,
                            duration: metadata.duration,
                            metadataLastRefreshed: .now
                        )
                    )

                    return nil
                }
            }
        }
    }

    private func deleteTracks(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(tracks[index])
        }
    }
}

struct TrackEditorView: View {
    struct SaveRequest {
        let title: String
        let youtubeVideo: YouTubeURLParser.Video
        let metadata: YouTubeMetadata?
    }

    @Environment(\.dismiss) private var dismiss

    let title: String
    let actionTitle: String
    let onSave: (SaveRequest) -> String?

    @State private var trackTitle: String
    @State private var youtubeURLText: String
    @State private var metadata: YouTubeMetadata?
    @State private var previewedURL: URL?
    @State private var isLoadingMetadata = false
    @State private var errorMessage: String?

    private let initialYouTubeURL: URL?
    private let metadataClient = YouTubeMetadataClient()

    init(
        title: String,
        actionTitle: String,
        initialTrackTitle: String = "",
        initialYouTubeURL: URL? = nil,
        onSave: @escaping (SaveRequest) -> String?
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.initialYouTubeURL = initialYouTubeURL
        self.onSave = onSave
        _trackTitle = State(initialValue: initialTrackTitle)
        _youtubeURLText = State(initialValue: initialYouTubeURL?.absoluteString ?? "")
    }

    private var trimmedTitle: String {
        trackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedURLText: String {
        youtubeURLText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedYouTubeVideo: YouTubeURLParser.Video? {
        YouTubeURLParser.parse(trimmedURLText)
    }

    private var isCreating: Bool {
        initialYouTubeURL == nil
    }

    private var requiresMetadataFetch: Bool {
        guard let parsedYouTubeVideo else {
            return true
        }

        return isCreating || parsedYouTubeVideo.url != initialYouTubeURL
    }

    private var hasCurrentPreview: Bool {
        metadata != nil && previewedURL == parsedYouTubeVideo?.url
    }

    private var canSave: Bool {
        guard !trimmedTitle.isEmpty, parsedYouTubeVideo != nil, !isLoadingMetadata else {
            return false
        }

        return !requiresMetadataFetch || hasCurrentPreview
    }

    var body: some View {
        NavigationStack {
            Form {
                if !isCreating {
                    TextField("Track Title", text: $trackTitle)
                }

                Section("YouTube Video") {
                    TextField("YouTube URL", text: $youtubeURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if !trimmedURLText.isEmpty && parsedYouTubeVideo == nil {
                        Text("Enter a valid YouTube video URL.")
                            .foregroundStyle(.red)
                    }

                    if requiresMetadataFetch, parsedYouTubeVideo != nil {
                        Button("Fetch Metadata") {
                            fetchMetadata()
                        }
                        .disabled(isLoadingMetadata)
                    }
                }

                metadataState
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: youtubeURLText) {
                metadata = nil
                previewedURL = nil
                errorMessage = nil

                if isCreating {
                    trackTitle = ""
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) {
                        guard let youtubeVideo = parsedYouTubeVideo else {
                            return
                        }

                        let saveError = onSave(
                            SaveRequest(
                                title: trimmedTitle,
                                youtubeVideo: youtubeVideo,
                                metadata: hasCurrentPreview ? metadata : nil
                            )
                        )

                        if let saveError {
                            errorMessage = saveError
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    @ViewBuilder
    private var metadataState: some View {
        if isLoadingMetadata {
            Section {
                HStack {
                    ProgressView()
                    Text("Loading metadata…")
                }
            }
        } else {
            if let metadata, hasCurrentPreview {
                Section("Preview") {
                    YouTubeMetadataView(
                        title: metadata.title,
                        channelTitle: metadata.channelTitle,
                        thumbnailURL: metadata.thumbnailURL,
                        duration: metadata.duration
                    )
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            } else if requiresMetadataFetch, parsedYouTubeVideo != nil, !hasCurrentPreview {
                Section {
                    Text("Ready to fetch metadata.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func fetchMetadata() {
        guard let youtubeVideo = parsedYouTubeVideo else {
            errorMessage = "Enter a valid YouTube video URL."
            return
        }

        let requestedURL = youtubeVideo.url
        isLoadingMetadata = true
        errorMessage = nil
        metadata = nil
        previewedURL = nil

        Task {
            do {
                let fetchedMetadata = try await metadataClient.metadata(for: youtubeVideo.id)
                guard parsedYouTubeVideo?.url == requestedURL else {
                    isLoadingMetadata = false
                    return
                }

                metadata = fetchedMetadata
                previewedURL = requestedURL

                if isCreating {
                    trackTitle = fetchedMetadata.title
                }
            } catch {
                guard parsedYouTubeVideo?.url == requestedURL else {
                    isLoadingMetadata = false
                    return
                }

                errorMessage = error.localizedDescription
            }

            isLoadingMetadata = false
        }
    }
}

private struct YouTubeMetadataView: View {
    let title: String
    let channelTitle: String?
    let thumbnailURL: URL?
    let duration: TimeInterval?

    var body: some View {
        if let thumbnailURL {
            AsyncImage(url: thumbnailURL) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 140)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                case .failure:
                    Label("Thumbnail unavailable", systemImage: "photo")
                        .foregroundStyle(.secondary)
                @unknown default:
                    EmptyView()
                }
            }
        }

        LabeledContent("Title", value: title)

        if let channelTitle {
            LabeledContent("Channel", value: channelTitle)
        }

        if let duration {
            LabeledContent("Duration", value: YouTubeDuration.formatted(duration))
        }
    }
}

struct TrackDetailView: View {
    @EnvironmentObject private var playbackManager: PlaybackManager

    let track: Track
    let queue: [Track]

    @Query(sort: \Playlist.dateCreated, order: .reverse)
    private var playlists: [Playlist]

    @Query(sort: \Track.dateAdded, order: .reverse)
    private var libraryTracks: [Track]

    @State private var isShowingEdit = false

    var body: some View {
        Form {
            if track.thumbnailURL != nil || track.channelTitle != nil || track.duration != nil {
                Section("YouTube Metadata") {
                    YouTubeMetadataView(
                        title: track.title,
                        channelTitle: track.channelTitle,
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
                LabeledContent("Title", value: track.title)
                LabeledContent("YouTube URL", value: track.youtubeURL.absoluteString)
                LabeledContent(
                    "Date Added",
                    value: track.dateAdded.formatted(date: .abbreviated, time: .shortened)
                )
            }

            Section("Playback") {
                if let currentTrack = playbackManager.currentTrack {
                    LabeledContent("Current Track", value: currentTrack.title)
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
        .navigationTitle(track.title)
        .toolbar {
            Button("Edit") {
                isShowingEdit = true
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
                }

                track.title = request.title
                return nil
            }
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
                Text("Playback continues for \(currentTrack.title).")
                    .foregroundStyle(.secondary)
            }
        }

        if playbackManager.currentTrack != nil {
            queueControls
        }
    }

    private func playButton(_ title: String) -> some View {
        Button(title) {
            playbackManager.play(track, in: queue)
        }
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

            Spacer()

            switch playbackManager.state {
            case .playing:
                Button {
                    playbackManager.pause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .labelStyle(.iconOnly)
                }

            case .paused:
                Button {
                    playbackManager.resume()
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .labelStyle(.iconOnly)
                }

            case .idle, .resolving, .loading, .failed:
                Image(systemName: "play.fill")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Play unavailable")
            }

            Spacer()

            Button {
                playbackManager.nextTrack()
            } label: {
                Label("Next", systemImage: "forward.fill")
                    .labelStyle(.iconOnly)
            }
            .disabled(!playbackManager.hasNextTrack)
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
