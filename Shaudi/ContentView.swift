//
//  ContentView.swift
//  Shaudi
//
//  Created by Ali Al Anbari on 9/10/26.
//

import Combine
import SwiftUI
import SwiftData
import PhotosUI
import UIKit

private enum RootTab: Hashable {
    case library
    case search
    case playlists
    case settings
}

struct ShaudiGlassSurface<SurfaceShape: Shape>: ViewModifier {
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

extension View {
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
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var appearanceSettings: AppearanceSettings
    @State private var selectedTab: RootTab = .library
    @State private var isShowingNowPlaying = false
    @StateObject private var loveLetterCoordinator = AmbientLoveLetterCoordinator()

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                LibraryView()
                    .tag(RootTab.library)

                SearchView()
                    .tag(RootTab.search)

                PlaylistsView()
                    .tag(RootTab.playlists)

                SettingsView()
                    .tag(RootTab.settings)
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

            AmbientLoveLetterOverlay(
                coordinator: loveLetterCoordinator,
                isEnabled: appearanceSettings.loveLettersEnabled,
                isAppActive: scenePhase == .active,
                accentColor: appearanceSettings.primaryColor
            )
        }
        .fullScreenCover(isPresented: $isShowingNowPlaying) {
            ZStack {
                NowPlayingView(playbackManager: playbackManager)

                AmbientLoveLetterOverlay(
                    coordinator: loveLetterCoordinator,
                    isEnabled: appearanceSettings.loveLettersEnabled,
                    isAppActive: scenePhase == .active,
                    accentColor: appearanceSettings.primaryColor
                )
            }
            .presentationBackground(.clear)
        }
        // This is the surface behind every tab and its NavigationStack.  Keeping it
        // safe-area-filling prevents transparent navigation regions from revealing
        // the system's default black window background.
        .background(ShaudiTheme.dashboardBackground.ignoresSafeArea())
        .tint(appearanceSettings.primaryColor)
        .onAppear {
            playbackManager.configureListeningHistory(modelContext: modelContext)
        }
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
    @EnvironmentObject private var appearanceSettings: AppearanceSettings

    var body: some View {
        HStack(spacing: 4) {
            tabButton(.library, title: "Library", systemImage: "music.note.house")
            tabButton(.search, title: "Search", systemImage: "magnifyingglass")
            tabButton(.playlists, title: "Playlists", systemImage: "music.note.list")
            tabButton(.settings, title: "Settings", systemImage: "gearshape.fill")
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
                            tint: appearanceSettings.primaryColor,
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

#Preview {
    ContentView()
        .environmentObject(PlaybackManager())
        .modelContainer(for: [Track.self, Playlist.self], inMemory: true)
}
