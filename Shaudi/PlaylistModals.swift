//
//  PlaylistModals.swift
//  Shaudi
//

import SwiftUI
import SwiftData

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

struct ShaudiPlaylistNameModal: View {
    let title: String
    @Binding var isPresented: Bool
    let onCreate: (String) -> Void

    @State private var name = ""
    @FocusState private var isNameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.48)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)

            VStack(alignment: .leading, spacing: 18) {
                Text(title)
                    .font(ShaudiTheme.scriptFont(size: 30, relativeTo: .title2))
                    .foregroundStyle(.white)

                TextField("Playlist Name", text: $name)
                    .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .body))
                    .textInputAutocapitalization(.words)
                    .focused($isNameFocused)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 46)
                    .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 13))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13)
                            .stroke(ShaudiTheme.accent.opacity(0.42), lineWidth: 1)
                    }

                HStack {
                    Button("Cancel", action: dismiss)
                        .foregroundStyle(.white.opacity(0.76))

                    Spacer()

                    Button("Create") {
                        guard !trimmedName.isEmpty else { return }
                        onCreate(trimmedName)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(trimmedName.isEmpty)
                }
                .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .body))
            }
            .padding(22)
            .frame(maxWidth: 340)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            .background(ShaudiTheme.lavender.opacity(0.18), in: RoundedRectangle(cornerRadius: 24))
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .stroke(ShaudiTheme.accent.opacity(0.42), lineWidth: 1)
            }
            .shadow(color: ShaudiTheme.accent.opacity(0.32), radius: 22, y: 8)
            .padding(.horizontal, 28)
            .contentShape(RoundedRectangle(cornerRadius: 24))
            .onTapGesture {}
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .onAppear { isNameFocused = true }
    }

    private func dismiss() {
        isNameFocused = false
        isPresented = false
    }
}

struct ShaudiAddToPlaylistModal: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Playlist.dateCreated, order: .reverse)
    private var playlists: [Playlist]
    @Query(sort: \Track.dateAdded, order: .reverse)
    private var libraryTracks: [Track]

    @Binding var isPresented: Bool
    let transientTrack: Track?
    let playableTrack: PlayableTrack?

    @State private var isShowingNewPlaylist = false
    @State private var errorMessage: String?

    init(
        isPresented: Binding<Bool>,
        transientTrack: Track? = nil,
        playableTrack: PlayableTrack? = nil
    ) {
        _isPresented = isPresented
        self.transientTrack = transientTrack
        self.playableTrack = playableTrack
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.48)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)

            VStack(alignment: .leading, spacing: 16) {
                Text("Add to Playlist")
                    .font(ShaudiTheme.scriptFont(size: 30, relativeTo: .title2))
                    .foregroundStyle(.white)

                Button {
                    isShowingNewPlaylist = true
                } label: {
                    Label("New Playlist", systemImage: "plus")
                        .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .body).weight(.semibold))
                        .foregroundStyle(ShaudiTheme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if playlists.isEmpty {
                    Text("Create a playlist to add this song.")
                        .font(ShaudiTheme.bodyFont(size: 15, relativeTo: .subheadline))
                        .foregroundStyle(.white.opacity(0.72))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(playlists) { playlist in
                                Button {
                                    addCurrentTrack(to: playlist)
                                } label: {
                                    HStack {
                                        Text(playlist.name)
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Spacer()
                                        Image(systemName: containsCurrentTrack(in: playlist)
                                            ? "checkmark.circle.fill" : "plus.circle")
                                            .foregroundStyle(ShaudiTheme.accent)
                                    }
                                    .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .body))
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                                .disabled(containsCurrentTrack(in: playlist))
                            }
                        }
                    }
                    .frame(maxHeight: 250)
                }

                HStack {
                    Spacer()
                    Button("Done", action: dismiss)
                        .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .body).weight(.semibold))
                        .foregroundStyle(ShaudiTheme.accent)
                }
            }
            .padding(22)
            .frame(maxWidth: 340)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            .background(ShaudiTheme.lavender.opacity(0.18), in: RoundedRectangle(cornerRadius: 24))
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .stroke(ShaudiTheme.accent.opacity(0.42), lineWidth: 1)
            }
            .shadow(color: ShaudiTheme.accent.opacity(0.32), radius: 22, y: 8)
            .padding(.horizontal, 28)
            .contentShape(RoundedRectangle(cornerRadius: 24))
            .onTapGesture {}

            if isShowingNewPlaylist {
                ShaudiPlaylistNameModal(
                    title: "Create Playlist",
                    isPresented: $isShowingNewPlaylist
                ) { name in
                    let playlist = Playlist(name: name)
                    modelContext.insert(playlist)
                    if addCurrentTrack(to: playlist) {
                        dismiss()
                    } else {
                        modelContext.delete(playlist)
                    }
                }
            }
        }
        .alert(
            "Couldn’t Add to Playlist",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private var currentVideoID: String? {
        let videoID = playableTrack?.youtubeVideoID
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? transientTrack?.youtubeVideoID ?? ""
        return videoID.isEmpty ? nil : videoID
    }

    private func containsCurrentTrack(in playlist: Playlist) -> Bool {
        guard let currentVideoID else { return false }
        return playlist.tracks.contains {
            $0.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines) == currentVideoID
        }
    }

    @discardableResult
    private func addCurrentTrack(to playlist: Playlist) -> Bool {
        guard !containsCurrentTrack(in: playlist) else {
            return false
        }
        do {
            try TrackPersistence.promoteOrReuse(
                transientTrack: transientTrack,
                playableTrack: playableTrack,
                in: modelContext,
                targetPlaylist: playlist,
                existingLibraryTracks: libraryTracks
            )
            return true
        } catch {
            #if DEBUG
            print("[ShaudiAddToPlaylistModal] addCurrentTrack failed: \(error)")
            #endif
            errorMessage = "Couldn’t add song to playlist. Please try again."
            return false
        }
    }

    private func dismiss() {
        isShowingNewPlaylist = false
        isPresented = false
    }
}
