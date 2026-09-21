//
//  TrackPersistence.swift
//  Shaudi
//

import Foundation
import SwiftData

enum TrackPersistenceError: LocalizedError {
    case invalidVideoID
    case duplicatePlaylistMembership
    case missingSource
    case saveFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidVideoID: "Invalid video ID."
        case .duplicatePlaylistMembership: "Song is already in this playlist."
        case .missingSource: "No track information provided."
        case .saveFailed(let error): "Failed to save: \(error.localizedDescription)"
        }
    }
}

@MainActor
enum TrackPersistence {
    // Replaced by deterministic tests to exercise the production action.
    static var saveOverride: ((ModelContext) throws -> Void)?

    static func transientTrack(for recommendation: ResolvedRecommendation) -> Track {
        let videoID = recommendation.youtubeResult.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: "https://www.youtube.com/watch")!
        components.queryItems = [URLQueryItem(name: "v", value: videoID)]
        let url = components.url!
        return Track(
            title: recommendation.title, youtubeURL: url, youtubeVideoID: videoID,
            channelTitle: recommendation.artist, thumbnailURL: recommendation.youtubeResult.thumbnailURL,
            duration: recommendation.youtubeResult.duration, metadataLastRefreshed: .now,
            authoritativeRecommendationTitle: recommendation.songIdentity.title,
            authoritativeRecommendationArtist: recommendation.songIdentity.artist
        )
    }

    static func findExistingTrack(
        videoID: String, in modelContext: ModelContext, existingLibraryTracks: [Track]? = nil
    ) throws -> Track? {
        let normalized = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if let match = existingLibraryTracks?.first(where: {
            $0.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
        }) { return match }
        return try modelContext.fetch(FetchDescriptor<Track>()).first {
            $0.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
        }
    }

    @discardableResult
    static func promoteOrReuse(
        track: Track, in modelContext: ModelContext, targetPlaylist: Playlist? = nil,
        existingLibraryTracks: [Track]? = nil
    ) throws -> Track {
        let videoID = track.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !videoID.isEmpty else { throw TrackPersistenceError.invalidVideoID }
        if let targetPlaylist, targetPlaylist.tracks.contains(where: {
            $0.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines) == videoID
        }) { throw TrackPersistenceError.duplicatePlaylistMembership }

        let existing = try findExistingTrack(
            videoID: videoID, in: modelContext, existingLibraryTracks: existingLibraryTracks
        )
        let persisted: Track
        let newlyInserted: Bool
        if let existing {
            persisted = existing
            newlyInserted = false
        } else if track.modelContext === modelContext {
            persisted = track
            newlyInserted = false
        } else {
            // Keep the transient source intact so the picker can retry after a failed save.
            persisted = copy(track)
            modelContext.insert(persisted)
            newlyInserted = true
        }

        // Existing user edits win. Restore enrichment if saving fails.
        let oldIdentity = (persisted.authoritativeRecommendationTitle, persisted.authoritativeRecommendationArtist)
        let oldOverride = persisted.userArtistOverride
        let oldTrim = (persisted.playbackStartTime, persisted.playbackEndTime)
        let oldCover = persisted.customCoverID
        if persisted !== track {
            if let identity = track.persistedAuthoritativeRecommendationIdentity {
                persisted.preserveAuthoritativeRecommendationIdentity(identity)
            }
            if persisted.userArtistOverride == nil { persisted.userArtistOverride = track.userArtistOverride }
            if persisted.playbackStartTime == nil { persisted.playbackStartTime = track.playbackStartTime }
            if persisted.playbackEndTime == nil { persisted.playbackEndTime = track.playbackEndTime }
            if persisted.customCoverID == nil { persisted.customCoverID = track.customCoverID }
        }
        if let targetPlaylist { targetPlaylist.tracks.append(persisted) }

        do {
            try saveOverride?(modelContext)
            try modelContext.save()
            return persisted
        } catch {
            #if DEBUG
            print("[TrackPersistence] Save failed: \(error)")
            #endif
            if let targetPlaylist { targetPlaylist.tracks.removeAll { $0 === persisted } }
            if newlyInserted {
                modelContext.delete(persisted)
            } else {
                persisted.authoritativeRecommendationTitle = oldIdentity.0
                persisted.authoritativeRecommendationArtist = oldIdentity.1
                persisted.userArtistOverride = oldOverride
                persisted.playbackStartTime = oldTrim.0
                persisted.playbackEndTime = oldTrim.1
                persisted.customCoverID = oldCover
            }
            throw TrackPersistenceError.saveFailed(error)
        }
    }

    @discardableResult
    static func promoteOrReuse(
        recommendation: ResolvedRecommendation, in modelContext: ModelContext,
        targetPlaylist: Playlist? = nil, existingLibraryTracks: [Track]? = nil
    ) throws -> Track {
        try promoteOrReuse(
            track: transientTrack(for: recommendation), in: modelContext,
            targetPlaylist: targetPlaylist, existingLibraryTracks: existingLibraryTracks
        )
    }

    @discardableResult
    static func promoteOrReuse(
        playableTrack: PlayableTrack, in modelContext: ModelContext,
        targetPlaylist: Playlist? = nil, existingLibraryTracks: [Track]? = nil
    ) throws -> Track {
        let videoID = playableTrack.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !videoID.isEmpty,
              let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)")
        else { throw TrackPersistenceError.invalidVideoID }
        let track = Track(
            title: playableTrack.title, youtubeURL: url, youtubeVideoID: videoID,
            channelTitle: playableTrack.channelTitle, thumbnailURL: playableTrack.thumbnailURL,
            duration: playableTrack.duration, metadataLastRefreshed: .now,
            playbackStartTime: playableTrack.playbackStartTime,
            playbackEndTime: playableTrack.playbackEndTime
        )
        return try promoteOrReuse(
            track: track, in: modelContext, targetPlaylist: targetPlaylist,
            existingLibraryTracks: existingLibraryTracks
        )
    }

    @discardableResult
    static func promoteOrReuse(
        transientTrack: Track?, playableTrack: PlayableTrack?, in modelContext: ModelContext,
        targetPlaylist: Playlist? = nil, existingLibraryTracks: [Track]? = nil
    ) throws -> Track {
        if let transientTrack {
            return try promoteOrReuse(
                track: transientTrack, in: modelContext, targetPlaylist: targetPlaylist,
                existingLibraryTracks: existingLibraryTracks
            )
        }
        if let playableTrack {
            return try promoteOrReuse(
                playableTrack: playableTrack, in: modelContext, targetPlaylist: targetPlaylist,
                existingLibraryTracks: existingLibraryTracks
            )
        }
        throw TrackPersistenceError.missingSource
    }

    private static func copy(_ track: Track) -> Track {
        let copy = Track(
            title: track.title, youtubeURL: track.youtubeURL,
            youtubeVideoID: track.youtubeVideoID, dateAdded: track.dateAdded,
            channelTitle: track.channelTitle, userArtistOverride: track.userArtistOverride,
            thumbnailURL: track.thumbnailURL, duration: track.duration,
            metadataLastRefreshed: track.metadataLastRefreshed, playCount: track.playCount,
            totalListenedDuration: track.totalListenedDuration, lastPlayedAt: track.lastPlayedAt,
            playbackStartTime: track.playbackStartTime, playbackEndTime: track.playbackEndTime,
            customCoverID: track.customCoverID,
            authoritativeRecommendationTitle: track.authoritativeRecommendationTitle,
            authoritativeRecommendationArtist: track.authoritativeRecommendationArtist
        )
        copy.genreTagsStorage = track.genreTagsStorage
        copy.genreTagsFetchedAt = track.genreTagsFetchedAt
        copy.genreTagsLastAttemptAt = track.genreTagsLastAttemptAt
        return copy
    }
}
