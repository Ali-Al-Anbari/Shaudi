import SwiftData
import XCTest
@testable import Shaudi

@MainActor
final class ListeningHistoryTests: XCTestCase {
    func testConfirmedPlaybackCreatesExactlyOneEventAndPauseResumeKeepsItOneEvent() throws {
        let harness = try Harness()
        let requestID = UUID()

        harness.confirm(requestID: requestID, mediaTime: 0)
        harness.confirm(requestID: requestID, mediaTime: 0)
        harness.recorder.closeSegment(requestID: requestID, mediaTime: 20)
        harness.recorder.beginSegment(requestID: requestID, mediaTime: 100)
        harness.recorder.closeSegment(requestID: requestID, mediaTime: 130)
        harness.recorder.finalize(requestID: requestID)

        let entries = try harness.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].listenedDuration, 50, accuracy: 0.001)
        XCTAssertTrue(entries[0].confirmedPlay)
    }

    func testSelectionPreparationLookaheadTrimAndFailureBeforePlayingCreateNoEvents() throws {
        let harness = try Harness()

        // These lifecycle stages deliberately make no confirmPlayback call.
        harness.recorder.finalize(requestID: UUID())

        XCTAssertTrue(try harness.entries().isEmpty)
    }

    func testUnsavedSearchPersistsWithoutChangingLibrary() throws {
        let harness = try Harness()
        harness.confirm(source: .search)

        XCTAssertEqual(try harness.entries().count, 1)
        XCTAssertTrue(try harness.context.fetch(FetchDescriptor<Track>()).isEmpty)
    }

    func testRecommendationPreservesAuthoritativeLastFMIdentity() throws {
        let harness = try Harness()
        let identity = SongIdentity(artist: "Lil Peep", title: "Falling Down - Bonus Track")
        harness.confirm(identity: identity, source: .recommendations)

        let entry = try XCTUnwrap(harness.entries().first)
        XCTAssertEqual(entry.canonicalArtist, "Lil Peep")
        XCTAssertEqual(entry.canonicalTitle, "Falling Down - Bonus Track")
        XCTAssertEqual(entry.playbackSource, .recommendations)
    }

    func testLibraryAndPlaylistSourcesPersistAndHistoryDoesNotMutateTrackStats() throws {
        let harness = try Harness()
        let track = Track(
            title: "Artist - Song",
            youtubeURL: URL(string: "https://youtube.com/watch?v=video")!,
            youtubeVideoID: "video"
        )
        harness.context.insert(track)
        track.playCount += 1 // The existing confirmed-play signal remains the sole aggregate write.
        track.lastPlayedAt = .now

        harness.confirm(requestID: UUID(), source: .library)
        harness.recorder.finalize()
        harness.confirm(requestID: UUID(), source: .playlist)

        let entries = try harness.entries()
        XCTAssertEqual(Set(entries.compactMap(\.playbackSource)), [.library, .playlist])
        XCTAssertEqual(track.playCount, 1)
    }

    func testSeekDoesNotAddSkippedMediaDistance() throws {
        let harness = try Harness()
        let requestID = UUID()
        harness.confirm(requestID: requestID, mediaTime: 0)
        harness.recorder.closeSegment(requestID: requestID, mediaTime: 20)
        harness.recorder.beginSegment(requestID: requestID, mediaTime: 200)
        harness.recorder.closeSegment(requestID: requestID, mediaTime: 230)

        XCTAssertEqual(try XCTUnwrap(harness.entries().first).listenedDuration, 50, accuracy: 0.001)
    }

    func testSkipFinalizesAndNextWaitsForConfirmedPlayback() throws {
        let harness = try Harness()
        let first = UUID()
        harness.confirm(requestID: first)
        harness.recorder.finalize(requestID: first, mediaTime: 12)
        XCTAssertEqual(try harness.entries().count, 1)

        let second = UUID()
        XCTAssertEqual(try harness.entries().count, 1)
        harness.confirm(requestID: second, title: "Second")

        XCTAssertEqual(try harness.entries().count, 2)
    }

    func testStopAndFailureAfterListeningRetainDurationAndFinalize() throws {
        let harness = try Harness()
        let stopped = UUID()
        harness.confirm(requestID: stopped)
        harness.recorder.finalize(requestID: stopped, mediaTime: 14)

        let failed = UUID()
        harness.confirm(requestID: failed)
        harness.recorder.closeSegment(requestID: failed, mediaTime: 9)
        harness.recorder.finalize(requestID: failed)

        let entries = try harness.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.listenedDuration)), Set([14, 9]))
        XCTAssertTrue(entries.allSatisfy { $0.endedAt != nil })
    }

    func testTwoSeparatePlaysOfSameSongCreateTwoEvents() throws {
        let harness = try Harness()
        harness.confirm(requestID: UUID())
        harness.recorder.finalize()
        harness.confirm(requestID: UUID())

        XCTAssertEqual(try harness.entries().count, 2)
    }

    func testMetadataIsSnapshotAndCanonicalHTMLUnicodeIdentitiesGroup() throws {
        let harness = try Harness()
        let track = Track(
            title: "Don't Cry",
            youtubeURL: URL(string: "https://youtube.com/watch?v=video")!,
            youtubeVideoID: "video",
            channelTitle: "Guns N' Roses"
        )
        harness.context.insert(track)
        let htmlIdentity = SongIdentity(artist: "Guns N&#39; Roses", title: "Don&#39;t Cry")
        harness.confirm(identity: htmlIdentity)
        track.title = "A Later Custom Title"
        track.userArtistOverride = "A Later Artist"

        let entry = try XCTUnwrap(harness.entries().first)
        XCTAssertEqual(entry.canonicalArtist, "Guns N' Roses")
        XCTAssertEqual(entry.canonicalTitle, "Don't Cry")
        XCTAssertEqual(
            entry.canonicalIdentityKey,
            SongIdentity(artist: "Guns N’ Roses", title: "Don’t Cry").cacheKey
        )
    }

    func testStaleRequestCannotMutateCurrentEvent() throws {
        let harness = try Harness()
        let old = UUID()
        let current = UUID()
        harness.confirm(requestID: old)
        harness.confirm(requestID: current, title: "Current")
        harness.recorder.closeSegment(requestID: old, mediaTime: 500)
        harness.recorder.finalize(requestID: old, mediaTime: 500)

        let currentEntry = try XCTUnwrap(harness.entries().first { $0.canonicalTitle == "Current" })
        XCTAssertEqual(currentEntry.listenedDuration, 0)
        XCTAssertNil(currentEntry.endedAt)
    }

    func testCheckpointUpdatesSameEvent() throws {
        let harness = try Harness()
        let requestID = UUID()
        harness.confirm(requestID: requestID)
        harness.recorder.checkpoint(requestID: requestID, mediaTime: 30)
        harness.recorder.checkpoint(requestID: requestID, mediaTime: 60)

        let entries = try harness.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].listenedDuration, 60, accuracy: 0.001)
    }

    func testRecentFetchIsLimitedAndNewestFirst() throws {
        let harness = try Harness()
        for index in 0..<250 {
            let entry = ListeningHistoryEntry(
                youtubeVideoID: "video-\(index)",
                canonicalArtist: "Artist",
                canonicalTitle: "Song \(index)",
                canonicalIdentityKey: "artist\u{1F}song \(index)",
                playbackSourceRawValue: ListeningHistoryPlaybackSource.search.rawValue,
                startedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
            harness.context.insert(entry)
        }
        try harness.context.save()

        let recent = try harness.context.fetch(ListeningHistoryStats.recentDescriptor(limit: 10))
        XCTAssertEqual(recent.count, 10)
        XCTAssertEqual(recent.first?.canonicalTitle, "Song 249")
        XCTAssertEqual(recent.last?.canonicalTitle, "Song 240")
    }

    func testTopArtistsGroupsCaseDifferencesAndKeepsDisplayArtistReadable() {
        let artists = ListeningHistoryStats.topArtists(from: [
            historyEntry(artist: "Juice WRLD", title: "Bandit", duration: 40),
            historyEntry(artist: "juice wrld", title: "Lucid Dreams", duration: 20),
            historyEntry(artist: "JUICE WRLD", title: "Robbery", duration: 10)
        ])

        XCTAssertEqual(artists.count, 1)
        XCTAssertEqual(artists[0].displayArtist, "Juice WRLD")
        XCTAssertEqual(artists[0].listenedDuration, 70, accuracy: 0.001)
        XCTAssertEqual(artists[0].eventCount, 3)
    }

    func testTopArtistsSortByListenedDuration() {
        let artists = ListeningHistoryStats.topArtists(from: [
            historyEntry(artist: "Paramore", title: "A", duration: 40),
            historyEntry(artist: "Shakira", title: "B", duration: 80)
        ])

        XCTAssertEqual(artists.map(\.displayArtist), ["Shakira", "Paramore"])
    }

    func testTopArtistsBreakDurationTieByEventCountThenAlphabetically() {
        let artists = ListeningHistoryStats.topArtists(from: [
            historyEntry(artist: "Zulu", title: "A", duration: 60),
            historyEntry(artist: "Alpha", title: "B", duration: 30),
            historyEntry(artist: "Alpha", title: "C", duration: 30),
            historyEntry(artist: "Bravo", title: "D", duration: 60),
            historyEntry(artist: "Charlie", title: "E", duration: 60)
        ])

        XCTAssertEqual(artists.map(\.displayArtist), ["Alpha", "Bravo", "Charlie", "Zulu"])
    }

    func testTopArtistsIgnoresZeroDurationEventsAndIncludesUnsavedSources() {
        let artists = ListeningHistoryStats.topArtists(from: [
            historyEntry(artist: "Lil Peep", title: "Falling Down", duration: 30, source: .search),
            historyEntry(artist: "Lil Peep", title: "Star Shopping", duration: 45, source: .recommendations),
            historyEntry(artist: "Distractor", title: "Silent", duration: 0, source: .search)
        ])

        XCTAssertEqual(artists.count, 1)
        XCTAssertEqual(artists[0].displayArtist, "Lil Peep")
        XCTAssertEqual(artists[0].listenedDuration, 75, accuracy: 0.001)
        XCTAssertEqual(artists[0].eventCount, 2)
    }
}

@MainActor
private func historyEntry(
    artist: String,
    title: String,
    duration: TimeInterval,
    source: ListeningHistoryPlaybackSource = .library
) -> ListeningHistoryEntry {
    let identity = SongIdentity(artist: artist, title: title)
    return ListeningHistoryEntry(
        youtubeVideoID: UUID().uuidString,
        canonicalArtist: identity.artist,
        canonicalTitle: identity.title,
        canonicalIdentityKey: identity.cacheKey,
        playbackSourceRawValue: source.rawValue,
        listenedDuration: duration
    )
}

@MainActor
private final class Harness {
    let container: ModelContainer
    let context: ModelContext
    let recorder: ListeningHistoryRecorder

    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: Track.self,
            Playlist.self,
            ListeningHistoryEntry.self,
            configurations: configuration
        )
        context = container.mainContext
        recorder = ListeningHistoryRecorder(modelContext: context)
    }

    func confirm(
        requestID: UUID = UUID(),
        mediaTime: TimeInterval = 0,
        identity: SongIdentity? = nil,
        title: String? = nil,
        source: ListeningHistoryPlaybackSource = .search
    ) {
        let baseIdentity = identity ?? SongIdentity(artist: "Artist", title: "Song")
        let selectedIdentity = title.map { SongIdentity(artist: baseIdentity.artist, title: $0) }
            ?? baseIdentity
        recorder.confirmPlayback(
            requestID: requestID,
            snapshot: ListeningHistorySnapshot(
                youtubeVideoID: "video",
                identity: selectedIdentity,
                artworkURL: URL(string: "https://example.com/art.jpg"),
                source: source
            ),
            mediaTime: mediaTime
        )
    }

    func entries() throws -> [ListeningHistoryEntry] {
        try context.fetch(
            FetchDescriptor<ListeningHistoryEntry>(
                sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
            )
        )
    }
}
