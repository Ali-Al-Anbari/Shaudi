//
//  YouTubeRecommendationSearchClient.swift
//  Shaudi
//

import Foundation

@MainActor
final class RecommendationDataAPIFallbackBudget {
    enum ExhaustionReason: Error, Equatable {
        case epochBudgetExhausted
        case sessionBudgetExhausted
        case dailyBudgetExhausted
    }

    struct Usage: Equatable {
        let epoch: Int
        let session: Int
        let daily: Int
    }

    private enum Keys {
        static let dailyCount = "shaudi.recommendations.dataAPIFallback.dailyCount"
        static let dailyDate = "shaudi.recommendations.dataAPIFallback.dailyDate"
    }

    private let defaults: UserDefaults
    private let calendar: Calendar
    private let now: () -> Date
    private var epochCounts: [UUID: Int] = [:]
    private var sessionCounts: [UUID: Int] = [:]

    init(
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
    }

    func reserveFallback(
        sessionID: UUID,
        epochID: UUID
    ) -> Result<Usage, ExhaustionReason> {
        let date = now()
        let daily = currentDailyCount(at: date)
        let epoch = epochCounts[epochID, default: 0]
        let session = sessionCounts[sessionID, default: 0]
        guard epoch < RecommendationRadioPolicy.maxDataAPIFallbacksPerEpoch else {
            return .failure(.epochBudgetExhausted)
        }
        guard session < RecommendationRadioPolicy.maxDataAPIFallbacksPerRadioSession else {
            return .failure(.sessionBudgetExhausted)
        }
        guard daily < RecommendationRadioPolicy.maxDataAPIFallbacksPerDay else {
            return .failure(.dailyBudgetExhausted)
        }

        let usage = Usage(epoch: epoch + 1, session: session + 1, daily: daily + 1)
        epochCounts[epochID] = usage.epoch
        sessionCounts[sessionID] = usage.session
        defaults.set(usage.daily, forKey: Keys.dailyCount)
        defaults.set(calendar.startOfDay(for: date), forKey: Keys.dailyDate)
        return .success(usage)
    }

    func dailyCount() -> Int {
        currentDailyCount(at: now())
    }

    private func currentDailyCount(at date: Date) -> Int {
        guard
            let storedDate = defaults.object(forKey: Keys.dailyDate) as? Date,
            calendar.isDate(storedDate, inSameDayAs: date)
        else {
            defaults.set(0, forKey: Keys.dailyCount)
            defaults.set(calendar.startOfDay(for: date), forKey: Keys.dailyDate)
            return 0
        }
        return max(0, defaults.integer(forKey: Keys.dailyCount))
    }
}

@MainActor
final class YouTubeRecommendationResolver {
    typealias SearchOperation = (String) async throws -> [YouTubeSearchResult]

    enum WebCircuitState: Equatable {
        case closed
        case open(until: Date)
        case halfOpen
    }

    enum WebSearchOutcome {
        case results([YouTubeSearchResult])
        case temporarilyUnavailable
        case blocked
        case parserFailure
        case circuitOpen
    }

    enum DataAPIFallbackUnavailableReason: Equatable {
        case quotaCircuitOpen
        case bufferHealthy
        case epochBudgetExhausted
        case sessionBudgetExhausted
        case dailyBudgetExhausted
        case staleSession
    }

    enum DataAPIFallbackOutcome {
        case results([YouTubeSearchResult])
        case unavailable(DataAPIFallbackUnavailableReason)
    }

    private enum WebFailureKind {
        case blocking
        case transient
        case parser
    }

    private let primarySearch: SearchOperation
    private let dataAPISearch: SearchOperation
    private let fallbackBudget: RecommendationDataAPIFallbackBudget
    private let now: () -> Date
    private(set) var webCircuitState: WebCircuitState = .closed
    private var isHalfOpenProbeInFlight = false
    private(set) var isDataAPIQuotaCircuitOpen = false

    var isWebSearchCircuitOpen: Bool {
        switch webCircuitState {
        case .closed:
            return false
        case .open(let until):
            return now() < until
        case .halfOpen:
            return true
        }
    }

    init(
        structuredSearchClient: YouTubeStructuredSearchClient? = nil,
        dataAPIClient: YouTubeMetadataClient? = nil
    ) {
        let structuredSearchClient = structuredSearchClient
            ?? YouTubeStructuredSearchClient()
        let dataAPIClient = dataAPIClient ?? YouTubeMetadataClient()
        primarySearch = { query in
            try await structuredSearchClient.search(query: query).map(\.searchResult)
        }
        dataAPISearch = { query in
            try await dataAPIClient.search(query: query).results
        }
        fallbackBudget = RecommendationDataAPIFallbackBudget()
        now = Date.init
    }

    init(
        primarySearch: @escaping SearchOperation,
        dataAPISearch: @escaping SearchOperation,
        fallbackBudget: RecommendationDataAPIFallbackBudget? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.primarySearch = primarySearch
        self.dataAPISearch = dataAPISearch
        self.fallbackBudget = fallbackBudget ?? RecommendationDataAPIFallbackBudget()
        self.now = now
    }

    func primaryOutcome(
        query: String,
        isActive: @escaping () -> Bool = { true }
    ) async throws -> WebSearchOutcome {
        guard isActive() else {
            throw CancellationError()
        }
        let isHalfOpenProbe: Bool
        switch webCircuitState {
        case .closed:
            isHalfOpenProbe = false
        case .open(let until):
            guard now() >= until else {
#if DEBUG
                let remaining = max(0, until.timeIntervalSince(now()))
                print("[RecommendationResolver] webCircuit state=open cooldownRemaining=\(Int(remaining))")
#endif
                return .circuitOpen
            }
            webCircuitState = .halfOpen
            fallthrough
        case .halfOpen:
            guard !isHalfOpenProbeInFlight else {
                return .circuitOpen
            }
            isHalfOpenProbeInFlight = true
            isHalfOpenProbe = true
#if DEBUG
            print("[RecommendationResolver] webCircuit state=halfOpen probe=true")
#endif
        }
#if DEBUG
        print("[IDResolver] source=structured target=\(query)")
#endif
        do {
            let results = try await primarySearch(query)
            try Task.checkCancellation()
            guard isActive() else {
                throw CancellationError()
            }
            if isHalfOpenProbe {
                isHalfOpenProbeInFlight = false
                webCircuitState = .closed
#if DEBUG
                print("[RecommendationResolver] webCircuit recovered=true")
#endif
            }
            return .results(results)
        } catch is CancellationError {
            if isHalfOpenProbe {
                isHalfOpenProbeInFlight = false
            }
            throw CancellationError()
        } catch {
            if isHalfOpenProbe {
                isHalfOpenProbeInFlight = false
            }
            try Task.checkCancellation()
            guard isActive() else {
                throw CancellationError()
            }
            let failureKind = Self.webFailureKind(for: error)
            switch failureKind {
            case .blocking:
                openWebCircuit(for: RecommendationRadioPolicy.webCircuitCooldown)
            case .transient:
                openWebCircuit(for: RecommendationRadioPolicy.transientWebCooldown)
            case .parser:
                openWebCircuit(for: RecommendationRadioPolicy.webCircuitCooldown)
            }
#if DEBUG
            print("[IDResolver] structuredFailure=\(error.localizedDescription)")
#endif
            switch failureKind {
            case .blocking: return .blocked
            case .transient: return .temporarilyUnavailable
            case .parser: return .parserFailure
            }
        }
    }

    func primaryResults(query: String) async throws -> [YouTubeSearchResult] {
        if case .results(let results) = try await primaryOutcome(query: query) {
            return results
        }
        return []
    }

    private func openWebCircuit(for duration: TimeInterval) {
        let until = now().addingTimeInterval(duration)
        webCircuitState = .open(until: until)
#if DEBUG
        print("[RecommendationResolver] webCircuit state=open cooldownRemaining=\(Int(duration))")
#endif
    }

    private static func webFailureKind(for error: Error) -> WebFailureKind {
        if let structuredError = error as? YouTubeStructuredSearchClient.ClientError {
            switch structuredError {
            case .httpStatus(let statusCode):
                return statusCode == 403 || statusCode == 429
                    ? .blocking
                    : .transient
            case .network:
                return .transient
            case .invalidRequest, .invalidResponse, .malformedResponse:
                return .parser
            }
        }
        let urlError = error as? URLError
        if urlError?.code == .httpTooManyRedirects {
            return .blocking
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           nsError.code == URLError.Code.httpTooManyRedirects.rawValue {
            return .blocking
        }
        return .transient
    }

    func dataAPIFallbackOutcome(
        query: String,
        context: RecommendationResolutionContext
    ) async throws -> DataAPIFallbackOutcome {
        guard context.isActive else {
            return .unavailable(.staleSession)
        }
        guard !isDataAPIQuotaCircuitOpen else {
#if DEBUG
            print("[RecommendationResolver] dataAPIQuotaCircuitOpen=true")
#endif
            return .unavailable(.quotaCircuitOpen)
        }

        let currentUpcomingCount = context.currentUpcomingCount()
#if DEBUG
        print("[RecommendationResolver] fallbackUpcomingCount current=\(currentUpcomingCount)")
#endif
        guard currentUpcomingCount <= RecommendationRadioPolicy.criticalUpcomingCount else {
#if DEBUG
            print("[RecommendationResolver] dataAPIFallbackSkipped reason=bufferHealthy")
#endif
            return .unavailable(.bufferHealthy)
        }

        let reservation = fallbackBudget.reserveFallback(
            sessionID: context.sessionID,
            epochID: context.epochID
        )
        guard case .success(let usage) = reservation else {
            let reason: DataAPIFallbackUnavailableReason
            switch reservation {
            case .failure(.epochBudgetExhausted): reason = .epochBudgetExhausted
            case .failure(.sessionBudgetExhausted): reason = .sessionBudgetExhausted
            case .failure(.dailyBudgetExhausted): reason = .dailyBudgetExhausted
            case .success: fatalError("Handled by guard")
            }
#if DEBUG
            print("[RecommendationResolver] dataAPIFallbackSkipped reason=\(reason)")
#endif
            return .unavailable(reason)
        }

#if DEBUG
        print("[RecommendationResolver] officialFallback reason=criticalBuffer target=\(query)")
        print(
            "[RecommendationResolver] dataAPIBudget "
                + "epoch=\(usage.epoch)/\(RecommendationRadioPolicy.maxDataAPIFallbacksPerEpoch) "
                + "session=\(usage.session)/\(RecommendationRadioPolicy.maxDataAPIFallbacksPerRadioSession) "
                + "daily=\(usage.daily)/\(RecommendationRadioPolicy.maxDataAPIFallbacksPerDay)"
        )
#endif
        do {
            let results = try await dataAPISearch(query)
            try Task.checkCancellation()
            guard context.isActive else {
                throw CancellationError()
            }
            return .results(results)
        } catch YouTubeMetadataClient.ClientError.quotaExceeded {
            try Task.checkCancellation()
            guard context.isActive else {
                throw CancellationError()
            }
            isDataAPIQuotaCircuitOpen = true
#if DEBUG
            print("[RecommendationResolver] dataAPIQuotaCircuitOpen=true")
#endif
            return .unavailable(.quotaCircuitOpen)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
#if DEBUG
            print("[RecommendationResolver] DataAPI failed=\(error.localizedDescription)")
#endif
            return .results([])
        }
    }

    func dataAPIFallbackResults(
        query: String,
        context: RecommendationResolutionContext
    ) async throws -> [YouTubeSearchResult] {
        if case .results(let results) = try await dataAPIFallbackOutcome(
            query: query,
            context: context
        ) {
            return results
        }
        return []
    }
}
