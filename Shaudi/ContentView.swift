//
//  ContentView.swift
//  Shaudi
//
//  Created by Ali Al Anbari on 9/10/26.
//

import SwiftUI
import SwiftData

private enum RootTab: Hashable {
    case library
    case search
    case playlists
}

private struct ShaudiGlassSurface<SurfaceShape: Shape>: ViewModifier {
    let shape: SurfaceShape
    let tint: Color?
    let isInteractive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            if let tint {
                content.glassEffect(
                    isInteractive
                        ? .regular.tint(tint).interactive()
                        : .regular.tint(tint),
                    in: shape
                )
            } else {
                content.glassEffect(
                    isInteractive ? .regular.interactive() : .regular,
                    in: shape
                )
            }
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background((tint ?? .clear).opacity(0.12), in: shape)
                .overlay {
                    shape.stroke(.white.opacity(0.24), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
        }
    }
}

private extension View {
    func shaudiGlassSurface<SurfaceShape: Shape>(
        in shape: SurfaceShape,
        tint: Color? = nil,
        isInteractive: Bool = false
    ) -> some View {
        modifier(
            ShaudiGlassSurface(
                shape: shape,
                tint: tint,
                isInteractive: isInteractive
            )
        )
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var playbackManager: PlaybackManager
    @State private var selectedTab: RootTab = .library
    @State private var isShowingNowPlaying = false

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                LibraryView()
                    .tag(RootTab.library)

                SearchView()
                    .tag(RootTab.search)

                PlaylistsView()
                    .tag(RootTab.playlists)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if playbackManager.currentPlayableTrack != nil {
                MiniPlayerView(
                    playbackManager: playbackManager,
                    onOpen: { isShowingNowPlaying = true }
                )
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 6)
            }

            RootTabBar(selectedTab: $selectedTab)
        }
        .sheet(isPresented: $isShowingNowPlaying) {
            NowPlayingView(playbackManager: playbackManager)
        }
        .tint(ShaudiTheme.accent)
        .onChange(of: playbackManager.playbackStartEvent) { _, event in
            recordRecentlyPlayedPlaylist(for: event)
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

private struct RootTabBar: View {
    @Binding var selectedTab: RootTab

    var body: some View {
        HStack(spacing: 4) {
            tabButton(.library, title: "Library", systemImage: "music.note.house")
            tabButton(.search, title: "Search", systemImage: "magnifyingglass")
            tabButton(.playlists, title: "Playlists", systemImage: "music.note.list")
        }
        .padding(6)
        .shaudiGlassSurface(in: Capsule())
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .safeAreaPadding(.bottom, 8)
    }

    private func tabButton(
        _ tab: RootTab,
        title: String,
        systemImage: String
    ) -> some View {
        Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))

                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .background {
                if selectedTab == tab {
                    Color.clear
                        .shaudiGlassSurface(
                            in: Capsule(),
                            tint: ShaudiTheme.accent,
                            isInteractive: true
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            selectedTab == tab
                ? Color.black
                : Color.white.opacity(0.72)
        )
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
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
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if let channelTitle = playbackManager.currentPlayableTrack?.channelTitle,
                           !channelTitle.isEmpty
                        {
                            Text(channelTitle)
                                .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
                                .foregroundStyle(.secondary)
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
        .shaudiGlassSurface(
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
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
