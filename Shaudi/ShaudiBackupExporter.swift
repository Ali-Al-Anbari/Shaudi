import Foundation
import SwiftData

struct ShaudiBackupRow {
    let playlist: String
    let song: String
    let artist: String
    let youtubeVideoID: String

    nonisolated var youtubeURL: String {
        youtubeVideoID.isEmpty ? "" : "https://www.youtube.com/watch?v=\(youtubeVideoID)"
    }

    fileprivate nonisolated var csvLine: String {
        [playlist, song, artist, youtubeVideoID, youtubeURL]
            .map(Self.escapeCSVField)
            .joined(separator: ",")
    }

    private nonisolated static func escapeCSVField(_ value: String) -> String {
        let charactersNeedingQuotes = CharacterSet(charactersIn: ",\"\r\n")
        guard value.unicodeScalars.contains(where: charactersNeedingQuotes.contains) else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

enum ShaudiBackupSelection {
    case playlist(Playlist)
    case playlists([Playlist])
    case fullBackup
}

struct ShaudiBackupSkippedTrack {
    let title: String
    let youtubeVideoID: String
    let reason: String
}

struct ShaudiBackupExportResult {
    let csvData: Data
    let exportedRowCount: Int
    let exportedSongCount: Int
    let skippedTracks: [ShaudiBackupSkippedTrack]
    let suggestedFilename: String

    var skippedTrackCount: Int { skippedTracks.count }
}

enum ShaudiBackupExportError: Error {
    case noValidRows(skippedTracks: [ShaudiBackupSkippedTrack])
}

enum ShaudiBackupExporter {
    static func export(
        _ selection: ShaudiBackupSelection,
        allPlaylists: [Playlist] = [],
        libraryTracks: [Track] = [],
        date: Date = .now
    ) throws -> ShaudiBackupExportResult {
        let selectedPlaylists: [Playlist]
        switch selection {
        case .playlist(let playlist):
            selectedPlaylists = [playlist]
        case .playlists(let playlists):
            selectedPlaylists = playlists
        case .fullBackup:
            selectedPlaylists = allPlaylists.sorted {
                if $0.dateCreated != $1.dateCreated { return $0.dateCreated > $1.dateCreated }
                if $0.name != $1.name { return $0.name < $1.name }
                return String(describing: $0.persistentModelID) < String(describing: $1.persistentModelID)
            }
        }

        var rows: [ShaudiBackupRow] = []
        var validRowCount = 0
        var skipped: [ShaudiBackupSkippedTrack] = []
        var seenInvalidTracks = Set<ObjectIdentifier>()
        var representedVideoIDs = Set<String>()
        var playlistTrackObjects = Set<ObjectIdentifier>()
        var seenPlaylists = Set<ObjectIdentifier>()

        func append(_ track: Track, playlistName: String) {
            let videoID = track.youtubeVideoID
            guard YouTubeURLParser.isUsableVideoID(videoID) else {
                if seenInvalidTracks.insert(ObjectIdentifier(track)).inserted {
                    skipped.append(ShaudiBackupSkippedTrack(
                        title: track.title,
                        youtubeVideoID: videoID,
                        reason: videoID.isEmpty ? "Missing YouTube video ID" : "Invalid YouTube video ID"
                    ))
                }
                return
            }

            let artist = (track.userArtistOverride.flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            } ?? track.channelTitle).flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            } ?? ""
            rows.append(ShaudiBackupRow(
                playlist: playlistName,
                song: track.title,
                artist: artist,
                youtubeVideoID: videoID
            ))
            validRowCount += 1
            representedVideoIDs.insert(videoID)
        }

        for playlist in selectedPlaylists where seenPlaylists.insert(ObjectIdentifier(playlist)).inserted {
            let startingRowCount = rows.count
            var seenMemberships = Set<String>()
            for track in playlist.tracksInPlaybackOrder {
                playlistTrackObjects.insert(ObjectIdentifier(track))
                // Invalid tracks still reach append so they appear in the warning list.
                if YouTubeURLParser.isUsableVideoID(track.youtubeVideoID),
                   !seenMemberships.insert(track.youtubeVideoID).inserted {
                    continue
                }
                append(track, playlistName: playlist.name)
            }
            // An empty row preserves an empty playlist in the same five-column format.
            if rows.count == startingRowCount {
                rows.append(ShaudiBackupRow(
                    playlist: playlist.name, song: "", artist: "", youtubeVideoID: ""
                ))
            }
        }

        if case .fullBackup = selection {
            let sortedLibrary = libraryTracks.sorted {
                if $0.title != $1.title { return $0.title < $1.title }
                if $0.youtubeVideoID != $1.youtubeVideoID {
                    return $0.youtubeVideoID < $1.youtubeVideoID
                }
                if $0.dateAdded != $1.dateAdded { return $0.dateAdded < $1.dateAdded }
                return ($0.userArtistOverride ?? $0.channelTitle ?? "")
                    < ($1.userArtistOverride ?? $1.channelTitle ?? "")
            }
            for track in sortedLibrary {
                guard !playlistTrackObjects.contains(ObjectIdentifier(track)) else { continue }
                if YouTubeURLParser.isUsableVideoID(track.youtubeVideoID),
                   representedVideoIDs.contains(track.youtubeVideoID) {
                    continue
                }
                append(track, playlistName: "")
            }
        }

        if validRowCount == 0 && !skipped.isEmpty {
            throw ShaudiBackupExportError.noValidRows(skippedTracks: skipped)
        }

        let lines = ["Playlist,Song,Artist,YouTube Video ID,YouTube URL"] + rows.map(\.csvLine)
        let csvData = Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
        return ShaudiBackupExportResult(
            csvData: csvData,
            exportedRowCount: rows.count,
            exportedSongCount: validRowCount,
            skippedTracks: skipped,
            suggestedFilename: suggestedFilename(for: selection, date: date)
        )
    }

    static func suggestedFilename(for selection: ShaudiBackupSelection, date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        if case .playlist(let playlist) = selection {
            let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
            let name = String(playlist.name.unicodeScalars.map {
                invalid.contains($0) ? "-" : String($0)
            }.joined().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))))
            return "Shaudi - \(name.isEmpty ? "Playlist" : name) - \(day).csv"
        }
        return "Shaudi Backup \(day).csv"
    }
}
