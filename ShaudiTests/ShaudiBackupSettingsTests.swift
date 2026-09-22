import Foundation
import SwiftData
import XCTest
@testable import Shaudi

@MainActor
final class ShaudiBackupSettingsTests: XCTestCase {
    private let header = "Playlist,Song,Artist,YouTube Video ID,YouTube URL\r\n"

    private func context() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([Track.self, Playlist.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        return (container, container.mainContext)
    }

    func testOnePlaylistSelection() {
        let first = Playlist(name: "First")
        let second = Playlist(name: "Second")
        let selection = ShaudiBackupExportMode.selection(
            for: .one, playlists: [first, second], selectedIDs: [ObjectIdentifier(second)]
        )
        guard case .playlist(let selected) = selection else { return XCTFail("Expected one playlist") }
        XCTAssertTrue(selected === second)
    }

    func testMultipleSelectionPreservesDisplayedOrder() {
        let first = Playlist(name: "First")
        let second = Playlist(name: "Second")
        let third = Playlist(name: "Third")
        let selection = ShaudiBackupExportMode.selection(
            for: .multiple, playlists: [first, second, third],
            selectedIDs: [ObjectIdentifier(third), ObjectIdentifier(first)]
        )
        guard case .playlists(let selected) = selection else { return XCTFail("Expected playlists") }
        XCTAssertTrue(selected[0] === first)
        XCTAssertTrue(selected[1] === third)
    }

    func testFullBackupSelection() {
        let selection = ShaudiBackupExportMode.selection(for: .full, playlists: [], selectedIDs: [])
        guard case .fullBackup = selection else { return XCTFail("Expected full backup") }
    }

    func testEmptySelectionsCannotExport() {
        let playlist = Playlist(name: "Empty")
        XCTAssertNil(ShaudiBackupExportMode.selection(for: .one, playlists: [playlist], selectedIDs: []))
        XCTAssertNil(ShaudiBackupExportMode.selection(for: .multiple, playlists: [playlist], selectedIDs: []))
    }

    func testExportWarningUsesActualSkippedSongCount() throws {
        let valid = Track(title: "Valid", youtubeURL: URL(string: "https://youtu.be/abcdefghijk")!, youtubeVideoID: "abcdefghijk")
        let invalid = Track(title: "Missing", youtubeURL: URL(string: "https://example.com")!, youtubeVideoID: "")
        let result = try ShaudiBackupExporter.export(.playlist(Playlist(name: "P", tracks: [valid, invalid])))
        XCTAssertEqual(result.exportedSongCount, 1)
        XCTAssertEqual(result.skippedTrackCount, 1)
        XCTAssertEqual(result.skippedTracks.first?.title, "Missing")
    }

    func testTemporaryExportFileUsesSuggestedNameAndCanBeRemoved() throws {
        let result = try ShaudiBackupExporter.export(.playlist(Playlist(name: "Empty")))
        let url = try ShaudiBackupTemporaryFile.write(result)
        XCTAssertEqual(url.lastPathComponent, result.suggestedFilename)
        XCTAssertEqual(try Data(contentsOf: url), result.csvData)
        ShaudiBackupTemporaryFile.remove(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPreviewAndCancelDoNotMutateLibrary() throws {
        let (_, context) = try context()
        let backup = ShaudiBackupCoordinator()
        let csv = header + "Library,Song,Artist,abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
        try backup.prepareImport(data: Data(csv.utf8))
        XCTAssertEqual(backup.preview?.playlistNames, ["Library"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Track>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Playlist>()), 0)
        backup.cancelImport()
        XCTAssertNil(backup.preview)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Track>()), 0)
    }

    func testApplyRequiresConfirmationAndDuplicateStartIsRejected() throws {
        let (_, context) = try context()
        let backup = ShaudiBackupCoordinator()
        let csv = header + ",Song,Artist,abcdefghijk,https://www.youtube.com/watch?v=abcdefghijk\r\n"
        try backup.prepareImport(data: Data(csv.utf8))
        XCTAssertFalse(try backup.confirmImport(in: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Track>()), 0)
        XCTAssertTrue(backup.beginImport())
        XCTAssertFalse(backup.beginImport())
        XCTAssertTrue(try backup.confirmImport(in: context))
        XCTAssertEqual(backup.result?.importedTrackCount, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Track>()), 1)
    }

    func testInvalidDocumentDataAndWrongTypeSurfaceErrors() throws {
        let backup = ShaudiBackupCoordinator()
        XCTAssertThrowsError(try backup.prepareImport(data: Data([0xff]))) {
            XCTAssertEqual($0 as? ShaudiBackupImportError, .invalidUTF8)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data(header.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try backup.prepareImport(from: file)) {
            XCTAssertEqual($0 as? ShaudiBackupSettingsError, .wrongFileType)
        }
    }
}
