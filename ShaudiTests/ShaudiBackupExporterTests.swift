import Foundation
import XCTest
@testable import Shaudi

final class ShaudiBackupExporterTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_789_992_000)

    private func track(
        _ id: String,
        title: String = "Song",
        artist: String? = "Artist",
        added: TimeInterval = 0,
        storedURL: String = "https://example.com/stale"
    ) -> Track {
        Track(
            title: title,
            youtubeURL: URL(string: storedURL)!,
            youtubeVideoID: id,
            dateAdded: Date(timeIntervalSince1970: added),
            channelTitle: artist
        )
    }

    private func csv(_ result: ShaudiBackupExportResult) -> String {
        String(data: result.csvData, encoding: .utf8)!
    }

    private var header: String {
        "Playlist,Song,Artist,YouTube Video ID,YouTube URL\r\n"
    }

    private func row(_ playlist: String, _ title: String, _ artist: String, _ id: String) -> String {
        "\(playlist),\(title),\(artist),\(id),https://www.youtube.com/watch?v=\(id)\r\n"
    }

    func testSinglePlaylistExport() throws {
        let playlist = Playlist(name: "Road Trip", tracks: [track("abcdefghijk", title: "West Coast")])
        let result = try ShaudiBackupExporter.export(.playlist(playlist), date: date)
        XCTAssertEqual(csv(result), header + row("Road Trip", "West Coast", "Artist", "abcdefghijk"))
        XCTAssertEqual(result.exportedRowCount, 1)
        XCTAssertEqual(result.skippedTrackCount, 0)
    }

    func testMultiplePlaylistsKeepSuppliedOrder() throws {
        let first = Playlist(name: "First", tracks: [track("abcdefghijk")])
        let second = Playlist(name: "Second", tracks: [track("lmnopqrstuv")])
        let result = try ShaudiBackupExporter.export(.playlists([second, first]), date: date)
        XCTAssertEqual(csv(result), header + row("Second", "Song", "Artist", "lmnopqrstuv")
            + row("First", "Song", "Artist", "abcdefghijk"))
    }

    func testFullBackupIncludesPlaylistsAndLibraryOnlyTracks() throws {
        let member = track("abcdefghijk")
        let standalone = track("lmnopqrstuv", title: "Standalone")
        let playlist = Playlist(name: "Favorites", tracks: [member])
        let result = try ShaudiBackupExporter.export(
            .fullBackup, allPlaylists: [playlist], libraryTracks: [standalone, member], date: date
        )
        XCTAssertEqual(csv(result), header + row("Favorites", "Song", "Artist", "abcdefghijk")
            + row("", "Standalone", "Artist", "lmnopqrstuv"))
        XCTAssertEqual(result.exportedRowCount, 2)
    }

    func testEmptyPlaylistIsPreserved() throws {
        let result = try ShaudiBackupExporter.export(
            .fullBackup, allPlaylists: [Playlist(name: "Empty")], date: date
        )
        XCTAssertEqual(csv(result), header + "Empty,,,,\r\n")
        XCTAssertEqual(result.exportedRowCount, 1)
    }

    func testRealPlaylistNamedLibraryExportsSuccessfully() throws {
        let playlist = Playlist(name: "Library", tracks: [track("abcdefghijk", title: "My Library Track")])
        let result = try ShaudiBackupExporter.export(.playlist(playlist), date: date)
        XCTAssertEqual(csv(result), header + row("Library", "My Library Track", "Artist", "abcdefghijk"))
        XCTAssertEqual(result.exportedRowCount, 1)
    }

    func testLibraryOnlyRowsCannotBeConfusedWithPlaylistNamedLibrary() throws {
        let playlistTrack = track("abcdefghijk", title: "In Library Playlist")
        let libraryOnlyTrack = track("lmnopqrstuv", title: "Library Only")
        let playlist = Playlist(name: "Library", tracks: [playlistTrack])
        let result = try ShaudiBackupExporter.export(
            .fullBackup,
            allPlaylists: [playlist],
            libraryTracks: [playlistTrack, libraryOnlyTrack],
            date: date
        )
        XCTAssertEqual(
            csv(result),
            header + row("Library", "In Library Playlist", "Artist", "abcdefghijk")
                + row("", "Library Only", "Artist", "lmnopqrstuv")
        )
        XCTAssertEqual(result.exportedRowCount, 2)
    }

    func testEmptyPlaylistNamedLibraryPreservedDistinctly() throws {
        let emptyLibraryPlaylist = Playlist(name: "Library", tracks: [])
        let libraryOnlyTrack = track("lmnopqrstuv", title: "Standalone")
        let result = try ShaudiBackupExporter.export(
            .fullBackup,
            allPlaylists: [emptyLibraryPlaylist],
            libraryTracks: [libraryOnlyTrack],
            date: date
        )
        XCTAssertEqual(
            csv(result),
            header + "Library,,,,\r\n"
                + row("", "Standalone", "Artist", "lmnopqrstuv")
        )
        XCTAssertEqual(result.exportedRowCount, 2)
    }

    func testSameTrackInTwoPlaylistsProducesTwoMemberships() throws {
        let shared = track("abcdefghijk")
        let first = Playlist(name: "First", tracks: [shared])
        let second = Playlist(name: "Second", tracks: [shared])
        let result = try ShaudiBackupExporter.export(.playlists([first, second]), date: date)
        XCTAssertEqual(csv(result), header + row("First", "Song", "Artist", "abcdefghijk")
            + row("Second", "Song", "Artist", "abcdefghijk"))
    }

    func testLibraryOnlyTrackAppearsOncePerVideoID() throws {
        let first = track("abcdefghijk")
        let duplicate = track("abcdefghijk")
        let result = try ShaudiBackupExporter.export(
            .fullBackup, libraryTracks: [duplicate, first], date: date
        )
        XCTAssertEqual(result.exportedRowCount, 1)
        XCTAssertEqual(csv(result), header + row("", "Song", "Artist", "abcdefghijk"))
    }

    func testPlaylistVideoIDDoesNotGetLibraryOnlyRow() throws {
        let member = track("abcdefghijk")
        let duplicateLibraryObject = track("abcdefghijk", title: "Duplicate")
        let playlist = Playlist(name: "Favorites", tracks: [member])
        let result = try ShaudiBackupExporter.export(
            .fullBackup, allPlaylists: [playlist], libraryTracks: [duplicateLibraryObject], date: date
        )
        XCTAssertEqual(csv(result), header + row("Favorites", "Song", "Artist", "abcdefghijk"))
    }

    func testDuplicateMembershipSuppressedByVideoID() throws {
        let playlist = Playlist(name: "Favorites", tracks: [
            track("abcdefghijk"), track("abcdefghijk")
        ])
        let result = try ShaudiBackupExporter.export(.playlist(playlist), date: date)
        XCTAssertEqual(result.exportedRowCount, 1)
        XCTAssertEqual(csv(result), header + row("Favorites", "Song", "Artist", "abcdefghijk"))
    }

    func testInvalidAndMissingIDsAreSkippedWithWarnings() throws {
        let valid = track("abcdefghijk")
        let missing = track("", title: "Missing")
        let invalid = track("bad/id", title: "Invalid")
        let playlist = Playlist(name: "Favorites", tracks: [valid, missing, invalid])
        let result = try ShaudiBackupExporter.export(
            .fullBackup, allPlaylists: [playlist], libraryTracks: [valid, missing, invalid], date: date
        )
        XCTAssertEqual(result.exportedRowCount, 1)
        XCTAssertEqual(result.skippedTrackCount, 2)
        XCTAssertEqual(Set(result.skippedTracks.map(\.reason)),
                       ["Missing YouTube video ID", "Invalid YouTube video ID"])
        XCTAssertThrowsError(try ShaudiBackupExporter.export(.playlist(Playlist(name: "Bad", tracks: [missing])))) {
            guard case ShaudiBackupExportError.noValidRows(let skipped) = $0 else {
                return XCTFail("Expected noValidRows")
            }
            XCTAssertEqual(skipped.count, 1)
        }
    }

    func testCanonicalURLIgnoresStoredURL() throws {
        let result = try ShaudiBackupExporter.export(.playlist(Playlist(name: "P", tracks: [
            track("abcdefghijk", storedURL: "https://www.youtube.com/watch?v=wrongvideo1")
        ])))
        XCTAssertEqual(csv(result), header + row("P", "Song", "Artist", "abcdefghijk"))
    }

    func testCommasAreQuoted() throws {
        let result = try ShaudiBackupExporter.export(.playlist(Playlist(name: "A,B", tracks: [
            track("abcdefghijk", title: "One, Two", artist: "A, B")
        ])))
        XCTAssertEqual(csv(result), header + row("\"A,B\"", "\"One, Two\"", "\"A, B\"", "abcdefghijk"))
    }

    func testQuotesAreDoubled() throws {
        let result = try ShaudiBackupExporter.export(.playlist(Playlist(name: "P", tracks: [
            track("abcdefghijk", title: "Say \"Hi\"", artist: "The \"Band\"")
        ])))
        XCTAssertEqual(csv(result), header + row("P", "\"Say \"\"Hi\"\"\"", "\"The \"\"Band\"\"\"", "abcdefghijk"))
    }

    func testNewlinesAreQuoted() throws {
        let result = try ShaudiBackupExporter.export(.playlist(Playlist(name: "P", tracks: [
            track("abcdefghijk", title: "Line\nTwo", artist: "A\r\nB")
        ])))
        XCTAssertEqual(csv(result), header + row("P", "\"Line\nTwo\"", "\"A\r\nB\"", "abcdefghijk"))
    }

    func testUnicodeAndEmptyArtistPreserved() throws {
        let playlist = Playlist(name: "日本語", tracks: [
            track("abcdefghijk", title: "Café ☕️", artist: "Björk"),
            track("lmnopqrstuv", title: "無題", artist: nil)
        ])
        let result = try ShaudiBackupExporter.export(.playlist(playlist))
        XCTAssertEqual(csv(result), header + row("日本語", "Café ☕️", "Björk", "abcdefghijk")
            + row("日本語", "無題", "", "lmnopqrstuv"))
    }

    func testDeterministicOrdering() throws {
        let newer = track("lmnopqrstuv", title: "Z", added: 20)
        let older = track("abcdefghijk", title: "A", added: 10)
        let first = Playlist(name: "First", dateCreated: Date(timeIntervalSince1970: 20), tracks: [older, newer])
        let second = Playlist(name: "Second", dateCreated: Date(timeIntervalSince1970: 10), tracks: [older])
        let library = track("zxywvutsrqp", title: "Library")
        let result = try ShaudiBackupExporter.export(
            .fullBackup, allPlaylists: [second, first], libraryTracks: [library, older, newer]
        )
        XCTAssertEqual(csv(result), header + row("First", "Z", "Artist", "lmnopqrstuv")
            + row("First", "A", "Artist", "abcdefghijk")
            + row("Second", "A", "Artist", "abcdefghijk")
            + row("", "Library", "Artist", "zxywvutsrqp"))
    }

    func testCSVDataIsValidUTF8() throws {
        let result = try ShaudiBackupExporter.export(.playlist(Playlist(name: "P", tracks: [
            track("abcdefghijk", title: "🎵")
        ])))
        XCTAssertNotNil(String(data: result.csvData, encoding: .utf8))
        XCTAssertEqual(result.csvData, Data(csv(result).utf8))
    }

    func testFilenameSanitization() {
        let playlist = Playlist(name: " /Road:Trip?*\\\"<>|. ")
        let filename = ShaudiBackupExporter.suggestedFilename(for: .playlist(playlist), date: date)
        XCTAssertTrue(filename.hasPrefix("Shaudi - "))
        XCTAssertTrue(filename.hasSuffix(".csv"))
        XCTAssertFalse(filename.contains("/"))
        XCTAssertFalse(filename.contains(":"))
        XCTAssertFalse(filename.contains("?"))
        XCTAssertFalse(filename.contains("*"))
        XCTAssertFalse(filename.contains("\\"))
        XCTAssertFalse(filename.contains("\""))
        XCTAssertEqual(ShaudiBackupExporter.suggestedFilename(for: .fullBackup, date: date),
                       "Shaudi Backup 2026-09-21.csv")
    }
}
