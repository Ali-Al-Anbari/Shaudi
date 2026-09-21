//
//  RecommendationBudgetEpochTests.swift
//  ShaudiTests
//

import XCTest
@testable import Shaudi

@MainActor
final class RecommendationBudgetEpochTests: XCTestCase {
    func testHealthyBufferSkipsOfficialFallbackAndUsesReservoirAlternative() async throws {
        let cache = MemoryYouTubeResolutionCache()
        var webRequests = 0
        var dataAPIRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { query in
                webRequests += 1
                guard query.contains("Working Song") else { return [] }
                return [self.youtubeResult(
                    videoID: "working0001",
                    artist: "Artist B",
                    title: "Working Song"
                )]
            },
            dataAPISearch: { _ in dataAPIRequests += 1; return [] },
            fallbackBudget: isolatedFallbackBudget()
        )
        let service = RecommendationService(
            similarTracks: { _, _, _ in [] },
            videoResolver: resolver,
            resolutionCache: cache
        )

        let resolved = try await service.recommendationsFromReservoir(
            [candidate("Artist A", "Broken Song"), candidate("Artist B", "Working Song")],
            desiredCount: 1,
            excludingVideoIDs: [],
            excludingSongIdentities: [],
            context: resolutionContext(upcomingCount: 2)
        )

        XCTAssertEqual(resolved.map(\.title), ["Working Song"])
        XCTAssertEqual(webRequests, 2)
        XCTAssertEqual(dataAPIRequests, 0)
    }

    func testCriticalBufferAllowsOfficialFallbackAndCachesResult() async throws {
        let target = candidate("Artist", "Emergency Song")
        let cache = MemoryYouTubeResolutionCache()
        var webRequests = 0
        var dataAPIRequests = 0
        let official = youtubeResult(
            videoID: "emergency01",
            artist: target.artist,
            title: target.title
        )
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in webRequests += 1; return [] },
            dataAPISearch: { _ in dataAPIRequests += 1; return [official] },
            fallbackBudget: isolatedFallbackBudget()
        )
        let service = RecommendationService(
            similarTracks: { _, _, _ in [] },
            videoResolver: resolver,
            resolutionCache: cache
        )
        let context = resolutionContext(upcomingCount: 1)

        let resolved = try await service.recommendationsFromReservoir(
            [target],
            desiredCount: 1,
            excludingVideoIDs: [],
            excludingSongIdentities: [],
            context: context
        )
        let second = try await service.resolveOnYouTube(target)

        XCTAssertEqual(resolved.first?.youtubeResult.youtubeVideoID, "emergency01")
        XCTAssertEqual(second?.youtubeResult.youtubeVideoID, "emergency01")
        XCTAssertEqual(webRequests, 1)
        XCTAssertEqual(dataAPIRequests, 1)
        XCTAssertEqual(cache.storeCount, 1)
    }

    func testHealthyBufferDirectlyBlocksOfficialFallback() async throws {
        var dataAPIRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in [] },
            dataAPISearch: { _ in dataAPIRequests += 1; return [] },
            fallbackBudget: isolatedFallbackBudget()
        )

        let results = try await resolver.dataAPIFallbackResults(
            query: "Artist Song",
            context: resolutionContext(upcomingCount: 2)
        )

        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(dataAPIRequests, 0)
    }

    func testPerEpochOfficialFallbackLimitIsTwo() async throws {
        var dataAPIRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in [] },
            dataAPISearch: { _ in dataAPIRequests += 1; return [] },
            fallbackBudget: isolatedFallbackBudget()
        )
        let context = resolutionContext()

        for index in 0..<12 {
            _ = try await resolver.dataAPIFallbackResults(
                query: "Song \(index)",
                context: context
            )
        }

        XCTAssertEqual(dataAPIRequests, 2)
    }

    func testRadioSessionOfficialFallbackLimitIsSixAcrossEpochs() async throws {
        var dataAPIRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in [] },
            dataAPISearch: { _ in dataAPIRequests += 1; return [] },
            fallbackBudget: isolatedFallbackBudget()
        )
        let sessionID = UUID()

        for _ in 0..<4 {
            let context = resolutionContext(sessionID: sessionID)
            for index in 0..<4 {
                _ = try await resolver.dataAPIFallbackResults(
                    query: "Song \(index)",
                    context: context
                )
            }
        }

        XCTAssertEqual(dataAPIRequests, 6)
    }

    func testNewSeedResetsSessionBudgetButPreservesDailyUsage() {
        let budget = RecommendationDataAPIFallbackBudget(defaults: isolatedUserDefaults())
        let firstSession = UUID()
        for _ in 0..<3 {
            let epochID = UUID()
            _ = budget.reserveFallback(sessionID: firstSession, epochID: epochID)
            _ = budget.reserveFallback(sessionID: firstSession, epochID: epochID)
        }
        let newSessionReservation = budget.reserveFallback(
            sessionID: UUID(),
            epochID: UUID()
        )

        guard case .success(let usage) = newSessionReservation else {
            return XCTFail("Expected a new radio session allowance")
        }
        XCTAssertEqual(usage.session, 1)
        XCTAssertEqual(usage.daily, 7)
    }

    func testDailyBudgetPersistsAcrossResolverInstances() async throws {
        let defaults = isolatedUserDefaults()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var dataAPIRequests = 0

        for _ in 0..<2 {
            let budget = RecommendationDataAPIFallbackBudget(
                defaults: defaults,
                now: { date }
            )
            let resolver = YouTubeRecommendationResolver(
                primarySearch: { _ in [] },
                dataAPISearch: { _ in dataAPIRequests += 1; return [] },
                fallbackBudget: budget
            )
            for _ in 0..<3 {
                let context = resolutionContext()
                for index in 0..<2 {
                    _ = try await resolver.dataAPIFallbackResults(
                        query: "Song \(index)",
                        context: context
                    )
                }
            }
        }

        let restartedBudget = RecommendationDataAPIFallbackBudget(
            defaults: defaults,
            now: { date }
        )
        let restartedResolver = YouTubeRecommendationResolver(
            primarySearch: { _ in [] },
            dataAPISearch: { _ in dataAPIRequests += 1; return [] },
            fallbackBudget: restartedBudget
        )
        _ = try await restartedResolver.dataAPIFallbackResults(
            query: "Blocked after restart",
            context: resolutionContext()
        )

        XCTAssertEqual(dataAPIRequests, 10)
        XCTAssertEqual(restartedBudget.dailyCount(), 10)
    }

    func testDailyBudgetResetsOnCalendarDayChange() {
        let defaults = isolatedUserDefaults()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var date = Date(timeIntervalSince1970: 1_704_110_400)
        let budget = RecommendationDataAPIFallbackBudget(
            defaults: defaults,
            calendar: calendar,
            now: { date }
        )

        if case .failure = budget.reserveFallback(sessionID: UUID(), epochID: UUID()) {
            XCTFail("Expected fallback reservation")
        }
        XCTAssertEqual(budget.dailyCount(), 1)
        date = calendar.date(byAdding: .day, value: 1, to: date)!

        XCTAssertEqual(budget.dailyCount(), 0)
        if case .failure = budget.reserveFallback(sessionID: UUID(), epochID: UUID()) {
            XCTFail("Expected fallback reservation after day reset")
        }
        XCTAssertEqual(budget.dailyCount(), 1)
    }

    func testTwentyFourTrackBadWebEpochUsesAtMostTwoOfficialCalls() async throws {
        var webRequests = 0
        var dataAPIRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in
                webRequests += 1
                throw URLError(.httpTooManyRedirects)
            },
            dataAPISearch: { _ in dataAPIRequests += 1; return [] },
            fallbackBudget: isolatedFallbackBudget()
        )
        let context = resolutionContext()

        for index in 0..<24 {
            _ = try await resolver.primaryResults(query: "Song \(index)")
            _ = try await resolver.dataAPIFallbackResults(
                query: "Song \(index)",
                context: context
            )
        }

        XCTAssertEqual(webRequests, 1)
        XCTAssertEqual(dataAPIRequests, 2)
    }

    func testFiftyTrackBadWebRadioUsesAtMostSixOfficialCalls() async throws {
        var webRequests = 0
        var dataAPIRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in
                webRequests += 1
                throw YouTubeStructuredSearchClient.ClientError.httpStatus(403)
            },
            dataAPISearch: { _ in dataAPIRequests += 1; return [] },
            fallbackBudget: isolatedFallbackBudget()
        )
        let sessionID = UUID()
        let epochIDs = [UUID(), UUID(), UUID()]

        for index in 0..<50 {
            let context = resolutionContext(
                sessionID: sessionID,
                epochID: epochIDs[min(index / 24, 2)]
            )
            _ = try await resolver.primaryResults(query: "Song \(index)")
            _ = try await resolver.dataAPIFallbackResults(
                query: "Song \(index)",
                context: context
            )
        }

        XCTAssertEqual(webRequests, 1)
        XCTAssertEqual(dataAPIRequests, 6)
    }

}
