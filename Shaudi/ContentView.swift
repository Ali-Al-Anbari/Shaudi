//
//  ContentView.swift
//  Shaudi
//
//  Created by Ali Al Anbari on 9/10/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack {
                Text("Library")
                    .navigationTitle("Library")
            }
            .tabItem {
                Label("Library", systemImage: "music.note.house")
            }

            NavigationStack {
                Text("Playlists")
                    .navigationTitle("Playlists")
            }
            .tabItem {
                Label("Playlists", systemImage: "music.note.list")
            }
        }
    }
}

#Preview {
    ContentView()
}
