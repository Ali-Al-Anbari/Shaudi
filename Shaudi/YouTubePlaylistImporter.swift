//
//  YouTubePlaylistImporter.swift
//  Shaudi
//

import Foundation
import SwiftData

enum YouTubePlaylistImporterError: LocalizedError, Equatable {
    case noSongsSelected
    case playlistNotFound
    case emptyPlaylistName
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSongsSelected:
            return "At least one song must be selected for import."
        case .playlistNotFound:
            return "The selected Shaudi playlist could not be found."
        case .emptyPlaylistName:
            return "Please enter a name for the new playlist."
        case .saveFailed(let message):
            return "Could not save songs to Shaudi: \(message)"
        }
    }
}

@MainActor
enum YouTubePlaylistImporter {
    // Replaced by deterministic unit tests to exercise save failure / rollback.
    static var saveOverride: ((ModelContext) throws -> Void)?

    static func apply(
        items: [PendingYouTubePlaylistItem],
        originalFetchedCount: Int,
        unavailableSkippedCount: Int,
        destination: YouTubePlaylistDestination,
        in modelContext: ModelContext,
        baseDate: Date = .now
    ) throws -> YouTubePlaylistImportSummary {
        guard !items.isEmpty else {
            throw YouTubePlaylistImporterError.noSongsSelected
        }

        let removedBeforeImportCount = max(0, originalFetchedCount - items.count)

        // 1. Resolve destination
        let targetPlaylist: Playlist?
        let destinationTitle: String
        let isLibraryOnly: Bool
        var newlyCreatedPlaylist: Playlist? = nil

        switch destination {
        case .libraryOnly:
            targetPlaylist = nil
            destinationTitle = "Library"
            isLibraryOnly = true

        case .newPlaylist(let name):
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw YouTubePlaylistImporterError.emptyPlaylistName
            }
            let newPlaylist = Playlist(name: trimmedName, dateCreated: baseDate)
            modelContext.insert(newPlaylist)
            newlyCreatedPlaylist = newPlaylist
            targetPlaylist = newPlaylist
            destinationTitle = trimmedName
            isLibraryOnly = false

        case .existingPlaylist(let playlistID):
            let allPlaylists = try modelContext.fetch(FetchDescriptor<Playlist>())
            guard let found = allPlaylists.first(where: { $0.persistentModelID == playlistID }) else {
                throw YouTubePlaylistImporterError.playlistNotFound
            }
            targetPlaylist = found
            destinationTitle = found.name
            isLibraryOnly = false
        }

        // 2. Fetch existing library tracks for deduplication
        let existingLibraryTracks = try modelContext.fetch(FetchDescriptor<Track>())
        var trackByVideoID: [String: Track] = [:]
        for track in existingLibraryTracks {
            let id = track.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty && trackByVideoID[id] == nil {
                trackByVideoID[id] = track
            }
        }

        var newlyInsertedTracks: [Track] = []
        var modifiedTracksRollback: [(track: Track, oldChannel: String?, oldThumbnail: URL?)] = []
        var addedMemberships: [(playlist: Playlist, track: Track)] = []

        var newSongsAddedCount = 0
        var existingSongsReusedCount = 0
        var playlistMembershipsAddedCount = 0
        var duplicateMembershipsSkippedCount = 0

        for (index, item) in items.enumerated() {
            let videoID = item.videoID
            let resolvedTrack: Track

            if let existing = trackByVideoID[videoID] {
                resolvedTrack = existing
                existingSongsReusedCount += 1

                // Fill safe missing fields without overwriting user edits or nonempty data
                var didModify = false
                let oldChannel = existing.channelTitle
                let oldThumbnail = existing.thumbnailURL

                if (existing.channelTitle == nil || existing.channelTitle?.isEmpty == true)
                    && (existing.userArtistOverride == nil || existing.userArtistOverride?.isEmpty == true),
                   let newArtist = item.artist, !newArtist.isEmpty {
                    existing.channelTitle = newArtist
                    didModify = true
                }

                if existing.thumbnailURL == nil, let newThumbnail = item.thumbnailURL {
                    existing.thumbnailURL = newThumbnail
                    didModify = true
                }

                if didModify {
                    modifiedTracksRollback.append((track: existing, oldChannel: oldChannel, oldThumbnail: oldThumbnail))
                }
            } else {
                // Create new Track with dateAdded staggered to preserve source playlist order
                let dateAdded = baseDate.addingTimeInterval(Double(items.count - index))
                let newTrack = Track(
                    title: item.title,
                    youtubeURL: item.canonicalURL,
                    youtubeVideoID: videoID,
                    dateAdded: dateAdded,
                    channelTitle: item.artist,
                    thumbnailURL: item.thumbnailURL,
                    metadataLastRefreshed: .now
                )
                modelContext.insert(newTrack)
                newlyInsertedTracks.append(newTrack)
                trackByVideoID[videoID] = newTrack
                resolvedTrack = newTrack
                newSongsAddedCount += 1
            }

            // Playlist membership handling
            if let targetPlaylist {
                let alreadyInPlaylist = targetPlaylist.tracks.contains {
                    $0.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines) == videoID
                }
                if alreadyInPlaylist {
                    duplicateMembershipsSkippedCount += 1
                } else {
                    targetPlaylist.tracks.append(resolvedTrack)
                    addedMemberships.append((playlist: targetPlaylist, track: resolvedTrack))
                    playlistMembershipsAddedCount += 1
                }
            }
        }

        // 3. Persist
        do {
            try saveOverride?(modelContext)
            try modelContext.save()
        } catch {
            // Roll back on failure
            for membership in addedMemberships {
                membership.playlist.tracks.removeAll { $0 === membership.track }
            }
            for track in newlyInsertedTracks {
                modelContext.delete(track)
            }
            if let newlyCreatedPlaylist {
                modelContext.delete(newlyCreatedPlaylist)
            }
            for rollback in modifiedTracksRollback {
                rollback.track.channelTitle = rollback.oldChannel
                rollback.track.thumbnailURL = rollback.oldThumbnail
            }
            try? modelContext.save()
            throw YouTubePlaylistImporterError.saveFailed(error.localizedDescription)
        }

        return YouTubePlaylistImportSummary(
            selectedSongCount: items.count,
            newSongsAddedCount: newSongsAddedCount,
            existingSongsReusedCount: existingSongsReusedCount,
            playlistMembershipsAddedCount: playlistMembershipsAddedCount,
            duplicateMembershipsSkippedCount: duplicateMembershipsSkippedCount,
            unavailableVideosSkippedCount: unavailableSkippedCount,
            removedBeforeImportCount: removedBeforeImportCount,
            destinationTitle: destinationTitle,
            isLibraryOnly: isLibraryOnly
        )
    }
}
