//
//  RecommendationTestFixtures.swift
//  ShaudiTests
//

import Foundation
import XCTest
@testable import Shaudi

enum StructuredVideoIDPlacement: Equatable {
    case playlistItemData
    case navigation
    case flexColumn
    case overlay
}

extension XCTestCase {
    func targetIdentity(_ target: LastFMSimilarTrack) -> SongIdentity {
        SongIdentity(artist: target.artist, title: target.title)
    }

    func structuredFixture(contents: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["contents": contents])
    }

    func structuredCard(
        videoID: String,
        title: String,
        artist: String
    ) -> [String: Any] {
        [
            "title": ["runs": [["text": title]]],
            "subtitle": [
                "runs": [
                    ["text": "Song"],
                    ["text": " • "],
                    ["text": artist],
                    ["text": " • "],
                    ["text": "Album"]
                ]
            ],
            "navigationEndpoint": [
                "watchEndpoint": ["videoId": videoID]
            ]
        ]
    }

    func structuredRow(
        videoID: String,
        placement: StructuredVideoIDPlacement,
        title: String,
        artist: String
    ) -> [String: Any] {
        var titleRun: [String: Any] = ["text": title]
        if placement == .flexColumn {
            titleRun["navigationEndpoint"] = [
                "watchEndpoint": ["videoId": videoID]
            ]
        }
        var row: [String: Any] = [
            "flexColumns": [
                [
                    "musicResponsiveListItemFlexColumnRenderer": [
                        "text": ["runs": [titleRun]]
                    ]
                ],
                [
                    "musicResponsiveListItemFlexColumnRenderer": [
                        "text": [
                            "runs": [
                                ["text": "Song"],
                                ["text": " • "],
                                ["text": artist],
                                ["text": " • "],
                                ["text": "Album"]
                            ]
                        ]
                    ]
                ]
            ],
            "fixedColumns": [[
                "musicResponsiveListItemFixedColumnRenderer": [
                    "text": ["simpleText": "3:00"]
                ]
            ]]
        ]
        switch placement {
        case .playlistItemData:
            row["playlistItemData"] = ["videoId": videoID]
        case .navigation:
            row["navigationEndpoint"] = [
                "watchEndpoint": ["videoId": videoID]
            ]
        case .flexColumn:
            break
        case .overlay:
            row["overlay"] = [
                "musicItemThumbnailOverlayRenderer": [
                    "content": [
                        "musicPlayButtonRenderer": [
                            "playNavigationEndpoint": [
                                "watchEndpoint": ["videoId": videoID]
                            ]
                        ]
                    ]
                ]
            ]
        }
        return row
    }

    func structuredSearchFixtureData() -> Data {
        Data(
            #"""
            {
              "contents": {
                "tabbedSearchResultsRenderer": {
                  "tabs": [{
                    "tabRenderer": {
                      "content": {
                        "sectionListRenderer": {
                          "contents": [{
                            "musicShelfRenderer": {
                              "contents": [{
                                "musicResponsiveListItemRenderer": {
                                  "flexColumns": [
                                    {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Example Song","navigationEndpoint":{"watchEndpoint":{"videoId":"struct00001"}}}]}}},
                                    {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Song"},{"text":" • "},{"text":"Example Artist"},{"text":" • "},{"text":"Example Album"}]}}}
                                  ],
                                  "fixedColumns": [{"musicResponsiveListItemFixedColumnRenderer":{"text":{"simpleText":"3:45"}}}],
                                  "playlistItemData": {"videoId":"struct00001"},
                                  "thumbnail": {"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/struct00001/default.jpg"}]}}}
                                }
                              }]
                            }
                          }]
                        }
                      }
                    }
                  }]
                }
              }
            }
            """#.utf8
        )
    }

    func manualSeed(
        title: String,
        channel: String,
        searchQuery: String? = nil
    ) -> RecommendationSeed {
        RecommendationSeed(
            youtubeVideoID: "abcdefghijk",
            rawTitle: title,
            displayedArtist: channel,
            sourceChannel: channel,
            userArtistOverride: nil,
            searchQuery: searchQuery
        )
    }

    func candidate(_ artist: String, _ title: String) -> LastFMSimilarTrack {
        LastFMSimilarTrack(artist: artist, title: title, match: 1, url: nil)
    }

    func banditSeed() -> RecommendationSeed {
        RecommendationSeed(
            youtubeVideoID: "bandit00001",
            canonicalIdentity: SongIdentity(artist: "Juice WRLD", title: "Bandit"),
            youtubeTitle: "Juice WRLD - Bandit (Official Music Video)",
            youtubeChannel: "Lyrical Lemonade"
        )
    }

    func unreleasedSeed() -> RecommendationSeed {
        RecommendationSeed(
            youtubeVideoID: "unreleased1",
            canonicalIdentity: SongIdentity(
                artist: "Juice WRLD",
                title: "Some Unreleased Song"
            ),
            youtubeTitle: "Juice WRLD - Some Unreleased Song",
            youtubeChannel: "Juice WRLD"
        )
    }

    func fallbackTestService(
        similarTracks: @escaping (
            String,
            String,
            Int
        ) async throws -> [LastFMSimilarTrack],
        topTracks: @escaping (String, Int) async throws -> [LastFMTopTrack]
    ) -> RecommendationService {
        RecommendationService(
            similarTracks: similarTracks,
            topTracks: topTracks,
            videoResolver: YouTubeRecommendationResolver(
                primarySearch: { _ in [] },
                dataAPISearch: { _ in [] }
            ),
            resolutionCache: MemoryYouTubeResolutionCache()
        )
    }

    func canonicalSeed(index: Int) -> RecommendationSeed {
        RecommendationSeed(
            youtubeVideoID: String(format: "s%010d", index),
            canonicalIdentity: SongIdentity(artist: "Artist \(index)", title: "Song \(index)"),
            youtubeTitle: "Artist \(index) - Song \(index)",
            youtubeChannel: "Artist \(index)"
        )
    }

    func youtubeResult(
        videoID: String,
        artist: String,
        title: String
    ) -> YouTubeSearchResult {
        YouTubeSearchResult(
            youtubeVideoID: videoID,
            title: "\(artist) - \(title) (Official Audio)",
            channelTitle: artist,
            thumbnailURL: nil
        )
    }

    func resolutionContext(
        sessionID: UUID = UUID(),
        epochID: UUID = UUID(),
        upcomingCount: Int = 0
    ) -> RecommendationResolutionContext {
        RecommendationResolutionContext(
            sessionID: sessionID,
            epochID: epochID,
            upcomingCount: upcomingCount
        )
    }

    func isolatedFallbackBudget(
        now: @escaping () -> Date = Date.init
    ) -> RecommendationDataAPIFallbackBudget {
        RecommendationDataAPIFallbackBudget(defaults: isolatedUserDefaults(), now: now)
    }

    func isolatedUserDefaults() -> UserDefaults {
        UserDefaults(suiteName: "RecommendationFallbackTests.\(UUID().uuidString)")!
    }
}

actor AsyncSearchGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspendUntilReleased() async {
        started = true
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

actor FakeGenreTagFetcher: GenreTagFetching {
    enum Error: Swift.Error {
        case offline
    }

    private let result: Result<[GenreTag], Swift.Error>
    private let delayNanoseconds: UInt64
    private(set) var callCount = 0

    init(result: Result<[GenreTag], Swift.Error>, delayNanoseconds: UInt64 = 0) {
        self.result = result
        self.delayNanoseconds = delayNanoseconds
    }

    func topTags(artist: String, title: String) async throws -> [GenreTag] {
        callCount += 1
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return try result.get()
    }

    func calls() -> Int {
        callCount
    }
}

@MainActor
final class MemoryYouTubeResolutionCache: YouTubeResolutionCaching {
    private var storage: [SongIdentity: YouTubeSearchResult]
    private(set) var storeCount = 0
    private(set) var removeCount = 0

    init() {
        storage = [:]
    }

    init(_ storage: [SongIdentity: YouTubeSearchResult]) {
        self.storage = storage
    }

    func learnedIdentity(forVideoID videoID: String) async -> SongIdentity? {
        storage.first { $0.value.youtubeVideoID == videoID }?.key
    }

    func result(for identity: SongIdentity, now: Date) async -> YouTubeSearchResult? {
        storage[identity]
    }

    func peek(for identity: SongIdentity, now: Date) async -> YouTubeSearchResult? {
        storage[identity]
    }

    func learn(
        _ identity: SongIdentity,
        videoID: String,
        metadata: YouTubeResolutionMetadata,
        source: YouTubeResolutionKnowledgeSource,
        now: Date
    ) async -> Bool {
        guard videoID.count == 11 else {
            return false
        }
        storeCount += 1
        storage[identity] = YouTubeSearchResult(
            youtubeVideoID: videoID,
            title: metadata.title ?? identity.title,
            channelTitle: metadata.channel ?? identity.artist,
            thumbnailURL: metadata.thumbnailURL,
            duration: metadata.duration
        )
        return true
    }

    func store(
        _ result: YouTubeSearchResult,
        for identity: SongIdentity,
        now: Date
    ) async {
        storeCount += 1
        storage[identity] = result
    }

    func remove(_ identity: SongIdentity) async {
        removeCount += 1
        storage[identity] = nil
    }
}

@MainActor
final class MockRecommendationRadioHarness {
    private final class FixtureState {
        var lastFMCallCount = 0
        var requestedLimits: [Int] = []
        var nextVideoNumber = 1
        var searchResults: [String: YouTubeSearchResult] = [:]
    }

    private let fixture: FixtureState
    private let service: RecommendationService
    private(set) var session: RecommendationRadioSession
    private(set) var upcoming: [ResolvedRecommendation] = []
    private(set) var history: [SongIdentity] = []
    private(set) var consumedIdentities: [SongIdentity] = []
    private(set) var maxUpcomingCount = 0
    let tagRequestCount = 0

    var lastFMCallCount: Int { fixture.lastFMCallCount }
    var requestedLimits: [Int] { fixture.requestedLimits }

    init(anchor: RecommendationSeed) {
        let fixture = FixtureState()
        self.fixture = fixture
        session = RecommendationRadioSession(anchor: anchor)
        let cache = MemoryYouTubeResolutionCache()
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { query in
                fixture.searchResults[query].map { [$0] } ?? []
            },
            dataAPISearch: { _ in [] }
        )
        service = RecommendationService(
            similarTracks: { _, _, limit in
                fixture.lastFMCallCount += 1
                fixture.requestedLimits.append(limit)
                return (1...50).map { index in
                    let number = fixture.nextVideoNumber
                    fixture.nextVideoNumber += 1
                    let artist = "Epoch \(fixture.lastFMCallCount) Artist \(index)"
                    let title = "Epoch \(fixture.lastFMCallCount) Song \(index)"
                    let videoID = String(format: "m%010d", number)
                    fixture.searchResults["\(artist) \(title)"] = YouTubeSearchResult(
                        youtubeVideoID: videoID,
                        title: "\(artist) - \(title) (Official Audio)",
                        channelTitle: artist,
                        thumbnailURL: nil
                    )
                    return LastFMSimilarTrack(
                        artist: artist,
                        title: title,
                        match: 1 - Double(index) / 100,
                        url: nil
                    )
                }
            },
            videoResolver: resolver,
            resolutionCache: cache
        )
    }

    func start() async throws {
        try await loadCurrentEpoch()
        try await replenishIfNeeded()
    }

    func consumeNext() async throws {
        if upcoming.isEmpty {
            try await replenishIfNeeded()
        }
        let current = try XCTUnwrap(upcoming.first)
        upcoming.removeFirst()
        consumedIdentities.append(current.songIdentity)
        history.append(current.songIdentity)
        history = Array(history.suffix(RecommendationRadioPolicy.historyQueueLimit))

        let seed = RecommendationSeed(
            youtubeVideoID: current.youtubeResult.youtubeVideoID,
            canonicalIdentity: current.songIdentity,
            youtubeTitle: current.youtubeResult.title,
            youtubeChannel: current.youtubeResult.channelTitle
        )
        let action = session.confirmedRecommendationPlayback(seed: seed)
        if case .startNewEpoch = action {
            try await loadCurrentEpoch()
        }
        try await replenishIfNeeded()
    }

    private func loadCurrentEpoch() async throws {
        let epochID = session.epoch.id
        guard session.markEpochCandidateRequestStarted(epochID: epochID) else {
            return
        }
        let batch = try await service.recommendations(
            for: session.epoch.anchor,
            excludingVideoIDs: Set(upcoming.map { $0.youtubeResult.youtubeVideoID }),
            excludingSongIdentities: session.globalPlayedSongIdentities,
            context: RecommendationResolutionContext(
                sessionID: session.id,
                epochID: epochID,
                upcomingCount: upcoming.count
            )
        )
        XCTAssertTrue(session.replaceReservoir(batch.reservoirCandidates, epochID: epochID))
        append(batch.recommendations)
    }

    private func replenishIfNeeded() async throws {
        let desired = RecommendationRadioPolicy.targetUpcomingCount - upcoming.count
        guard desired > 0 else { return }
        let candidates = session.takeReservoirCandidates(
            upTo: 8,
            epochID: session.epoch.id
        )
        let resolution = try await service.resolveReservoirCandidates(
            candidates,
            desiredCount: desired,
            excludingVideoIDs: Set(upcoming.map { $0.youtubeResult.youtubeVideoID }),
            excludingSongIdentities: session.globalPlayedSongIdentities,
            context: RecommendationResolutionContext(
                sessionID: session.id,
                epochID: session.epoch.id,
                upcomingCount: upcoming.count
            )
        )
        XCTAssertTrue(session.returnUnusedReservoirCandidates(
            resolution.unusedCandidates,
            epochID: session.epoch.id
        ))
        append(resolution.recommendations)
    }

    private func append(_ results: [ResolvedRecommendation]) {
        for result in results where !session.globalPlayedSongIdentities.contains(result.songIdentity) {
            upcoming.append(result)
            session.recordSeen(result.songIdentity)
        }
        upcoming = Array(upcoming.prefix(RecommendationRadioPolicy.upcomingQueueLimit))
        maxUpcomingCount = max(maxUpcomingCount, upcoming.count)
    }
}
