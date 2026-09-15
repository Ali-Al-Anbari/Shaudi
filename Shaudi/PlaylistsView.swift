//
//  PlaylistsView.swift
//  Shaudi
//

import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct PlaylistsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appearanceSettings: AppearanceSettings

    @Query(sort: \Playlist.dateCreated, order: .reverse)
    private var playlists: [Playlist]

    @State private var isShowingNewPlaylist = false

    var body: some View {
        NavigationStack {
            playlistList
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $isShowingNewPlaylist) {
                PlaylistNameEditor(
                    title: "New Playlist",
                    actionTitle: "Create"
                ) { name in
                    modelContext.insert(Playlist(name: name))
                }
            }
        }
        .tint(appearanceSettings.primaryColor)
        .toolbarBackground(ShaudiTheme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var playlistList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Playlists")
                    .font(ShaudiTheme.scriptFont(size: 34, relativeTo: .title))
                    .foregroundStyle(ShaudiTheme.accent)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 12)

                Button {
                    isShowingNewPlaylist = true
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(ShaudiTheme.accent)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Playlist")
            }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 4)

            List {
                ForEach(playlists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        playlistRow(playlist)
                    }
                    .listRowBackground(ShaudiTheme.card)
                    .listRowSeparator(.hidden)
                }
                .onDelete(perform: deletePlaylists)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(ShaudiTheme.canvas)
        }
        .background(ShaudiTheme.canvas)
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        HStack(spacing: 13) {
            PlaylistArtworkView(playlist: playlist)
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(playlist.name)
                .font(ShaudiTheme.bodyFont(size: 17, relativeTo: .headline))
                .foregroundStyle(.primary)

            Spacer(minLength: 4)
        }
        .padding(.vertical, 5)
    }

    private func deletePlaylists(at offsets: IndexSet) {
        for index in offsets {
            let playlist = playlists[index]
            if let artworkID = playlist.artworkID {
                ArtworkStorage.deletePlaylistImage(for: artworkID)
            }
            modelContext.delete(playlist)
        }
    }
}

struct PlaylistNameEditor: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let actionTitle: String
    let onSave: (String) -> Void

    @State private var name: String

    init(
        title: String,
        actionTitle: String,
        initialName: String = "",
        onSave: @escaping (String) -> Void
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Playlist Name", text: $name)
            }
            .scrollContentBackground(.hidden)
            .background(ShaudiTheme.canvas)
            .tint(ShaudiTheme.accent)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) {
                        onSave(trimmedName)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
    }
}

struct PlaylistDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var playbackManager: PlaybackManager

    let playlist: Playlist

    @State private var isShowingRename = false
    @State private var isShowingAddTracks = false
    @State private var isShowingPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var editingArtworkImage: UIImage?
    @State private var isShowingArtworkCropper = false
    @State private var isPlaylistVisible = false
    @State private var infoTrack: Track?
    @State private var editingTrack: Track?
    @State private var trimmingTrack: Track?

    private let warmupTrackLimit = 10

    private struct PlaylistWarmupCandidate {
        enum Source: String {
            case statsPriority = "stats"
            case playbackOrder = "playback-order"
        }

        let videoID: String
        let source: Source
    }

    private var tracks: [Track] {
        playlist.tracksInPlaybackOrder
    }

    private var firstPlayableTrack: Track? {
        tracks.first {
            !$0.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
    }

    private var hasPlayableTrack: Bool {
        if let firstPlayableTrack {
            return true
        }
        return false
    }

    private var trackOrderSignature: [String] {
        tracks.map {
            let videoID = $0.youtubeVideoID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return videoID.isEmpty ? String(describing: $0.persistentModelID) : videoID
        }
    }

    private func playlistWarmupCandidates(
        for playbackOrder: [Track],
        maxCount: Int
    ) -> [PlaylistWarmupCandidate] {
        let indexedTracks = Array(playbackOrder.enumerated())
        let tracksWithHistory = indexedTracks
            .filter {
                $0.element.playCount > 0
                    || $0.element.totalListenedDuration > 0
                    || $0.element.lastPlayedAt != nil
            }
            .sorted { lhs, rhs in
                let leftIndex = lhs.offset
                let leftTrack = lhs.element
                let rightIndex = rhs.offset
                let rightTrack = rhs.element

                if leftTrack.playCount != rightTrack.playCount {
                    return leftTrack.playCount > rightTrack.playCount
                }

                if leftTrack.totalListenedDuration != rightTrack.totalListenedDuration {
                    return leftTrack.totalListenedDuration > rightTrack.totalListenedDuration
                }

                switch (leftTrack.lastPlayedAt, rightTrack.lastPlayedAt) {
                case let (leftDate?, rightDate?) where leftDate != rightDate:
                    return leftDate > rightDate
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    break
                }

                return leftIndex < rightIndex
            }

        var seenVideoIDs: Set<String> = []
        var candidates: [PlaylistWarmupCandidate] = []

        func appendCandidate(_ track: Track, source: PlaylistWarmupCandidate.Source) {
            guard candidates.count < maxCount else {
                return
            }

            let videoID = track.youtubeVideoID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !videoID.isEmpty, seenVideoIDs.insert(videoID).inserted else {
                return
            }

            candidates.append(PlaylistWarmupCandidate(videoID: videoID, source: source))
        }

        for indexedTrack in tracksWithHistory {
            appendCandidate(indexedTrack.element, source: .statsPriority)
        }

        for indexedTrack in indexedTracks {
            appendCandidate(indexedTrack.element, source: .playbackOrder)
        }

        return candidates
    }

    private func logPlaylistWarmupCandidates(_ candidates: [PlaylistWarmupCandidate]) {
#if DEBUG
        let descriptions = candidates.map { "\($0.videoID):\($0.source.rawValue)" }
            .joined(separator: ", ")
        print("[PlaylistWarmup] selected=[\(descriptions)]")
#endif
    }

    var body: some View {
        ZStack {
            playlistSurface

            VStack(spacing: 0) {
                playlistControlStrip

                Group {
                    if tracks.isEmpty {
                        ContentUnavailableView(
                            "No Tracks",
                            systemImage: "music.note",
                            description: Text("Add tracks from your Library.")
                        )
                    } else {
                        List {
                            ForEach(tracks) { track in
                                let isCurrentlyPlaying = playbackManager.isCurrentTrack(track)
                                    || playbackManager.isCurrentPlayable(track.youtubeVideoID)

                                playlistTrackRow(
                                    track,
                                    isCurrentlyPlaying: isCurrentlyPlaying
                                )
                                .listRowBackground(Color.clear)
                                .listRowInsets(
                                    EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12)
                                )
                                .listRowSeparator(.hidden)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
        }
        .tint(ShaudiTheme.accent)
        .navigationBarTitleDisplayMode(.inline)
        // The navigation controller owns the status-bar/Dynamic Island area. Give
        // it the same surface that starts the sticky playlist header so no parent
        // navigation background shows through above the detail content.
        .toolbarBackground(ShaudiTheme.card, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationDestination(isPresented: Binding(
            get: { infoTrack != nil },
            set: { if !$0 { infoTrack = nil } }
        )) {
            if let infoTrack {
                TrackDetailView(
                    track: infoTrack,
                    queue: tracks,
                    playbackOrigin: .playlist(playlist.persistentModelID)
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { editingTrack != nil },
            set: { if !$0 { editingTrack = nil } }
        )) {
            if let editingTrack {
                SongEditorView(track: editingTrack)
            }
        }
        .sheet(isPresented: Binding(
            get: { trimmingTrack != nil },
            set: { if !$0 { trimmingTrack = nil } }
        )) {
            if let trimmingTrack {
                TrackTrimEditorView(track: trimmingTrack)
            }
        }
        .onAppear {
            isPlaylistVisible = true
            updatePlaylistWarmup()
        }
        .onDisappear {
            isPlaylistVisible = false
            playbackManager.cancelPlaylistWarmup()
        }
        .onChange(of: trackOrderSignature) {
            updatePlaylistWarmup()
        }
        .onChange(of: playbackManager.isShuffleEnabled) {
            updatePlaylistWarmup()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                updatePlaylistWarmup()
            } else if isPlaylistVisible {
                playbackManager.cancelPlaylistWarmup()
            }
        }
        .toolbar {
            Menu {
                Button {
                    isShowingAddTracks = true
                } label: {
                    Label("Add Tracks", systemImage: "plus")
                }

                Button {
                    isShowingRename = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button {
                    isShowingPhotoPicker = true
                } label: {
                    Label("Change Playlist Photo", systemImage: "photo")
                }
            } label: {
                Label("Playlist Actions", systemImage: "ellipsis.circle")
            }
        }
        .photosPicker(
            isPresented: $isShowingPhotoPicker,
            selection: $selectedPhoto,
            matching: .images
        )
        .onChange(of: selectedPhoto) { _, photo in
            prepareSelectedArtwork(photo)
        }
        .sheet(isPresented: $isShowingRename) {
            PlaylistNameEditor(
                title: "Rename Playlist",
                actionTitle: "Save",
                initialName: playlist.name
            ) { name in
                playlist.name = name
            }
        }
        .sheet(isPresented: $isShowingAddTracks) {
            AddTracksView(playlist: playlist)
        }
        .sheet(isPresented: $isShowingArtworkCropper) {
            if let editingArtworkImage {
                ImageCropEditor(
                    image: editingArtworkImage,
                    title: "Adjust Playlist Photo",
                    cropAspectRatio: 1,
                    outputSize: ArtworkStorage.playlistOutputSize,
                    cornerRadius: 18
                ) { croppedImage in
                    savePlaylistArtwork(croppedImage)
                }
            }
        }
    }

    private var playlistControlStrip: some View {
        HStack(spacing: 10) {
            Button {
                handlePlaylistPlayButton()
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(ShaudiTheme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!hasPlayableTrack)
            .opacity(hasPlayableTrack ? 1 : 0.45)
            .accessibilityLabel("Start Playlist")

            Text(playlist.name)
                .font(ShaudiTheme.scriptFont(size: 25, relativeTo: .title3))
                .foregroundStyle(ShaudiTheme.accent)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 4)

            playbackModeButton(
                title: "Shuffle",
                systemImage: "shuffle",
                isActive: playbackManager.isShuffleEnabled
            ) {
                playbackManager.toggleShuffle()
            }

            playbackModeButton(
                title: "Repeat",
                systemImage: playbackManager.repeatMode == .one ? "repeat.1" : "repeat",
                isActive: playbackManager.repeatMode != .off,
                stateDescription: repeatModeDescription
            ) {
                playbackManager.toggleRepeatMode()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background {
            LinearGradient(
                colors: [
                    ShaudiTheme.card,
                    ShaudiTheme.card.opacity(0.62),
                    ShaudiTheme.canvas.opacity(0.12)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var playlistSurface: some View {
        ZStack {
            ShaudiTheme.canvas

            LinearGradient(
                colors: [
                    ShaudiTheme.lavender.opacity(0.09),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }

    private func playbackModeButton(
        title: String,
        systemImage: String,
        isActive: Bool,
        stateDescription: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isActive ? ShaudiTheme.accent : Color.secondary)
                .frame(width: 38, height: 38)
                .background(
                    isActive ? ShaudiTheme.accent.opacity(0.16) : Color.clear,
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(stateDescription ?? (isActive ? "On" : "Off"))
    }

    private var repeatModeDescription: String {
        switch playbackManager.repeatMode {
        case .off:
            return "Off"
        case .playlist:
            return "Playlist"
        case .one:
            return "One song"
        }
    }

    private func playlistTrackRow(
        _ track: Track,
        isCurrentlyPlaying: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                playbackManager.play(
                    track,
                    in: tracks,
                    origin: .playlist(playlist.persistentModelID)
                )
            } label: {
                HStack(spacing: 13) {
                    trackArtwork(track)

                    Text(track.displayTitle)
                        .font(
                            isCurrentlyPlaying
                                ? ShaudiTheme.bodyFont(size: 17, relativeTo: .headline).weight(.semibold)
                                : ShaudiTheme.bodyFont(size: 17, relativeTo: .headline)
                        )
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button {
                    infoTrack = track
                } label: {
                    Label("Show Info", systemImage: "info.circle")
                }

                Button {
                    trimmingTrack = track
                } label: {
                    Label("Trim Song", systemImage: "scissors")
                }

                Button {
                    editingTrack = track
                } label: {
                    Label("Edit Song", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    playlist.tracks.removeAll { $0 === track }
                } label: {
                    Label("Remove from Playlist", systemImage: "minus.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Song actions")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background(
            isCurrentlyPlaying
                ? ShaudiTheme.accent.opacity(0.16)
                : ShaudiTheme.card.opacity(0.58),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func trackArtwork(_ track: Track) -> some View {
        Group {
            if let thumbnailURL = track.thumbnailURL {
                AsyncImage(url: thumbnailURL) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        trackArtworkPlaceholder
                    }
                }
            } else {
                trackArtworkPlaceholder
            }
        }
        .frame(width: 44, height: 44)
        .background(ShaudiTheme.lavender.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var trackArtworkPlaceholder: some View {
        Image(systemName: "music.note")
            .font(.headline)
            .foregroundStyle(ShaudiTheme.lavender)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handlePlaylistPlayButton() {
        playbackManager.restartPlaylist(
            tracks,
            playlistID: playlist.persistentModelID
        )
    }

    private func updatePlaylistWarmup() {
        guard
            isPlaylistVisible,
            scenePhase == .active,
            !playbackManager.hasActivePlaylistQueue(
                for: playlist.persistentModelID
            )
        else {
            return
        }

        let effectiveOrder = playbackManager.effectivePlaylistOrder(
            tracks,
            playlistID: playlist.persistentModelID
        )
        let candidates = playlistWarmupCandidates(
            for: effectiveOrder,
            maxCount: warmupTrackLimit
        )
        logPlaylistWarmupCandidates(candidates)
        playbackManager.warmPlaylist(
            candidates.map(\.videoID),
            playlistID: playlist.persistentModelID
        )
    }

    private func prepareSelectedArtwork(_ selectedPhoto: PhotosPickerItem?) {
        guard let selectedPhoto else {
            return
        }

        Task { @MainActor in
            defer { self.selectedPhoto = nil }
            guard
                let data = try? await selectedPhoto.loadTransferable(type: Data.self),
                let image = UIImage(data: data)
            else {
                return
            }

            editingArtworkImage = image
            isShowingArtworkCropper = true
        }
    }

    private func savePlaylistArtwork(_ image: UIImage) {
        let previousArtworkID = playlist.artworkID
        let newArtworkID = UUID()

        do {
            try ArtworkStorage.savePlaylistImage(image, for: newArtworkID)
            playlist.artworkID = newArtworkID

            do {
                try modelContext.save()
            } catch {
                playlist.artworkID = previousArtworkID
                ArtworkStorage.deletePlaylistImage(for: newArtworkID)
                throw error
            }

            if let previousArtworkID {
                ArtworkStorage.deletePlaylistImage(for: previousArtworkID)
            }
        } catch {
#if DEBUG
            print("[Artwork] Playlist save failed: \(error.localizedDescription)")
#endif
        }
    }
}

private struct AddTracksView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Track.dateAdded, order: .reverse)
    private var libraryTracks: [Track]

    let playlist: Playlist

    @State private var selectedTracks: Set<ObjectIdentifier> = []
    @State private var isShowingNewTrack = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        isShowingNewTrack = true
                    } label: {
                        Label("Create New Track", systemImage: "plus")
                    }
                }

                Section("Library") {
                    if libraryTracks.isEmpty {
                        Text("No tracks in Library.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(libraryTracks) { track in
                            Button {
                                toggleSelection(of: track)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(track.displayTitle)
                                            .foregroundStyle(.primary)

                                        if isAlreadyAdded(track) {
                                            Text("Already in Playlist")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer()

                                    Image(
                                        systemName: isAlreadyAdded(track) || isSelected(track)
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                }
                            }
                            .disabled(isAlreadyAdded(track))
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(ShaudiTheme.canvas)
            .tint(ShaudiTheme.accent)
            .navigationTitle("Add Tracks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(addButtonTitle) {
                        addSelectedTracks()
                        dismiss()
                    }
                    .disabled(selectedTracks.isEmpty)
                }
            }
            .sheet(isPresented: $isShowingNewTrack) {
                TrackEditorView(
                    title: "New Track",
                    actionTitle: "Create"
                ) { request in
                    if let existingTrack = libraryTracks.first(where: {
                        $0.youtubeVideoID == request.youtubeVideo.id
                    }) {
                        guard !isAlreadyAdded(existingTrack) else {
                            return "This YouTube video is already in this Playlist."
                        }

                        add(existingTrack)
                        return nil
                    }

                    guard let metadata = request.metadata else {
                        return "Fetch the YouTube metadata before creating this track."
                    }

                    let track = Track(
                        title: metadata.title,
                        youtubeURL: request.youtubeVideo.url,
                        youtubeVideoID: request.youtubeVideo.id,
                        channelTitle: metadata.channelTitle,
                        thumbnailURL: metadata.thumbnailURL,
                        duration: metadata.duration,
                        metadataLastRefreshed: .now
                    )

                    modelContext.insert(track)
                    add(track)
                    return nil
                }
            }
        }
    }

    private var addButtonTitle: String {
        selectedTracks.isEmpty ? "Add" : "Add (\(selectedTracks.count))"
    }

    private func isAlreadyAdded(_ track: Track) -> Bool {
        playlist.tracks.contains { $0 === track }
    }

    private func isSelected(_ track: Track) -> Bool {
        selectedTracks.contains(ObjectIdentifier(track))
    }

    private func toggleSelection(of track: Track) {
        guard !isAlreadyAdded(track) else {
            return
        }

        let identifier = ObjectIdentifier(track)

        if selectedTracks.contains(identifier) {
            selectedTracks.remove(identifier)
        } else {
            selectedTracks.insert(identifier)
        }
    }

    private func addSelectedTracks() {
        for track in libraryTracks where isSelected(track) {
            add(track)
        }
    }

    private func add(_ track: Track) {
        guard !isAlreadyAdded(track) else {
            return
        }

        playlist.tracks.append(track)
    }
}
