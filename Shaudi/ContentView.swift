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

    var body: some View {
        TabView {
            LibraryView()
            .tabItem {
                Label("Library", systemImage: "music.note.house")
            }

            SearchView()
            .tabItem {
                Label("Search", systemImage: "magnifyingglass")
            }

            PlaylistsView()
            .tabItem {
                Label("Playlists", systemImage: "music.note.list")
            }
        }
        .tint(ShaudiTheme.accent)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(ShaudiTheme.card, for: .tabBar)
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

#Preview {
    ContentView()
        .environmentObject(PlaybackManager())
        .modelContainer(for: [Track.self, Playlist.self], inMemory: true)
}
