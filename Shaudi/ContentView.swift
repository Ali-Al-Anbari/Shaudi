//
//  ContentView.swift
//  Shaudi
//
//  Created by Ali Al Anbari on 9/10/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    var body: some View {
        TabView {
            LibraryView()
            .tabItem {
                Label("Library", systemImage: "music.note.house")
            }

            PlaylistsView()
            .tabItem {
                Label("Playlists", systemImage: "music.note.list")
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Track.self, Playlist.self], inMemory: true)
}
