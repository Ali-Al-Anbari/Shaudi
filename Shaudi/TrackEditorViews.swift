//
//  TrackEditorViews.swift
//  Shaudi
//

import PhotosUI
import SwiftUI

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
            .scrollContentBackground(.hidden)
            .background(ShaudiTheme.canvas)
            .tint(ShaudiTheme.accent)
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

struct SongEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let track: Track

    @State private var title: String
    @State private var artist: String
    @State private var selectedCover: PhotosPickerItem?
    @State private var pendingCoverData: Data?
    @State private var shouldRemoveCustomCover = false
    @State private var errorMessage: String?

    init(track: Track) {
        self.track = track
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.displayArtist ?? "")
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedArtist: String {
        artist.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Song") {
                    TextField("Title", text: $title)
                    TextField("Artist", text: $artist)
                }

                Section("Cover") {
                    PhotosPicker(selection: $selectedCover, matching: .images) {
                        Label("Choose Custom Cover", systemImage: "photo.on.rectangle")
                    }

                    if pendingCoverData != nil {
                        Label("New custom cover selected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(ShaudiTheme.accent)
                    } else if shouldRemoveCustomCover {
                        Text("Custom cover will be removed when saved.")
                            .foregroundStyle(.secondary)
                    } else if track.customCoverID != nil {
                        Button(role: .destructive) {
                            shouldRemoveCustomCover = true
                        } label: {
                            Label("Remove Custom Cover", systemImage: "trash")
                        }
                    } else {
                        Text("Using the YouTube artwork or Shaudi fallback.")
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ShaudiTheme.canvas)
            .tint(ShaudiTheme.accent)
            .navigationTitle("Edit Song")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: selectedCover) { _, selection in
                loadSelectedCover(selection)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(trimmedTitle.isEmpty)
                }
            }
        }
    }

    private func loadSelectedCover(_ selection: PhotosPickerItem?) {
        guard let selection else {
            return
        }

        Task { @MainActor in
            defer { selectedCover = nil }
            guard let data = try? await selection.loadTransferable(type: Data.self) else {
                errorMessage = "Could not load the selected cover."
                return
            }

            pendingCoverData = data
            shouldRemoveCustomCover = false
            errorMessage = nil
        }
    }

    private func save() {
        guard !trimmedTitle.isEmpty else {
            return
        }

        do {
            if shouldRemoveCustomCover, let coverID = track.customCoverID {
                ArtworkStorage.deleteTrackCover(for: coverID)
                track.customCoverID = nil
            } else if let pendingCoverData {
                let coverID = track.customCoverID ?? UUID()
                try ArtworkStorage.saveTrackCover(data: pendingCoverData, for: coverID)
                track.customCoverID = coverID
            }

            track.title = trimmedTitle
            track.userArtistOverride = trimmedArtist.isEmpty ? nil : trimmedArtist
            dismiss()
        } catch {
            errorMessage = "Could not save the custom cover."
#if DEBUG
            print("[Artwork] Track cover save failed: \(error.localizedDescription)")
#endif
        }
    }
}

struct YouTubeMetadataView: View {
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
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }

        LabeledContent("Title", value: title)

        if let channelTitle {
            LabeledContent("Artist", value: channelTitle)
        }

        if let duration {
            LabeledContent("Duration", value: YouTubeDuration.formatted(duration))
        }
    }
}
