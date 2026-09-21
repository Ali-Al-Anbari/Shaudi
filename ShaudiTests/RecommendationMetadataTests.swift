//
//  RecommendationMetadataTests.swift
//  ShaudiTests
//

import XCTest
@testable import Shaudi

@MainActor
final class RecommendationMetadataTests: XCTestCase {
    func testMusicMetadataDecodesCommonHTMLEntitiesForDisplay() {
        XCTAssertEqual(
            MusicMetadataText.decoded("That&#39;s What You Get"),
            "That's What You Get"
        )
        XCTAssertEqual(
            MusicMetadataText.decoded("Rock &amp; Roll"),
            "Rock & Roll"
        )
        XCTAssertEqual(
            MusicMetadataText.decoded("&quot;Song&#x27;s Name&quot;"),
            "\"Song's Name\""
        )
    }

    func testMusicMetadataLeavesAlreadyDecodedTextUnchanged() {
        let value = "That's What You Get"

        XCTAssertEqual(MusicMetadataText.decoded(value), value)
    }

    func testGenreAliasesNormalizeToCanonicalGenres() {
        XCTAssertEqual(GenreTagNormalizer.normalizedGenre(for: "hip hop"), "Hip-Hop")
        XCTAssertEqual(GenreTagNormalizer.normalizedGenre(for: "hip-hop"), "Hip-Hop")
        XCTAssertEqual(GenreTagNormalizer.normalizedGenre(for: "hiphop"), "Hip-Hop")
        XCTAssertEqual(GenreTagNormalizer.normalizedGenre(for: "rnb"), "R&B")
        XCTAssertEqual(GenreTagNormalizer.normalizedGenre(for: "r&b"), "R&B")
        XCTAssertEqual(GenreTagNormalizer.normalizedGenre(for: "rhythm and blues"), "R&B")
        XCTAssertEqual(GenreTagNormalizer.normalizedGenre(for: "pop punk"), "Pop Punk")
    }

    func testNonGenreTagsAreIgnoredAndAliasesCollapse() {
        let genres = GenreTagNormalizer.normalizedGenres(from: [
            GenreTag(name: "seen live", weight: 100),
            GenreTag(name: "favorites", weight: 90),
            GenreTag(name: "female vocalists", weight: 80),
            GenreTag(name: "2010s", weight: 70),
            GenreTag(name: "hip hop", weight: 60),
            GenreTag(name: "hip-hop", weight: 50)
        ])

        XCTAssertEqual(genres, ["Hip-Hop"])
    }

    func testGenreTagsRetainAtMostThreeStrongestGenres() {
        let genres = GenreTagNormalizer.normalizedGenres(from: [
            GenreTag(name: "pop", weight: 10),
            GenreTag(name: "hip hop", weight: 40),
            GenreTag(name: "trap", weight: 30),
            GenreTag(name: "r&b", weight: 20)
        ])

        XCTAssertEqual(genres, ["Hip-Hop", "Trap", "R&B"])
    }

    func testGenreListeningTimeIsDistributedWithoutMultiplyingDuration() {
        let favorites = FavoriteGenreCalculator.favorites(from: [
            (genres: ["Hip-Hop", "Trap"], listeningDuration: 300)
        ])

        XCTAssertEqual(favorites.reduce(0) { $0 + $1.listeningDuration }, 300, accuracy: 0.001)
        XCTAssertEqual(Set(favorites.map(\.name)), Set(["Hip-Hop", "Trap"]))
        XCTAssertEqual(Set(favorites.map(\.percentage)), Set([50]))
    }

    func testFavoriteGenresSortAndPercentagesUseClassifiedListeningTime() {
        let favorites = FavoriteGenreCalculator.favorites(from: [
            (genres: ["Hip-Hop"], listeningDuration: 300),
            (genres: ["Pop"], listeningDuration: 100),
            (genres: [], listeningDuration: 600)
        ])

        XCTAssertEqual(favorites.map(\.name), ["Hip-Hop", "Pop"])
        XCTAssertEqual(favorites.map(\.percentage), [75, 25])
    }

    func testGenreLookupUsesCachedResultWithoutCallingFetcher() async {
        let fetcher = FakeGenreTagFetcher(result: .success([GenreTag(name: "pop", weight: 1)]))
        let coordinator = GenreLookupCoordinator()
        let result = await coordinator.lookup(
            cacheState: GenreTagCacheState(
                genres: ["Pop"],
                fetchedAt: .now,
                lastAttemptAt: .now
            ),
            cacheKey: "artist-song",
            artist: "Artist",
            title: "Song",
            fetcher: fetcher
        )

        XCTAssertEqual(result, .cached)
        let callCount = await fetcher.calls()
        XCTAssertEqual(callCount, 0)
    }

    func testUncachedGenreLookupCallsFetcherOnceAndCachesEmptyResult() async {
        let fetcher = FakeGenreTagFetcher(result: .success([]))
        let coordinator = GenreLookupCoordinator()
        let emptyCache = GenreTagCacheState(genres: [], fetchedAt: nil, lastAttemptAt: nil)
        let result = await coordinator.lookup(
            cacheState: emptyCache,
            cacheKey: "artist-song",
            artist: "Artist",
            title: "Song",
            fetcher: fetcher
        )

        XCTAssertEqual(result, .success([]))
        var callCount = await fetcher.calls()
        XCTAssertEqual(callCount, 1)

        let cachedEmpty = GenreTagCacheState(
            genres: [],
            fetchedAt: .now,
            lastAttemptAt: .now
        )
        let retry = await coordinator.lookup(
            cacheState: cachedEmpty,
            cacheKey: "artist-song",
            artist: "Artist",
            title: "Song",
            fetcher: fetcher
        )
        XCTAssertEqual(retry, .cached)
        callCount = await fetcher.calls()
        XCTAssertEqual(callCount, 1)
    }

    func testSimultaneousGenreLookupTriggersOnlyOneFetcherCall() async {
        let fetcher = FakeGenreTagFetcher(
            result: .success([GenreTag(name: "pop", weight: 1)]),
            delayNanoseconds: 50_000_000
        )
        let coordinator = GenreLookupCoordinator()
        let state = GenreTagCacheState(genres: [], fetchedAt: nil, lastAttemptAt: nil)

        async let first = coordinator.lookup(
            cacheState: state,
            cacheKey: "artist-song",
            artist: "Artist",
            title: "Song",
            fetcher: fetcher
        )
        async let second = coordinator.lookup(
            cacheState: state,
            cacheKey: "artist-song",
            artist: "Artist",
            title: "Song",
            fetcher: fetcher
        )
        let results = await [first, second]

        XCTAssertTrue(results.contains(.success(["Pop"])))
        XCTAssertTrue(results.contains(.inFlight))
        let callCount = await fetcher.calls()
        XCTAssertEqual(callCount, 1)
    }

    func testGenreLookupFailureDefersRetryWithoutChangingCachedGenres() async {
        let fetcher = FakeGenreTagFetcher(result: .failure(FakeGenreTagFetcher.Error.offline))
        let coordinator = GenreLookupCoordinator()
        let result = await coordinator.lookup(
            cacheState: GenreTagCacheState(genres: [], fetchedAt: nil, lastAttemptAt: nil),
            cacheKey: "artist-song",
            artist: "Artist",
            title: "Song",
            fetcher: fetcher
        )

        XCTAssertEqual(result, .failed)
        let failedCache = GenreTagCacheState(genres: [], fetchedAt: nil, lastAttemptAt: .now)
        let retry = await coordinator.lookup(
            cacheState: failedCache,
            cacheKey: "artist-song",
            artist: "Artist",
            title: "Song",
            fetcher: fetcher
        )
        XCTAssertEqual(retry, .retryDeferred)
        let callCount = await fetcher.calls()
        XCTAssertEqual(callCount, 1)
    }

    func testDefaultGenreCacheStateAndUnclassifiedListeningAreSafe() {
        let defaultCache = GenreTagCacheState(
            genres: [],
            fetchedAt: nil,
            lastAttemptAt: nil
        )

        XCTAssertEqual(defaultCache.lookupDecision(), .lookup)
        XCTAssertTrue(
            FavoriteGenreCalculator.favorites(
                from: [(genres: [], listeningDuration: 300)]
            ).isEmpty
        )
    }
}
