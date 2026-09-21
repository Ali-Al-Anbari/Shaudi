import Foundation
import XCTest
@testable import Shaudi

@MainActor
final class WrappedStatsTests: XCTestCase {
    private var calendar: Calendar!
    private var now: Date!

    override func setUp() {
        super.setUp()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        self.calendar = calendar
        now = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 19,
            hour: 12
        ))!
    }

    func testNoDataSummaryDoesNotInventValues() {
        let summary = build([])

        XCTAssertFalse(summary.hasData)
        XCTAssertEqual(summary.totalListenedDuration, 0)
        XCTAssertEqual(summary.playCount, 0)
        XCTAssertTrue(summary.topSongs.isEmpty)
        XCTAssertTrue(summary.topArtists.isEmpty)
        XCTAssertTrue(summary.favoriteGenres.isEmpty)
        XCTAssertNil(summary.personality)
    }

    func testThisYearFiltersOlderEntriesAndAllTimeIncludesThem() {
        let thisYear = entry(
            artist: "Current",
            title: "Now",
            listened: 60,
            startedAt: date(year: 2026, month: 2, day: 1)
        )
        let older = entry(
            artist: "Older",
            title: "Then",
            listened: 120,
            startedAt: date(year: 2025, month: 12, day: 31, hour: 23)
        )

        let yearly = build([thisYear, older])
        let allTime = build([thisYear, older], period: .allTime)

        XCTAssertEqual(yearly.totalListenedDuration, 60)
        XCTAssertEqual(yearly.playCount, 1)
        XCTAssertEqual(allTime.totalListenedDuration, 180)
        XCTAssertEqual(allTime.playCount, 2)
    }

    func testTotalDurationUsesActualListenedSecondsAndConfirmedPlayCount() {
        let entries = [
            entry(artist: "A", title: "One", listened: 42),
            entry(artist: "B", title: "Two", listened: 18),
            entry(artist: "C", title: "Zero", listened: 0),
            entry(artist: "D", title: "Unconfirmed", listened: 500, confirmed: false)
        ]

        let summary = build(entries)

        XCTAssertEqual(summary.totalListenedDuration, 60, accuracy: 0.001)
        XCTAssertEqual(summary.playCount, 3)
    }

    func testTopSongUsesDurationAndAggregatesCanonicalDuplicates() {
        let entries = [
            entry(artist: "Guns N' Roses", title: "Don&#39;t Cry", listened: 80),
            entry(artist: "guns n’ roses", title: "Don't Cry", listened: 70),
            entry(artist: "Other", title: "Song", listened: 140)
        ]

        let summary = build(entries)
        let top = summary.topSong

        XCTAssertEqual(top?.title, "Don't Cry")
        XCTAssertEqual(top?.artist, "Guns N' Roses")
        XCTAssertEqual(top?.listenedDuration, 150)
        XCTAssertEqual(top?.playCount, 2)
    }

    func testCaseDistinctVideoIDsKeepArtistlessSongsSeparate() {
        let entries = [
            entry(artist: "", title: "Stay", listened: 80, videoID: " ABC123 "),
            entry(artist: "", title: "Stay", listened: 70, videoID: "abc123")
        ]
        let summary = build(entries)

        XCTAssertEqual(summary.topSongs.map(\.identityKey), ["video:ABC123", "video:abc123"])
        XCTAssertEqual(summary.topSongs.map(\.playCount), [1, 1])
        XCTAssertEqual(summary.playCount, 2)
        XCTAssertEqual(summary.totalListenedDuration, 150)
    }

    func testEqualArtistlessSongsHaveStableOrderAcrossInputOrder() {
        let entries = [
            entry(artist: "", title: "Stay", listened: 60, videoID: "ABC123"),
            entry(artist: "", title: "Stay", listened: 60, videoID: "abc123")
        ]
        XCTAssertEqual(build(entries).topSongs, build(entries.reversed()).topSongs)
    }

    func testArtistlessSongsGroupByVideoBeforeTitle() {
        let summary = build([
            entry(artist: "", title: "Stay", listened: 30, videoID: "video-A"),
            entry(artist: "", title: "Stay", listened: 40, videoID: "video-A"),
            entry(artist: "", title: "Stay", listened: 50, videoID: "video-B")
        ])

        XCTAssertEqual(summary.topSongs.count, 2)
        XCTAssertEqual(summary.topSongs.first { $0.identityKey == "video:video-A" }?.playCount, 2)
        XCTAssertEqual(summary.topSongs.first { $0.identityKey == "video:video-B" }?.playCount, 1)
    }

    func testCanonicalSongGroupsAcrossVideoIDsButDifferentArtistsStaySeparate() {
        let summary = build([
            entry(artist: "Artist One", title: "Stay", listened: 50, videoID: "video-A"),
            entry(artist: "artist one", title: "Stay", listened: 60, videoID: "video-B"),
            entry(artist: "Artist Two", title: "Stay", listened: 70, videoID: "video-C")
        ])

        XCTAssertEqual(summary.topSongs.count, 2)
        XCTAssertEqual(summary.topSongs.first?.playCount, 2)
        XCTAssertEqual(summary.topSongs.first?.listenedDuration, 110)
        XCTAssertEqual(summary.topSongs.last?.artist, "Artist Two")
    }

    func testTitleOnlyIsLastResortForLegacyRowsWithoutArtistOrVideo() {
        let summary = build([
            entry(artist: "", title: "Stay", listened: 30, videoID: ""),
            entry(artist: "", title: "stay", listened: 40, videoID: " "),
            entry(artist: "", title: "", listened: 10, videoID: "")
        ])

        XCTAssertEqual(summary.topSongs.first?.identityKey, "title:stay")
        XCTAssertEqual(summary.topSongs.first?.playCount, 2)
        XCTAssertEqual(summary.topSongs.count, 2)
    }

    func testReplayCountsDoNotMergeCaseDistinctVideoIDs() {
        let summary = build([
            entry(artist: "Known", title: "Top", listened: 200),
            entry(artist: "", title: "Stay", listened: 40, videoID: "ABC123"),
            entry(artist: "", title: "Stay", listened: 40, videoID: "ABC123"),
            entry(artist: "", title: "Stay", listened: 40, videoID: "abc123")
        ])

        XCTAssertEqual(summary.mostReplayedSong?.identityKey, "video:ABC123")
        XCTAssertEqual(summary.mostReplayedSong?.playCount, 2)
        XCTAssertEqual(summary.topSongs.first { $0.identityKey == "video:abc123" }?.playCount, 1)
    }

    func testGenreFallbackKeepsCaseDistinctVideoIDsSeparate() {
        let upperTrack = Track(
            title: "Upper",
            youtubeURL: URL(string: "https://youtube.com/watch?v=ABC123")!,
            youtubeVideoID: "ABC123"
        )
        upperTrack.storeGenreTags(["Rock"])
        let lowerTrack = Track(
            title: "Lower",
            youtubeURL: URL(string: "https://youtube.com/watch?v=abc123")!,
            youtubeVideoID: "abc123"
        )
        lowerTrack.storeGenreTags(["Pop"])

        let summary = build([
            entry(artist: "", title: "Stay", listened: 120, videoID: "ABC123")
        ], tracks: [upperTrack, lowerTrack])

        XCTAssertEqual(summary.favoriteGenres.map(\.name), ["Rock"])
    }

    func testTopArtistReusesCanonicalListeningHistoryAggregation() {
        let entries = [
            entry(artist: "Paramore", title: "A", listened: 80),
            entry(artist: "paramore", title: "B", listened: 70),
            entry(artist: "Other", title: "C", listened: 120)
        ]

        let summary = build(entries)

        XCTAssertEqual(summary.topArtist?.displayArtist, "Paramore")
        XCTAssertEqual(summary.topArtist?.listenedDuration, 150)
        XCTAssertEqual(summary.topArtist?.eventCount, 2)
    }

    func testFavoriteGenresReuseExistingDurationDistribution() {
        let entries = [
            entry(
                artist: "A",
                title: "One",
                listened: 300,
                genres: ["Pop", "Rock"]
            ),
            entry(
                artist: "B",
                title: "Two",
                listened: 100,
                genres: ["Pop"]
            )
        ]

        let genres = build(entries).favoriteGenres

        XCTAssertEqual(genres.map(\.name), ["Pop", "Rock"])
        XCTAssertEqual(genres.map(\.percentage), [63, 38])
    }

    func testCurrentTrackGenreCacheFillsMissingSnapshotWithoutTrackDependency() {
        let history = entry(
            artist: "Artist",
            title: "Song",
            listened: 120,
            videoID: "same-video"
        )
        let track = Track(
            title: "Uploader title",
            youtubeURL: URL(string: "https://youtube.com/watch?v=same-video")!,
            youtubeVideoID: "same-video"
        )
        track.storeGenreTags(["Alternative"])

        XCTAssertEqual(
            build([history], tracks: [track]).favoriteGenre?.name,
            "Alternative"
        )
        XCTAssertTrue(build([history], tracks: []).favoriteGenres.isEmpty)
    }

    func testDeletedTrackAndMissingMetadataFallBackSafely() {
        let missing = entry(
            artist: "",
            title: "",
            listened: 90,
            genres: ["Pop"],
            videoID: "orphaned-video"
        )

        let summary = build([missing], tracks: [])

        XCTAssertTrue(summary.hasData)
        XCTAssertEqual(summary.topSong?.title, "Unknown Song")
        XCTAssertEqual(summary.topSong?.artist, "Unknown Artist")
        XCTAssertEqual(summary.favoriteGenre?.name, "Pop")
        XCTAssertTrue(summary.topArtists.isEmpty)
    }

    func testOldRowsWithNilNewerFieldsRemainUsable() {
        let old = entry(
            artist: "Legacy Artist",
            title: "Legacy Song",
            listened: 180,
            authoritativeDuration: nil,
            completionOutcome: nil
        )

        let summary = build([old], period: .allTime)

        XCTAssertEqual(summary.totalListenedDuration, 180)
        XCTAssertEqual(summary.topSong?.title, "Legacy Song")
        XCTAssertNil(summary.personality)
    }

    func testThisYearUsesLocalCalendarJanuaryFirstBoundary() {
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = TimeZone(secondsFromGMT: 14 * 60 * 60)!
        let localNow = localCalendar.date(from: DateComponents(
            year: 2026,
            month: 1,
            day: 2,
            hour: 12
        ))!
        let boundary = localCalendar.dateInterval(of: .year, for: localNow)!.start
        let entries = [
            entry(artist: "In", title: "Boundary", listened: 60, startedAt: boundary),
            entry(
                artist: "Out",
                title: "Before",
                listened: 120,
                startedAt: boundary.addingTimeInterval(-1)
            )
        ]

        let summary = WrappedStatsBuilder.build(
            entries: entries,
            period: .thisYear,
            now: localNow,
            calendar: localCalendar
        )

        XCTAssertEqual(summary.playCount, 1)
        XCTAssertEqual(summary.topSong?.title, "Boundary")
        XCTAssertEqual(summary.periodTitle, "2026")
    }

    func testFiveDayHistoryDisplayCutoffDoesNotLimitWrapped() {
        let tenDaysOld = entry(
            artist: "Stored Artist",
            title: "Still Counts",
            listened: 240,
            startedAt: now.addingTimeInterval(-10 * 86_400)
        )
        let displayCutoff = ListeningHistoryStats.displayCutoff(now: now, calendar: calendar)

        XCTAssertLessThan(tenDaysOld.startedAt, displayCutoff)
        XCTAssertEqual(build([tenDaysOld]).totalListenedDuration, 240)
    }

    func testMostReplayedCardIsOnlyProducedWhenDifferentFromTopSong() {
        let entries = [
            entry(artist: "Long", title: "Top", listened: 300),
            entry(artist: "Repeat", title: "Again", listened: 30),
            entry(artist: "Repeat", title: "Again", listened: 30),
            entry(artist: "Repeat", title: "Again", listened: 30)
        ]

        let summary = build(entries)

        XCTAssertEqual(summary.topSong?.title, "Top")
        XCTAssertEqual(summary.mostReplayedSong?.title, "Again")
        XCTAssertEqual(summary.mostReplayedSong?.playCount, 3)

        let sameTopAndReplay = build([
            entry(artist: "Only", title: "Favorite", listened: 100),
            entry(artist: "Only", title: "Favorite", listened: 100),
            entry(artist: "Only", title: "Favorite", listened: 100)
        ])
        XCTAssertNil(sameTopAndReplay.mostReplayedSong)
    }

    func testPersonalityRulesClassifyRepeatExplorerDeepAndLoyalist() {
        let repeater = (0..<4).map { _ in
            entry(artist: "Repeat", title: "Again", listened: 50)
        } + [
            entry(artist: "Other", title: "One", listened: 50),
            entry(artist: "Other", title: "Two", listened: 50)
        ]
        let explorer = (0..<5).map { index in
            entry(artist: "Artist \(index)", title: "Song \(index)", listened: 60)
        }
        let deep = (0..<4).map { index in
            entry(
                artist: "Deep \(index)",
                title: "Song \(index)",
                listened: 80,
                authoritativeDuration: 100
            )
        }
        let loyalist = (0..<4).map { index in
            entry(artist: "Only Artist", title: "Song \(index)", listened: 60)
        }

        XCTAssertEqual(build(repeater).personality, .repeatOffender)
        XCTAssertEqual(build(explorer).personality, .explorer)
        XCTAssertEqual(build(deep).personality, .deepListener)
        XCTAssertEqual(build(loyalist).personality, .loyalist)
    }

    func testPersonalityAndRankingsRemainDeterministicWhenInputOrderChanges() {
        let entries = (0..<5).map { index in
            entry(artist: "Artist \(index)", title: "Song \(index)", listened: 60)
        }

        let first = build(entries)
        let second = build(entries.reversed())

        XCTAssertEqual(first.personality, second.personality)
        XCTAssertEqual(first.topSongs, second.topSongs)
        XCTAssertEqual(first.topArtists, second.topArtists)
    }

    private func build(
        _ entries: some Sequence<ListeningHistoryEntry>,
        tracks: [Track] = [],
        period: WrappedPeriod = .thisYear
    ) -> WrappedSummary {
        WrappedStatsBuilder.build(
            entries: Array(entries),
            tracks: tracks,
            period: period,
            now: now,
            calendar: calendar
        )
    }

    private func entry(
        artist: String,
        title: String,
        listened: TimeInterval,
        startedAt: Date? = nil,
        confirmed: Bool = true,
        genres: [String] = [],
        videoID: String = UUID().uuidString,
        authoritativeDuration: TimeInterval? = nil,
        completionOutcome: ListeningHistoryCompletionOutcome? = nil
    ) -> ListeningHistoryEntry {
        let identity = SongIdentity(artist: artist, title: title)
        return ListeningHistoryEntry(
            youtubeVideoID: videoID,
            canonicalArtist: identity.artist,
            canonicalTitle: identity.title,
            canonicalIdentityKey: identity.cacheKey,
            playbackSourceRawValue: ListeningHistoryPlaybackSource.library.rawValue,
            startedAt: startedAt ?? now,
            listenedDuration: listened,
            confirmedPlay: confirmed,
            genreTagsStorage: genres.joined(separator: "|"),
            authoritativeDuration: authoritativeDuration,
            completionOutcomeRawValue: completionOutcome?.rawValue
        )
    }

    private func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 12
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
    }
}
