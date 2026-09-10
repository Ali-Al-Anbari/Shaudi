//
//  ShaudiApp.swift
//  Shaudi
//
//  Created by Ali Al Anbari on 9/10/26.
//

import SwiftUI
import SwiftData

@main
struct ShaudiApp: App {
    @StateObject private var playbackManager = PlaybackManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(playbackManager)
        }
        .modelContainer(for: [Track.self, Playlist.self])
    }
}
