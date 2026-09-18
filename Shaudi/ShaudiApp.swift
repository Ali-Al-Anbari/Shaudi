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
    @State private var isShowingLaunchScreen = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(playbackManager)
                    .environmentObject(appearanceSettings)

                if isShowingLaunchScreen {
                    ShaudiLaunchView()
                        .transition(.opacity)
                }
            }
            .task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.45)) {
                    isShowingLaunchScreen = false
                }
            }
        }
        .modelContainer(for: [Track.self, Playlist.self, ListeningHistoryEntry.self])
    }
}

private struct ShaudiLaunchView: View {
    @State private var isHeartGlowing = false

    var body: some View {
        ZStack {
            ShaudiTheme.dashboardBackground.ignoresSafeArea()

            RadialGradient(
                colors: [ShaudiTheme.lavender.opacity(0.36), .clear],
                center: .center,
                startRadius: 8,
                endRadius: 260
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                Text("Shaudi")
                    .font(ShaudiTheme.scriptFont(size: 58, relativeTo: .largeTitle))
                    .foregroundStyle(.white)
                    .shadow(color: ShaudiTheme.accent.opacity(0.62), radius: 16)

                Text("made with all my love, for you.")
                    .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .body))
                    .foregroundStyle(.white.opacity(0.76))

                Image(systemName: "heart.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(ShaudiTheme.accent)
                    .scaleEffect(isHeartGlowing ? 1.12 : 0.92)
                    .opacity(isHeartGlowing ? 1 : 0.62)
                    .shadow(color: ShaudiTheme.accent.opacity(0.8), radius: 10)
                    .padding(.top, 6)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                isHeartGlowing = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shaudi. Made with all my love, for you.")
    }
}
