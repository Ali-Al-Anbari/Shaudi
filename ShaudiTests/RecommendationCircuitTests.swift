//
//  RecommendationCircuitTests.swift
//  ShaudiTests
//

import XCTest
@testable import Shaudi

@MainActor
final class RecommendationCircuitTests: XCTestCase {
    func testDataAPIQuotaOpensCircuitAfterOneRequest() async throws {
        var requestCount = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in [] },
            dataAPISearch: { _ in
                requestCount += 1
                throw YouTubeMetadataClient.ClientError.quotaExceeded
            },
            fallbackBudget: isolatedFallbackBudget()
        )
        let context = resolutionContext()

        let first = try await resolver.dataAPIFallbackResults(
            query: "Artist Song",
            context: context
        )
        let second = try await resolver.dataAPIFallbackResults(
            query: "Another Song",
            context: context
        )

        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(resolver.isDataAPIQuotaCircuitOpen)
    }

    func testTooManyRedirectsOpensWebCircuitAfterOneRequest() async throws {
        var requestCount = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in
                requestCount += 1
                throw URLError(.httpTooManyRedirects)
            },
            dataAPISearch: { _ in [] }
        )

        let first = try await resolver.primaryResults(query: "First")
        let second = try await resolver.primaryResults(query: "Second")
        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(resolver.isWebSearchCircuitOpen)
    }

    func testHTTP429OpensWebCircuitAfterOneRequest() async throws {
        var requestCount = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in
                requestCount += 1
                throw YouTubeStructuredSearchClient.ClientError.httpStatus(429)
            },
            dataAPISearch: { _ in [] }
        )

        _ = try await resolver.primaryResults(query: "First")
        _ = try await resolver.primaryResults(query: "Second")
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(resolver.isWebSearchCircuitOpen)
    }

    func testCandidateSpecificWebMissDoesNotOpenCircuit() async throws {
        var requestCount = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in requestCount += 1; return [] },
            dataAPISearch: { _ in [] }
        )

        _ = try await resolver.primaryResults(query: "First")
        _ = try await resolver.primaryResults(query: "Second")

        XCTAssertEqual(requestCount, 2)
        XCTAssertFalse(resolver.isWebSearchCircuitOpen)
    }

    func testWebCircuitCooldownAllowsHalfOpenProbeAndSuccessfulRecovery() async throws {
        var date = Date(timeIntervalSince1970: 10_000)
        var requestCount = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in
                requestCount += 1
                if requestCount == 1 {
                    throw URLError(.httpTooManyRedirects)
                }
                return []
            },
            dataAPISearch: { _ in [] },
            now: { date }
        )

        _ = try await resolver.primaryOutcome(query: "blocked")
        date.addTimeInterval(RecommendationRadioPolicy.webCircuitCooldown - 1)
        let blocked = try await resolver.primaryOutcome(query: "too early")
        if case .circuitOpen = blocked {} else {
            XCTFail("Expected the circuit to remain open before cooldown")
        }
        XCTAssertEqual(requestCount, 1)

        date.addTimeInterval(2)
        _ = try await resolver.primaryOutcome(query: "probe")
        XCTAssertFalse(resolver.isWebSearchCircuitOpen)
        _ = try await resolver.primaryOutcome(query: "normal")
        XCTAssertEqual(requestCount, 3)
    }

    func testHalfOpenSystemicFailureReopensCircuit() async throws {
        var date = Date(timeIntervalSince1970: 20_000)
        var requestCount = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in
                requestCount += 1
                throw URLError(.httpTooManyRedirects)
            },
            dataAPISearch: { _ in [] },
            now: { date }
        )

        _ = try await resolver.primaryOutcome(query: "initial")
        date.addTimeInterval(RecommendationRadioPolicy.webCircuitCooldown + 1)
        _ = try await resolver.primaryOutcome(query: "failed probe")
        _ = try await resolver.primaryOutcome(query: "blocked again")

        XCTAssertEqual(requestCount, 2)
        XCTAssertTrue(resolver.isWebSearchCircuitOpen)
    }

    func testOnlyOneHalfOpenProbeCanRun() async throws {
        var date = Date(timeIntervalSince1970: 30_000)
        var requestCount = 0
        let gate = AsyncSearchGate()
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in
                requestCount += 1
                if requestCount == 1 {
                    throw URLError(.httpTooManyRedirects)
                }
                await gate.suspendUntilReleased()
                return []
            },
            dataAPISearch: { _ in [] },
            now: { date }
        )
        _ = try await resolver.primaryOutcome(query: "initial")
        date.addTimeInterval(RecommendationRadioPolicy.webCircuitCooldown + 1)

        let probe = Task { try await resolver.primaryOutcome(query: "probe") }
        await gate.waitUntilStarted()
        let simultaneous = try await resolver.primaryOutcome(query: "simultaneous")
        if case .circuitOpen = simultaneous {} else {
            XCTFail("Expected a second half-open request to be rejected")
        }
        XCTAssertEqual(requestCount, 2)
        await gate.release()
        _ = try await probe.value
    }

    func testTransientNetworkFailureRecoversAfterShortCooldown() async throws {
        var date = Date(timeIntervalSince1970: 40_000)
        var requestCount = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in
                requestCount += 1
                if requestCount == 1 {
                    throw URLError(.timedOut)
                }
                return []
            },
            dataAPISearch: { _ in [] },
            now: { date }
        )

        _ = try await resolver.primaryOutcome(query: "timeout")
        _ = try await resolver.primaryOutcome(query: "temporarily blocked")
        XCTAssertEqual(requestCount, 1)
        date.addTimeInterval(RecommendationRadioPolicy.transientWebCooldown + 1)
        _ = try await resolver.primaryOutcome(query: "probe")

        XCTAssertEqual(requestCount, 2)
        XCTAssertFalse(resolver.isWebSearchCircuitOpen)
    }

    func testSystemicWebFailureDoesNotRepeatedlyInvokeWebOrDataAPI() async throws {
        var webRequests = 0
        var dataAPIRequests = 0
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in
                webRequests += 1
                throw URLError(.httpTooManyRedirects)
            },
            dataAPISearch: { _ in
                dataAPIRequests += 1
                return []
            },
            fallbackBudget: isolatedFallbackBudget()
        )
        let context = resolutionContext()

        for index in 0..<20 {
            _ = try await resolver.primaryResults(query: "Song \(index)")
            _ = try await resolver.dataAPIFallbackResults(
                query: "Song \(index)",
                context: context
            )
        }

        XCTAssertEqual(webRequests, 1)
        XCTAssertEqual(dataAPIRequests, 2)
    }

    func testBothResolverCircuitsOpenWithoutRepeatedAttempts() async throws {
        var webRequestCount = 0
        var dataAPIRequestCount = 0
        let originalQueue = ["already-queued-1", "already-queued-2"]
        var queue = originalQueue
        let resolver = YouTubeRecommendationResolver(
            primarySearch: { _ in
                webRequestCount += 1
                throw URLError(.httpTooManyRedirects)
            },
            dataAPISearch: { _ in
                dataAPIRequestCount += 1
                throw YouTubeMetadataClient.ClientError.quotaExceeded
            },
            fallbackBudget: isolatedFallbackBudget()
        )
        let context = resolutionContext()

        for query in ["First", "Second", "Third"] {
            let web = try await resolver.primaryResults(query: query)
            let dataAPI = try await resolver.dataAPIFallbackResults(
                query: query,
                context: context
            )
            if !web.isEmpty || !dataAPI.isEmpty {
                queue.append(query)
            }
        }

        XCTAssertEqual(webRequestCount, 1)
        XCTAssertEqual(dataAPIRequestCount, 1)
        XCTAssertEqual(queue, originalQueue)
    }

}
