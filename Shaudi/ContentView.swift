//
//  ContentView.swift
//  Shaudi
//
//  Created by Ali Al Anbari on 9/10/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var playbackManager: PlaybackManager
    @State private var isShowingNowPlaying = false

    var body: some View {
        TabView {
            tabContent(LibraryView())
            .tabItem {
                Label("Library", systemImage: "music.note.house")
            }

            tabContent(SearchView())
            .tabItem {
                Label("Search", systemImage: "magnifyingglass")
            }

            tabContent(PlaylistsView())
            .tabItem {
                Label("Playlists", systemImage: "music.note.list")
            }
        }
        .sheet(isPresented: $isShowingNowPlaying) {
            NowPlayingView(playbackManager: playbackManager)
        }
        .tint(ShaudiTheme.accent)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(ShaudiTheme.card, for: .tabBar)
        .onChange(of: playbackManager.playbackStartEvent) { _, event in
            recordRecentlyPlayedPlaylist(for: event)
        }
    }

    private func tabContent<Content: View>(_ content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if playbackManager.currentPlayableTrack != nil {
                    MiniPlayerView(
                        playbackManager: playbackManager,
                        onOpen: { isShowingNowPlaying = true }
                    )
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                }
            }
    }

    private func recordRecentlyPlayedPlaylist(
        for event: PlaybackManager.PlaybackStartEvent?
    ) {
        guard
            let event,
            case .playlist(let playlistID) = event.origin
        else {
            return
        }

        do {
            let playlists = try modelContext.fetch(FetchDescriptor<Playlist>())
            guard let playlist = playlists.first(where: {
                $0.persistentModelID == playlistID
            }) else {
                return
            }

            playlist.lastPlayedAt = .now
            try modelContext.save()

#if DEBUG
            print("[RecentlyPlayed] updated playlist=\(playlistID) track=\(event.trackID)")
#endif
        } catch {
#if DEBUG
            print("[RecentlyPlayed] update failed: \(error.localizedDescription)")
#endif
        }
    }
}

private struct MiniPlayerView: View {
    @ObservedObject var playbackManager: PlaybackManager
    let onOpen: () -> Void

    private var isPlaying: Bool {
        if case .playing = playbackManager.state {
            return true
        }

        return false
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    artwork

                    VStack(alignment: .leading, spacing: 2) {
                        Text(playbackManager.currentPlayableTrack?.title ?? "")
                            .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .headline))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if let channelTitle = playbackManager.currentPlayableTrack?.channelTitle,
                           !channelTitle.isEmpty
                        {
                            Text(channelTitle)
                                .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
                                .foregroundStyle(.white.opacity(0.68))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Now Playing")

            miniPlayerControl(
                systemImage: "backward.fill",
                label: "Previous",
                isEnabled: playbackManager.hasPreviousTrack
            ) {
                playbackManager.previousTrack()
            }

            miniPlayerControl(
                systemImage: isPlaying ? "pause.fill" : "play.fill",
                label: isPlaying ? "Pause" : "Play",
                isEnabled: playbackManager.currentPlayableTrack != nil
            ) {
                switch playbackManager.state {
                case .playing:
                    playbackManager.pause()
                case .paused:
                    playbackManager.resume()
                case .idle, .resolving, .loading, .failed:
                    break
                }
            }

            miniPlayerControl(
                systemImage: "forward.fill",
                label: "Next",
                isEnabled: playbackManager.hasNextTrack
            ) {
                playbackManager.nextTrack()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            ShaudiTheme.dashboardCard,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private func miniPlayerControl(
        systemImage: String,
        label: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(
                    isEnabled
                        ? ShaudiTheme.accent
                        : ShaudiTheme.accent.opacity(0.35)
                )
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }

    private var artwork: some View {
        Group {
            if let thumbnailURL = playbackManager.currentPlayableTrack?.thumbnailURL {
                AsyncImage(url: thumbnailURL) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        artworkPlaceholder
                    }
                }
            } else {
                artworkPlaceholder
            }
        }
        .frame(width: 44, height: 44)
        .background(ShaudiTheme.accent.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var artworkPlaceholder: some View {
        Image(systemName: "music.note")
            .font(.headline)
            .foregroundStyle(ShaudiTheme.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var playbackManager: PlaybackManager

    private var isPlaying: Bool {
        if case .playing = playbackManager.state {
            return true
        }

        return false
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ShaudiTheme.dashboardBackground
                    .ignoresSafeArea()

                VStack(spacing: 24) {
                    artwork

                    VStack(spacing: 6) {
                        Text(playbackManager.currentPlayableTrack?.title ?? "")
                            .font(ShaudiTheme.bodyFont(size: 22, relativeTo: .title3))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)

                        if let channelTitle = playbackManager.currentPlayableTrack?.channelTitle,
                           !channelTitle.isEmpty
                        {
                            Text(channelTitle)
                                .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .body))
                                .foregroundStyle(.white.opacity(0.68))
                                .lineLimit(1)
                        }
                    }

                    HStack(spacing: 34) {
                        expandedControl(
                            systemImage: "backward.fill",
                            label: "Previous",
                            isEnabled: playbackManager.hasPreviousTrack
                        ) {
                            playbackManager.previousTrack()
                        }

                        expandedControl(
                            systemImage: isPlaying ? "pause.fill" : "play.fill",
                            label: isPlaying ? "Pause" : "Play",
                            isEnabled: playbackManager.currentPlayableTrack != nil,
                            isPrimary: true
                        ) {
                            switch playbackManager.state {
                            case .playing:
                                playbackManager.pause()
                            case .paused:
                                playbackManager.resume()
                            case .idle, .resolving, .loading, .failed:
                                break
                            }
                        }

                        expandedControl(
                            systemImage: "forward.fill",
                            label: "Next",
                            isEnabled: playbackManager.hasNextTrack
                        ) {
                            playbackManager.nextTrack()
                        }
                    }

                    HStack(spacing: 18) {
                        Image(systemName: "shuffle")
                            .foregroundStyle(
                                playbackManager.isShuffleEnabled
                                    ? ShaudiTheme.accent
                                    : .white.opacity(0.4)
                            )

                        Image(
                            systemName: playbackManager.repeatMode == .one
                                ? "repeat.1"
                                : "repeat"
                        )
                        .foregroundStyle(
                            playbackManager.repeatMode == .off
                                ? .white.opacity(0.4)
                                : ShaudiTheme.accent
                        )
                    }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Shuffle and repeat status")
                    .accessibilityValue(
                        "Shuffle \(playbackManager.isShuffleEnabled ? "on" : "off"), repeat \(repeatDescription)"
                    )
                }
                .padding(.horizontal, 24)
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .tint(ShaudiTheme.accent)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var artwork: some View {
        Group {
            if let thumbnailURL = playbackManager.currentPlayableTrack?.thumbnailURL {
                AsyncImage(url: thumbnailURL) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        artworkPlaceholder
                    }
                }
            } else {
                artworkPlaceholder
            }
        }
        .frame(maxWidth: 320)
        .aspectRatio(1, contentMode: .fit)
        .background(ShaudiTheme.accent.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func expandedControl(
        systemImage: String,
        label: String,
        isEnabled: Bool,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: isPrimary ? 22 : 18, weight: .semibold))
                .foregroundStyle(
                    isEnabled
                        ? ShaudiTheme.accent
                        : ShaudiTheme.accent.opacity(0.35)
                )
                .frame(width: isPrimary ? 56 : 44, height: isPrimary ? 56 : 44)
                .background(
                    isPrimary
                        ? ShaudiTheme.accent.opacity(0.18)
                        : ShaudiTheme.accent.opacity(0.12),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }

    private var artworkPlaceholder: some View {
        Image(systemName: "music.note")
            .font(.largeTitle)
            .foregroundStyle(ShaudiTheme.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var repeatDescription: String {
        switch playbackManager.repeatMode {
        case .off:
            return "off"
        case .playlist:
            return "playlist"
        case .one:
            return "one"
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(PlaybackManager())
        .modelContainer(for: [Track.self, Playlist.self], inMemory: true)
}
