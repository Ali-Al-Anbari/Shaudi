//
//  Models.swift
//  Shaudi
//

import Foundation
import SwiftData

@Model
final class Track {
    var title: String
    var youtubeURL: URL
    var youtubeVideoID: String
    var dateAdded: Date
    var channelTitle: String?
    var thumbnailURL: URL?
    var duration: TimeInterval?
    var metadataLastRefreshed: Date?
    var playCount: Int = 0
    var totalListenedDuration: TimeInterval = 0
    var lastPlayedAt: Date? = nil
    var playbackStartTime: Double? = nil
    var playbackEndTime: Double? = nil
    var customCoverID: UUID? = nil
    var playlists: [Playlist]

    init(
        title: String,
        youtubeURL: URL,
        youtubeVideoID: String,
        dateAdded: Date = .now,
        channelTitle: String? = nil,
        thumbnailURL: URL? = nil,
        duration: TimeInterval? = nil,
        metadataLastRefreshed: Date? = nil,
        playCount: Int = 0,
        totalListenedDuration: TimeInterval = 0,
        lastPlayedAt: Date? = nil,
        playbackStartTime: Double? = nil,
        playbackEndTime: Double? = nil,
        customCoverID: UUID? = nil,
        playlists: [Playlist] = []
    ) {
        self.title = title
        self.youtubeURL = youtubeURL
        self.youtubeVideoID = youtubeVideoID
        self.dateAdded = dateAdded
        self.channelTitle = channelTitle
        self.thumbnailURL = thumbnailURL
        self.duration = duration
        self.metadataLastRefreshed = metadataLastRefreshed
        self.playCount = playCount
        self.totalListenedDuration = totalListenedDuration
        self.lastPlayedAt = lastPlayedAt
        self.playbackStartTime = playbackStartTime
        self.playbackEndTime = playbackEndTime
        self.customCoverID = customCoverID
        self.playlists = playlists
    }
}

@Model
final class Playlist {
    var name: String
    var dateCreated: Date
    var lastPlayedAt: Date? = nil
    var artworkID: UUID? = nil

    @Relationship(inverse: \Track.playlists)
    var tracks: [Track]

    init(
        name: String,
        dateCreated: Date = .now,
        lastPlayedAt: Date? = nil,
        artworkID: UUID? = nil,
        tracks: [Track] = []
    ) {
        self.name = name
        self.dateCreated = dateCreated
        self.lastPlayedAt = lastPlayedAt
        self.artworkID = artworkID
        self.tracks = tracks
    }
}

extension Playlist {
    var tracksInPlaybackOrder: [Track] {
        tracks.sorted { first, second in
            if first.dateAdded != second.dateAdded {
                return first.dateAdded > second.dateAdded
            }

            if first.youtubeVideoID != second.youtubeVideoID {
                return first.youtubeVideoID < second.youtubeVideoID
            }

            return first.title.localizedStandardCompare(second.title) == .orderedAscending
        }
    }
}
