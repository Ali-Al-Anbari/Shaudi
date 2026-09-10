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
    var playlists: [Playlist]

    init(
        title: String,
        youtubeURL: URL,
        youtubeVideoID: String,
        dateAdded: Date = .now,
        playlists: [Playlist] = []
    ) {
        self.title = title
        self.youtubeURL = youtubeURL
        self.youtubeVideoID = youtubeVideoID
        self.dateAdded = dateAdded
        self.playlists = playlists
    }
}

@Model
final class Playlist {
    var name: String
    var dateCreated: Date

    @Relationship(inverse: \Track.playlists)
    var tracks: [Track]

    init(
        name: String,
        dateCreated: Date = .now,
        tracks: [Track] = []
    ) {
        self.name = name
        self.dateCreated = dateCreated
        self.tracks = tracks
    }
}
