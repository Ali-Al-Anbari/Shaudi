//
//  ShaudiBackupImporter.swift
//  Shaudi
//

import Foundation
import SwiftData

struct ShaudiBackupImportWarning: Equatable, Sendable {
    let rowNumber: Int
    let playlistName: String
    let songTitle: String
    let youtubeVideoID: String
    let reason: String
}

struct ShaudiBackupImportItem: Equatable, Sendable {
    let rowNumber: Int
    let playlistName: String
    let songTitle: String
    let artist: String
    let youtubeVideoID: String
    let isPlaylistOnlyMarker: Bool
}

struct ShaudiBackupImportPreview: Sendable {
    let items: [ShaudiBackupImportItem]
    let warnings: [ShaudiBackupImportWarning]
    let playlistNames: [String]
    let emptyPlaylistNames: [String]
    let uniqueTrackVideoIDs: [String]
    let totalRowCount: Int
    let validSongRowCount: Int
    let emptyPlaylistRowCount: Int
    let invalidRowCount: Int
}

struct ShaudiBackupImportResult: Sendable {
    let importedTrackCount: Int
    let reusedTrackCount: Int
    let createdPlaylistCount: Int
    let reusedPlaylistCount: Int
    let addedMembershipCount: Int
    let skippedDuplicateMembershipCount: Int
    let skippedInvalidRowCount: Int
    let warnings: [ShaudiBackupImportWarning]
}

enum ShaudiBackupImportError: LocalizedError, Equatable {
    case invalidUTF8
    case invalidHeader
    case malformedCSV
    case noValidRows(warnings: [ShaudiBackupImportWarning])
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "The backup file is not valid UTF-8 text."
        case .invalidHeader:
            return "The backup file header is invalid."
        case .malformedCSV:
            return "The backup CSV file is malformed."
        case .noValidRows:
            return "The backup file contains no valid tracks or playlists to import."
        case .saveFailed(let message):
            return "Failed to save imported backup: \(message)"
        }
    }
}

enum ShaudiBackupCSVParser {
    static func parseRecords(_ csvText: String) throws -> [[String]] {
        var records: [[String]] = []
        var currentRecord: [String] = []
        var currentField = ""
        var inQuotes = false
        var fieldWasQuoted = false
        var index = csvText.startIndex

        while index < csvText.endIndex {
            let char = csvText[index]

            if inQuotes {
                if char == "\"" {
                    let nextIndex = csvText.index(after: index)
                    if nextIndex < csvText.endIndex && csvText[nextIndex] == "\"" {
                        currentField.append("\"")
                        index = nextIndex
                    } else {
                        inQuotes = false
                    }
                } else {
                    currentField.append(char)
                }
            } else {
                if char == "\"" {
                    if currentField.isEmpty && !fieldWasQuoted {
                        inQuotes = true
                        fieldWasQuoted = true
                    } else {
                        throw ShaudiBackupImportError.malformedCSV
                    }
                } else if char == "," {
                    currentRecord.append(currentField)
                    currentField = ""
                    fieldWasQuoted = false
                } else if char == "\r\n" || char == "\n" || char == "\r" {
                    currentRecord.append(currentField)
                    currentField = ""
                    fieldWasQuoted = false
                    records.append(currentRecord)
                    currentRecord = []
                } else {
                    if fieldWasQuoted && !char.isWhitespace {
                        throw ShaudiBackupImportError.malformedCSV
                    }
                    if !fieldWasQuoted {
                        currentField.append(char)
                    }
                }
            }

            index = csvText.index(after: index)
        }

        if inQuotes {
            throw ShaudiBackupImportError.malformedCSV
        }

        if !currentField.isEmpty || !currentRecord.isEmpty || fieldWasQuoted {
            currentRecord.append(currentField)
            records.append(currentRecord)
        }

        return records
    }
}

@MainActor
enum ShaudiBackupImporter {
    // Testing hook to simulate persistence failures
    static var saveOverride: ((ModelContext) throws -> Void)?

    static func preview(data: Data) throws -> ShaudiBackupImportPreview {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ShaudiBackupImportError.invalidUTF8
        }
        return try preview(csvString: text)
    }

    static func preview(csvString: String) throws -> ShaudiBackupImportPreview {
        var text = csvString
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        let records = try ShaudiBackupCSVParser.parseRecords(text)
        let expectedHeader = ["Playlist", "Song", "Artist", "YouTube Video ID", "YouTube URL"]
        guard let headerRow = records.first, headerRow == expectedHeader else {
            throw ShaudiBackupImportError.invalidHeader
        }

        var items: [ShaudiBackupImportItem] = []
        var warnings: [ShaudiBackupImportWarning] = []
        var validSongCount = 0
        var emptyPlaylistCount = 0

        for (index, row) in records.dropFirst().enumerated() {
            let rowNumber = index + 2
            if row.count != 5 {
                if row.count == 1 && row[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
                warnings.append(ShaudiBackupImportWarning(
                    rowNumber: rowNumber,
                    playlistName: row.first ?? "",
                    songTitle: "",
                    youtubeVideoID: "",
                    reason: "Row has \(row.count) columns (expected 5)"
                ))
                continue
            }

            let playlist = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let song = row[1]
            let artist = row[2]
            let videoID = row[3].trimmingCharacters(in: .whitespacesAndNewlines)
            let url = row[4].trimmingCharacters(in: .whitespacesAndNewlines)

            if playlist.isEmpty
                && song.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && videoID.isEmpty
                && url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            if !playlist.isEmpty
                && song.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && videoID.isEmpty {
                items.append(ShaudiBackupImportItem(
                    rowNumber: rowNumber,
                    playlistName: playlist,
                    songTitle: "",
                    artist: "",
                    youtubeVideoID: "",
                    isPlaylistOnlyMarker: true
                ))
                emptyPlaylistCount += 1
                continue
            }

            if videoID.isEmpty {
                warnings.append(ShaudiBackupImportWarning(
                    rowNumber: rowNumber,
                    playlistName: playlist,
                    songTitle: song,
                    youtubeVideoID: "",
                    reason: "Missing YouTube video ID"
                ))
                continue
            }

            guard YouTubeURLParser.isUsableVideoID(videoID) else {
                warnings.append(ShaudiBackupImportWarning(
                    rowNumber: rowNumber,
                    playlistName: playlist,
                    songTitle: song,
                    youtubeVideoID: videoID,
                    reason: "Invalid YouTube video ID"
                ))
                continue
            }

            items.append(ShaudiBackupImportItem(
                rowNumber: rowNumber,
                playlistName: playlist,
                songTitle: song,
                artist: artist,
                youtubeVideoID: videoID,
                isPlaylistOnlyMarker: false
            ))
            validSongCount += 1
        }

        if items.isEmpty {
            throw ShaudiBackupImportError.noValidRows(warnings: warnings)
        }

        var seenPlaylistNames = Set<String>()
        var playlistNames: [String] = []
        var playlistsWithTracks = Set<String>()
        for item in items where !item.playlistName.isEmpty {
            if seenPlaylistNames.insert(item.playlistName).inserted {
                playlistNames.append(item.playlistName)
            }
            if !item.isPlaylistOnlyMarker {
                playlistsWithTracks.insert(item.playlistName)
            }
        }

        let emptyPlaylistNames = playlistNames.filter { !playlistsWithTracks.contains($0) }

        var seenVideoIDs = Set<String>()
        var uniqueVideoIDs: [String] = []
        for item in items where !item.isPlaylistOnlyMarker {
            if seenVideoIDs.insert(item.youtubeVideoID).inserted {
                uniqueVideoIDs.append(item.youtubeVideoID)
            }
        }

        return ShaudiBackupImportPreview(
            items: items,
            warnings: warnings,
            playlistNames: playlistNames,
            emptyPlaylistNames: emptyPlaylistNames,
            uniqueTrackVideoIDs: uniqueVideoIDs,
            totalRowCount: max(0, records.count - 1),
            validSongRowCount: validSongCount,
            emptyPlaylistRowCount: emptyPlaylistCount,
            invalidRowCount: warnings.count
        )
    }

    @discardableResult
    static func apply(
        _ preview: ShaudiBackupImportPreview,
        in modelContext: ModelContext,
        baseDate: Date = .now
    ) throws -> ShaudiBackupImportResult {
        let existingTracks = try modelContext.fetch(FetchDescriptor<Track>())
        var trackByVideoID: [String: Track] = [:]
        for track in existingTracks {
            let id = track.youtubeVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty && trackByVideoID[id] == nil {
                trackByVideoID[id] = track
            }
        }

        let existingPlaylists = try modelContext.fetch(FetchDescriptor<Playlist>())
        var playlistByName: [String: Playlist] = [:]
        for playlist in existingPlaylists {
            if playlistByName[playlist.name] == nil {
                playlistByName[playlist.name] = playlist
            }
        }

        var newlyCreatedTracks: [Track] = []
        var newlyCreatedPlaylists: [Playlist] = []
        var addedMemberships: [(playlist: Playlist, track: Track)] = []
        var modifiedTrackOldState: [(track: Track, oldTitle: String, oldChannelTitle: String?, oldUserOverride: String?)] = []

        var seenReusedTrackIDs = Set<String>()
        var seenCreatedTrackIDs = Set<String>()
        var seenReusedPlaylistNames = Set<String>()
        var seenCreatedPlaylistNames = Set<String>()
        var addedMembershipCount = 0
        var skippedDuplicateMembershipCount = 0

        for (index, item) in preview.items.enumerated() {
            if !item.playlistName.isEmpty {
                if playlistByName[item.playlistName] == nil {
                    let newPlaylist = Playlist(name: item.playlistName, dateCreated: baseDate)
                    modelContext.insert(newPlaylist)
                    playlistByName[item.playlistName] = newPlaylist
                    newlyCreatedPlaylists.append(newPlaylist)
                    seenCreatedPlaylistNames.insert(item.playlistName)
                } else if !seenCreatedPlaylistNames.contains(item.playlistName) {
                    seenReusedPlaylistNames.insert(item.playlistName)
                }
            }

            if item.isPlaylistOnlyMarker {
                continue
            }

            let videoID = item.youtubeVideoID
            let targetTrack: Track

            if let existing = trackByVideoID[videoID] {
                targetTrack = existing
                if !seenCreatedTrackIDs.contains(videoID) {
                    seenReusedTrackIDs.insert(videoID)
                }

                var modified = false
                let oldTitle = targetTrack.title
                let oldChannel = targetTrack.channelTitle
                let oldOverride = targetTrack.userArtistOverride

                if targetTrack.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !item.songTitle.isEmpty {
                    targetTrack.title = item.songTitle
                    modified = true
                }
                let trimmedArtist = item.artist.trimmingCharacters(in: .whitespacesAndNewlines)
                if (targetTrack.channelTitle == nil || targetTrack.channelTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
                    && (targetTrack.userArtistOverride == nil || targetTrack.userArtistOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
                    && !trimmedArtist.isEmpty {
                    targetTrack.channelTitle = trimmedArtist
                    modified = true
                }

                if modified {
                    modifiedTrackOldState.append((track: targetTrack, oldTitle: oldTitle, oldChannelTitle: oldChannel, oldUserOverride: oldOverride))
                }
            } else {
                let canonicalURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
                let trimmedSong = item.songTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedArtist = item.artist.trimmingCharacters(in: .whitespacesAndNewlines)
                let dateAdded = baseDate.addingTimeInterval(Double(preview.items.count - index))
                let newTrack = Track(
                    title: trimmedSong.isEmpty ? "Untitled" : trimmedSong,
                    youtubeURL: canonicalURL,
                    youtubeVideoID: videoID,
                    dateAdded: dateAdded,
                    channelTitle: trimmedArtist.isEmpty ? nil : trimmedArtist
                )
                modelContext.insert(newTrack)
                trackByVideoID[videoID] = newTrack
                newlyCreatedTracks.append(newTrack)
                seenCreatedTrackIDs.insert(videoID)
                targetTrack = newTrack
            }

            if !item.playlistName.isEmpty, let playlist = playlistByName[item.playlistName] {
                if playlist.tracks.contains(where: { $0.youtubeVideoID == videoID }) {
                    skippedDuplicateMembershipCount += 1
                } else {
                    playlist.tracks.append(targetTrack)
                    addedMemberships.append((playlist: playlist, track: targetTrack))
                    addedMembershipCount += 1
                }
            }
        }

        do {
            try saveOverride?(modelContext)
            try modelContext.save()
            return ShaudiBackupImportResult(
                importedTrackCount: seenCreatedTrackIDs.count,
                reusedTrackCount: seenReusedTrackIDs.count,
                createdPlaylistCount: seenCreatedPlaylistNames.count,
                reusedPlaylistCount: seenReusedPlaylistNames.count,
                addedMembershipCount: addedMembershipCount,
                skippedDuplicateMembershipCount: skippedDuplicateMembershipCount,
                skippedInvalidRowCount: preview.invalidRowCount,
                warnings: preview.warnings
            )
        } catch {
            for (playlist, track) in addedMemberships {
                playlist.tracks.removeAll { $0 === track }
            }
            for (track, oldTitle, oldChannel, oldOverride) in modifiedTrackOldState {
                track.title = oldTitle
                track.channelTitle = oldChannel
                track.userArtistOverride = oldOverride
            }
            for playlist in newlyCreatedPlaylists {
                modelContext.delete(playlist)
            }
            for track in newlyCreatedTracks {
                modelContext.delete(track)
            }
            try? modelContext.save()
            throw ShaudiBackupImportError.saveFailed(error.localizedDescription)
        }
    }

    @discardableResult
    static func `import`(
        data: Data,
        in modelContext: ModelContext,
        baseDate: Date = .now
    ) throws -> ShaudiBackupImportResult {
        let preview = try preview(data: data)
        return try apply(preview, in: modelContext, baseDate: baseDate)
    }
}
