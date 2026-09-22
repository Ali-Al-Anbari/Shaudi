//
//  ShaudiBackupImporterTests.swift
//  ShaudiTests
//

import Foundation
import SwiftData
import XCTest
@testable import Shaudi

@MainActor
final class ShaudiBackupImporterTests: XCTestCase {
    private enum SimulatedError: Error { case failure }

    private func context() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Track.self,
            Playlist.self
        ])

        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )

        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        return (container, container.mainContext)
    }

    private var header: String {
        "Playlist,Song,Artist,YouTube Video ID,YouTube URL\r\n"
    }

    override func tearDown() {
        super.tearDown()
        ShaudiBackupImporter.saveOverride = nil
    }

    func testLibraryOnlyImport() throws {
        let (_container, ctx) = try context()
        let csv = header + ",West Coast,Artist,abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
        let result = try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)

        XCTAssertEqual(result.importedTrackCount, 1)
        XCTAssertEqual(result.createdPlaylistCount, 0)
        XCTAssertEqual(result.addedMembershipCount, 0)
        XCTAssertEqual(result.skippedInvalidRowCount, 0)

        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.title, "West Coast")
        XCTAssertEqual(tracks.first?.channelTitle, "Artist")
        XCTAssertEqual(tracks.first?.youtubeVideoID, "abcdefghijk")
        XCTAssertEqual(tracks.first?.playlists.count, 0)
    }

    func testOnePlaylistImport() throws {
        let (_container, ctx) = try context()
        let csv = header + "Road Trip,West Coast,Artist,abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
        let result = try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)

        XCTAssertEqual(result.importedTrackCount, 1)
        XCTAssertEqual(result.createdPlaylistCount, 1)
        XCTAssertEqual(result.addedMembershipCount, 1)

        let playlists = try ctx.fetch(FetchDescriptor<Playlist>())
        XCTAssertEqual(playlists.count, 1)
        XCTAssertEqual(playlists.first?.name, "Road Trip")
        XCTAssertEqual(playlists.first?.tracks.count, 1)
        XCTAssertEqual(playlists.first?.tracks.first?.youtubeVideoID, "abcdefghijk")
    }

    func testMultiplePlaylistsImport() throws {
        let (_container, ctx) = try context()
        let csv = header
            + "Road Trip,West Coast,Artist,abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
            + "Favorites,Midnight City,M83,lmnopqrstuv,https://www.youtube.com/watch?v=lmnopqrstuv\r\n"
        let result = try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)

        XCTAssertEqual(result.importedTrackCount, 2)
        XCTAssertEqual(result.createdPlaylistCount, 2)
        XCTAssertEqual(result.addedMembershipCount, 2)

        let playlists = try ctx.fetch(FetchDescriptor<Playlist>())
        XCTAssertEqual(playlists.count, 2)
    }

    func testSameSongInMultiplePlaylists() throws {
        let (_container, ctx) = try context()
        let csv = header
            + "Road Trip,West Coast,Artist,abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
            + "Favorites,West Coast,Artist,abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
        let result = try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)

        XCTAssertEqual(result.importedTrackCount, 1)
        XCTAssertEqual(result.createdPlaylistCount, 2)
        XCTAssertEqual(result.addedMembershipCount, 2)

        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        XCTAssertEqual(tracks.count, 1)

        let playlists = try ctx.fetch(FetchDescriptor<Playlist>())
        XCTAssertEqual(playlists.count, 2)
        XCTAssertTrue(playlists.allSatisfy { $0.tracks.count == 1 && $0.tracks.first === tracks.first })
    }

    func testExistingTrackReuse() throws {
        let (_container, ctx) = try context()
        let existing = Track(
            title: "Original Title",
            youtubeURL: URL(string: "https://www.youtube.com/watch?v=abcdefghijk")!,
            youtubeVideoID: "abcdefghijk",
            channelTitle: "Original Artist"
        )
        ctx.insert(existing)
        try ctx.save()

        let csv = header + "Road Trip,Imported Title,Imported Artist,abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
        let result = try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)

        XCTAssertEqual(result.importedTrackCount, 0)
        XCTAssertEqual(result.reusedTrackCount, 1)
        XCTAssertEqual(result.createdPlaylistCount, 1)
        XCTAssertEqual(result.addedMembershipCount, 1)

        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.title, "Original Title")
        XCTAssertEqual(tracks.first?.channelTitle, "Original Artist")
    }

    func testExistingPlaylistReuse() throws {
        let (_container, ctx) = try context()
        let existingPlaylist = Playlist(name: "Road Trip")
        ctx.insert(existingPlaylist)
        try ctx.save()

        let csv = header + "Road Trip,West Coast,Artist,abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
        let result = try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)

        XCTAssertEqual(result.createdPlaylistCount, 0)
        XCTAssertEqual(result.reusedPlaylistCount, 1)
        XCTAssertEqual(result.importedTrackCount, 1)
        XCTAssertEqual(result.addedMembershipCount, 1)

        let playlists = try ctx.fetch(FetchDescriptor<Playlist>())
        XCTAssertEqual(playlists.count, 1)
        XCTAssertEqual(playlists.first?.tracks.count, 1)
    }

    func testDuplicateMembershipSkipped() throws {
        let (_container, ctx) = try context()
        let existingTrack = Track(
            title: "West Coast",
            youtubeURL: URL(string: "https://www.youtube.com/watch?v=abcdefghijk")!,
            youtubeVideoID: "abcdefghijk"
        )
        let existingPlaylist = Playlist(name: "Road Trip", tracks: [existingTrack])
        ctx.insert(existingTrack)
        ctx.insert(existingPlaylist)
        try ctx.save()

        let csv = header + "Road Trip,West Coast,Artist,abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
        let result = try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)

        XCTAssertEqual(result.skippedDuplicateMembershipCount, 1)
        XCTAssertEqual(result.addedMembershipCount, 0)
        XCTAssertEqual(result.reusedTrackCount, 1)
        XCTAssertEqual(result.reusedPlaylistCount, 1)
    }

    func testEmptyPlaylistRestored() throws {
        let (_container, ctx) = try context()
        let csv = header + "Empty Road Trip,,,,\r\n"
        let result = try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)

        XCTAssertEqual(result.createdPlaylistCount, 1)
        XCTAssertEqual(result.importedTrackCount, 0)
        XCTAssertEqual(result.addedMembershipCount, 0)

        let playlists = try ctx.fetch(FetchDescriptor<Playlist>())
        XCTAssertEqual(playlists.count, 1)
        XCTAssertEqual(playlists.first?.name, "Empty Road Trip")
        XCTAssertEqual(playlists.first?.tracks.count, 0)
    }

    func testRealPlaylistNamedLibraryRestoredCorrectly() throws {
        let (_container, ctx) = try context()
        let csv = header
            + "Library,West Coast,Artist,abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
            + ",Standalone,Artist,lmnopqrstuv,https://www.youtube.com/watch?v=lmnopqrstuv\r\n"
        let result = try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)

        XCTAssertEqual(result.createdPlaylistCount, 1)
        XCTAssertEqual(result.importedTrackCount, 2)
        XCTAssertEqual(result.addedMembershipCount, 1)

        let playlists = try ctx.fetch(FetchDescriptor<Playlist>())
        XCTAssertEqual(playlists.count, 1)
        XCTAssertEqual(playlists.first?.name, "Library")
        XCTAssertEqual(playlists.first?.tracks.count, 1)
        XCTAssertEqual(playlists.first?.tracks.first?.youtubeVideoID, "abcdefghijk")
    }

    func testCanonicalURLReconstructedFromVideoID() throws {
        let (_container, ctx) = try context()
        let csv = header + "P,Song,Artist,abcdefghijk,https://example.com/arbitrary/wrong-url\r\n"
        try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)

        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        XCTAssertEqual(tracks.first?.youtubeURL, URL(string: "https://www.youtube.com/watch?v=abcdefghijk")!)
    }

    func testImportedURLIgnoredForIdentity() throws {
        let (_container, ctx) = try context()
        let csv = header + ",Song,Artist,abcdefghijk,https://example.com/stale-url\r\n"
        try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)

        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        XCTAssertEqual(tracks.first?.youtubeVideoID, "abcdefghijk")
    }

    func testInvalidVideoIDSkippedWithWarning() throws {
        let (_container, ctx) = try context()
        let csv = header
            + "P,Valid Song,Artist,abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
            + "P,Bad Song,Artist,bad/id,https://example.com\r\n"
            + "P,Missing Song,Artist,,https://example.com\r\n"
        let result = try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)

        XCTAssertEqual(result.importedTrackCount, 1)
        XCTAssertEqual(result.skippedInvalidRowCount, 2)
        XCTAssertEqual(result.warnings.count, 2)
        XCTAssertEqual(Set(result.warnings.map(\.reason)), ["Invalid YouTube video ID", "Missing YouTube video ID"])
    }

    func testMalformedCSVRejected() throws {
        let (_container, ctx) = try context()
        let csv = header + "\"Unclosed quote,Song,Artist,abcdefghijk,https://...\r\n"
        XCTAssertThrowsError(try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)) {
            guard case ShaudiBackupImportError.malformedCSV = $0 else {
                return XCTFail("Expected malformedCSV error, got \($0)")
            }
        }
    }

    func testIncorrectHeaderRejected() throws {
        let (_container, ctx) = try context()
        let csv = "Wrong,Header,Fields,Video,URL\r\nP,Song,Artist,abcdefghijk,https://...\r\n"
        XCTAssertThrowsError(try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)) {
            guard case ShaudiBackupImportError.invalidHeader = $0 else {
                return XCTFail("Expected invalidHeader error, got \($0)")
            }
        }
    }

    func testUnicodePreserved() throws {
        let (_container, ctx) = try context()
        let csv = header + "日本語,Café ☕️,Björk,abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
        let result = try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)

        XCTAssertEqual(result.importedTrackCount, 1)
        XCTAssertEqual(result.createdPlaylistCount, 1)

        let playlists = try ctx.fetch(FetchDescriptor<Playlist>())
        XCTAssertEqual(playlists.first?.name, "日本語")
        XCTAssertEqual(playlists.first?.tracks.first?.title, "Café ☕️")
        XCTAssertEqual(playlists.first?.tracks.first?.channelTitle, "Björk")
    }

    func testCommasInsideQuotedFields() throws {
        let (_container, ctx) = try context()
        let csv = header + "\"A, B\",\"One, Two\",\"Band, Inc.\",abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
        let result = try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)

        XCTAssertEqual(result.importedTrackCount, 1)
        let playlists = try ctx.fetch(FetchDescriptor<Playlist>())
        XCTAssertEqual(playlists.first?.name, "A, B")
        XCTAssertEqual(playlists.first?.tracks.first?.title, "One, Two")
        XCTAssertEqual(playlists.first?.tracks.first?.channelTitle, "Band, Inc.")
    }

    func testQuotesInsideQuotedFields() throws {
        let (_container, ctx) = try context()
        let csv = header + "P,\"Say \"\"Hi\"\"\",\"The \"\"Band\"\"\",abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
        let result = try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)

        XCTAssertEqual(result.importedTrackCount, 1)
        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        XCTAssertEqual(tracks.first?.title, "Say \"Hi\"")
        XCTAssertEqual(tracks.first?.channelTitle, "The \"Band\"")
    }

    func testEmbeddedNewlinesInsideQuotedFields() throws {
        let (_container, ctx) = try context()
        let csv = header + "P,\"Line\nTwo\",\"Artist\r\nName\",abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
        let result = try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)

        XCTAssertEqual(result.importedTrackCount, 1)
        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        XCTAssertEqual(tracks.first?.title, "Line\nTwo")
        XCTAssertEqual(tracks.first?.channelTitle, "Artist\r\nName")
    }

    func testCRLFLineEndings() throws {
        let (_container, ctx) = try context()
        let csv = "Playlist,Song,Artist,YouTube Video ID,YouTube URL\r\nP,Song,Artist,abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
        let result = try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)
        XCTAssertEqual(result.importedTrackCount, 1)
    }

    func testDuplicateVideoIDRowsReuseOneTrack() throws {
        let (_container, ctx) = try context()
        let csv = header
            + "P1,Song 1,Artist 1,abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
            + "P2,Song 2,Artist 2,abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
            + "P3,Song 3,Artist 3,abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
        let result = try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)

        XCTAssertEqual(result.importedTrackCount, 1)
        XCTAssertEqual(result.createdPlaylistCount, 3)
        XCTAssertEqual(result.addedMembershipCount, 3)

        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        XCTAssertEqual(tracks.count, 1)
    }

    func testExistingUserMetadataNotOverwritten() throws {
        let (_container, ctx) = try context()
        let existing = Track(
            title: "User Title",
            youtubeURL: URL(string: "https://www.youtube.com/watch?v=abcdefghijk")!,
            youtubeVideoID: "abcdefghijk",
            channelTitle: "User Channel",
            userArtistOverride: "Custom Artist"
        )
        ctx.insert(existing)
        try ctx.save()

        let csv = header + "P,Imported Title,Imported Channel,abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
        try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)

        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        XCTAssertEqual(tracks.first?.title, "User Title")
        XCTAssertEqual(tracks.first?.channelTitle, "User Channel")
        XCTAssertEqual(tracks.first?.userArtistOverride, "Custom Artist")
    }

    func testMissingMetadataSafelyFilled() throws {
        let (_container, ctx) = try context()
        let existing = Track(
            title: "   ",
            youtubeURL: URL(string: "https://www.youtube.com/watch?v=abcdefghijk")!,
            youtubeVideoID: "abcdefghijk",
            channelTitle: nil,
            userArtistOverride: nil
        )
        ctx.insert(existing)
        try ctx.save()

        let csv = header + "P,Filled Title,Filled Artist,abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
        try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)

        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        XCTAssertEqual(tracks.first?.title, "Filled Title")
        XCTAssertEqual(tracks.first?.channelTitle, "Filled Artist")
    }

    func testPreviewDoesNotMutateSwiftData() throws {
        let (_container, ctx) = try context()
        let csv = header + "Road Trip,West Coast,Artist,abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
        let preview = try ShaudiBackupImporter.preview(data: Data(csv.utf8))

        XCTAssertEqual(preview.validSongRowCount, 1)
        XCTAssertEqual(preview.playlistNames, ["Road Trip"])
        XCTAssertEqual(preview.uniqueTrackVideoIDs, ["abcdefghijk"])

        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        let playlists = try ctx.fetch(FetchDescriptor<Playlist>())
        XCTAssertEqual(tracks.count, 0)
        XCTAssertEqual(playlists.count, 0)
    }

    func testFinalImportResultCountsAreAccurate() throws {
        let (_container, ctx) = try context()
        let existingTrack = Track(
            title: "Existing Song",
            youtubeURL: URL(string: "https://www.youtube.com/watch?v=reused00001")!,
            youtubeVideoID: "reused00001"
        )
        let existingPlaylist = Playlist(name: "Existing P", tracks: [existingTrack])
        ctx.insert(existingTrack)
        ctx.insert(existingPlaylist)
        try ctx.save()

        let csv = header
            // Reused playlist + reused track -> duplicate membership (1 skipped)
            + "Existing P,Existing Song,Artist,reused00001,https://www.youtube.com/watch?v=reused00001\r\n"
            // Reused playlist + new track -> 1 membership added, 1 track imported
            + "Existing P,New Song,Artist,newvid00001,https://www.youtube.com/watch?v=newvid00001\r\n"
            // New playlist + reused track -> 1 new playlist, 1 membership added, 1 track reused
            + "New P,Existing Song,Artist,reused00001,https://www.youtube.com/watch?v=reused00001\r\n"
            // Invalid row -> 1 warning
            + "New P,Invalid Song,Artist,bad_id,https://example.com\r\n"

        let result = try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)

        XCTAssertEqual(result.importedTrackCount, 1)
        XCTAssertEqual(result.reusedTrackCount, 1)
        XCTAssertEqual(result.createdPlaylistCount, 1)
        XCTAssertEqual(result.reusedPlaylistCount, 1)
        XCTAssertEqual(result.addedMembershipCount, 2)
        XCTAssertEqual(result.skippedDuplicateMembershipCount, 1)
        XCTAssertEqual(result.skippedInvalidRowCount, 1)
    }

    func testPlaylistRowOrderPreserved() throws {
        let (_container, ctx) = try context()
        let baseDate = Date(timeIntervalSince1970: 1_000_000)
        let csv = header
            + "Road Trip,Track First,A,id111111111,https://www.youtube.com/watch?v=id111111111\r\n"
            + "Road Trip,Track Second,B,id222222222,https://www.youtube.com/watch?v=id222222222\r\n"
            + "Road Trip,Track Third,C,id333333333,https://www.youtube.com/watch?v=id333333333\r\n"
        let preview = try ShaudiBackupImporter.preview(data: Data(csv.utf8))
        try ShaudiBackupImporter.apply(preview, in: ctx, baseDate: baseDate)

        let playlists = try ctx.fetch(FetchDescriptor<Playlist>())
        XCTAssertEqual(playlists.first?.tracksInPlaybackOrder.map(\.title),
                       ["Track First", "Track Second", "Track Third"])
    }

    func testSaveFailureDoesNotFalselyReportSuccess() throws {
        let (_container, ctx) = try context()
        ShaudiBackupImporter.saveOverride = { _ in
            throw SimulatedError.failure
        }

        let csv = header + "Road Trip,West Coast,Artist,abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
        XCTAssertThrowsError(try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)) {
            guard case ShaudiBackupImportError.saveFailed = $0 else {
                return XCTFail("Expected saveFailed error, got \($0)")
            }
        }

        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        let playlists = try ctx.fetch(FetchDescriptor<Playlist>())
        XCTAssertEqual(tracks.count, 0)
        XCTAssertEqual(playlists.count, 0)
    }

    func testNoValidRowsThrows() throws {
        let (_container, ctx) = try context()
        let csv = header + "P,Bad Song,Artist,bad_id,https://example.com\r\n"
        XCTAssertThrowsError(try ShaudiBackupImporter.import(data: Data(csv.utf8), in: ctx)) {
            guard case ShaudiBackupImportError.noValidRows(let warnings) = $0 else {
                return XCTFail("Expected noValidRows error, got \($0)")
            }
            XCTAssertEqual(warnings.count, 1)
        }
    }

    func testInvalidUTF8Throws() throws {
        let (_container, ctx) = try context()
        let invalidData = Data([0xFF, 0xFE, 0xFD])
        XCTAssertThrowsError(try ShaudiBackupImporter.import(data: invalidData, in: ctx)) {
            guard case ShaudiBackupImportError.invalidUTF8 = $0 else {
                return XCTFail("Expected invalidUTF8 error, got \($0)")
            }
        }
    }
}
