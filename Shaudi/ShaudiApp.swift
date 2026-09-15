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
    @StateObject private var appearanceSettings = AppearanceSettings.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(playbackManager)
                .environmentObject(appearanceSettings)
        }
        .modelContainer(for: [Track.self, Playlist.self, ListeningHistoryEntry.self])
    }
}
