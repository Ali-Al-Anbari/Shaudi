//
//  YouTubePlaylistImportModels.swift
//  Shaudi
//

import Foundation
import SwiftData

struct PendingYouTubePlaylistItem: Identifiable, Equatable, Hashable {
    let videoID: String
    let title: String
    let artist: String?
    let thumbnailURL: URL?
    let canonicalURL: URL
    let sourceOrder: Int

    var id: String { videoID }

    init(
        videoID: String,
        title: String,
        artist: String?,
        thumbnailURL: URL?,
        canonicalURL: URL? = nil,
        sourceOrder: Int
    ) {
        let normalizedID = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.videoID = normalizedID
        self.title = MusicMetadataText.decoded(title.trimmingCharacters(in: .whitespacesAndNewlines))
        let trimmedArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artist = (trimmedArtist?.isEmpty == false) ? MusicMetadataText.decoded(trimmedArtist!) : nil
        self.thumbnailURL = thumbnailURL
        self.canonicalURL = canonicalURL ?? URL(string: "https://www.youtube.com/watch?v=\(normalizedID)")!
        self.sourceOrder = sourceOrder
    }
}

struct ExtractedYouTubePlaylist: Equatable {
    let playlistID: String
    let title: String?
    let items: [PendingYouTubePlaylistItem]
    let unavailableSkippedCount: Int
    let duplicateSkippedCount: Int

    var totalDiscoveredCount: Int {
        items.count + unavailableSkippedCount + duplicateSkippedCount
    }
}

enum YouTubePlaylistDestination: Equatable {
    case libraryOnly
    case newPlaylist(name: String)
    case existingPlaylist(PersistentIdentifier)
}

struct YouTubePlaylistImportSummary: Equatable {
    let selectedSongCount: Int
    let newSongsAddedCount: Int
    let existingSongsReusedCount: Int
    let playlistMembershipsAddedCount: Int
    let duplicateMembershipsSkippedCount: Int
    let unavailableVideosSkippedCount: Int
    let removedBeforeImportCount: Int
    let destinationTitle: String
    let isLibraryOnly: Bool
}
