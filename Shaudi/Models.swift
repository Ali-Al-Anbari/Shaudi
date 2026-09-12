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
        self.playlists = playlists
    }
}

@Model
final class Playlist {
    var name: String
    var dateCreated: Date
    var lastPlayedAt: Date? = nil

    @Relationship(inverse: \Track.playlists)
    var tracks: [Track]

    init(
        name: String,
        dateCreated: Date = .now,
        lastPlayedAt: Date? = nil,
        tracks: [Track] = []
    ) {
        self.name = name
        self.dateCreated = dateCreated
        self.lastPlayedAt = lastPlayedAt
        self.tracks = tracks
    }
}
