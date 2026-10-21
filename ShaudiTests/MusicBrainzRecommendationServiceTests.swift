import Foundation
import XCTest
@testable import Shaudi

@MainActor
final class MusicBrainzRecommendationServiceTests: XCTestCase {
    private let original = "0262bdd4-3e27-420c-ad79-a2b934c40b6c"
    private let artistID = "8837b875-3689-4646-b3fd-d8b53815c7a8"

    func testExactMatchAndRequestConstruction() async throws {
        let fixture = response(recordings: [recording(title: "Silly Watch", score: "100")])
        let (service, requests) = makeService(data: Data(fixture.utf8))
        let match = try await service.recording(artist: "Lil Uzi Vert", title: "Silly Watch")
        XCTAssertEqual(match?.recordingMBID.uuidString.lowercased(), original)
        XCTAssertEqual(match?.artistMBID.uuidString.lowercased(), artistID)
        XCTAssertEqual(match?.searchScore, 100)
        XCTAssertEqual(match?.confidence, "high")
        XCTAssertEqual(requests.requests.count, 1)
        let request = try XCTUnwrap(requests.requests.first)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertTrue(components.queryItems?.contains(URLQueryItem(name: "fmt", value: "json")) == true)
        XCTAssertTrue(components.queryItems?.contains(URLQueryItem(name: "limit", value: "10")) == true)
        XCTAssertTrue((request.value(forHTTPHeaderField: "User-Agent") ?? "").contains("Shaudi/"))
    }

    func testLiveMusicBrainzNumericSearchScoreDecodes() async throws {
        let fixture = response(recordings: [
            recording(title: "Silly Watch", score: "100")
                .replacingOccurrences(of: "\"score\":\"100\"", with: "\"score\":100")
        ])
        let (service, _) = makeService(data: Data(fixture.utf8))
        let match = try await service.recording(artist: "Lil Uzi Vert", title: "Silly Watch")
        XCTAssertEqual(match?.searchScore, 100)
    }

    func testPunctuationAndTopicMetadataNormalizeWithoutLosingVersion() async throws {
        let fixture = response(recordings: [recording(title: "Silly Watch!", score: "100")])
        let (service, _) = makeService(data: Data(fixture.utf8))
        let match = try await service.recording(
            artist: "Lil Uzi Vert - Topic",
            title: "Silly Watch (Official Audio)"
        )
        XCTAssertNotNil(match)
    }

    func testVerifiedArtistNameAliasCanMatch() async throws {
        let fixture = response(recordings: [recording(
            title: "Silly Watch", score: "100", alias: "Baby Pluto"
        )])
        let (service, _) = makeService(data: Data(fixture.utf8))
        let match = try await service.recording(artist: "Baby Pluto", title: "Silly Watch")
        XCTAssertNotNil(match)
    }

    func testFeaturedArtistJoinPhraseDoesNotBreakDecoding() async throws {
        let credited = recording(title: "Silly Watch", score: "100")
            .replacingOccurrences(
                of: "}}]}",
                with: "}},\" feat. \",{\"name\":\"Guest\",\"artist\":{\"id\":\"f802669f-45aa-4ec6-8221-26a73739e440\",\"name\":\"Guest\"}}]}"
            )
        let (service, _) = makeService(data: Data(response(recordings: [credited]).utf8))
        let match = try await service.recording(artist: "Lil Uzi Vert", title: "Silly Watch")
        XCTAssertNotNil(match)
        let guestOnly = try await service.recording(artist: "Guest", title: "Silly Watch")
        XCTAssertNil(guestOnly)
    }

    func testLiveAndRemixVersionMismatchesAreRejected() async throws {
        let fixture = response(recordings: [
            recording(title: "Silly Watch (Live)", score: "100"),
            recording(title: "Silly Watch (Remix)", score: "100")
        ])
        let (service, _) = makeService(data: Data(fixture.utf8))
        let match = try await service.recording(artist: "Lil Uzi Vert", title: "Silly Watch")
        XCTAssertNil(match)
    }

    func testLowScoreAndAmbiguousExactResultsAreRejected() async throws {
        let low = response(recordings: [recording(title: "Silly Watch", score: "90")])
        let (lowService, _) = makeService(data: Data(low.utf8))
        let lowMatch = try await lowService.recording(artist: "Lil Uzi Vert", title: "Silly Watch")
        XCTAssertNil(lowMatch)

        let second = recording(
            id: "5bd60198-2cfa-4c6a-9343-1d676023ccef",
            title: "Silly Watch", score: "99"
        )
        let ambiguous = response(recordings: [recording(title: "Silly Watch", score: "100"), second])
        let (ambiguousService, _) = makeService(data: Data(ambiguous.utf8))
        let ambiguousMatch = try await ambiguousService.recording(artist: "Lil Uzi Vert", title: "Silly Watch")
        XCTAssertNil(ambiguousMatch)
    }

    func testNoResultAndMalformedResponse() async throws {
        let (empty, _) = makeService(data: Data(#"{"recordings":[]}"#.utf8))
        let emptyMatch = try await empty.recording(artist: "Lil Uzi Vert", title: "Silly Watch")
        XCTAssertNil(emptyMatch)
        let (malformed, _) = makeService(data: Data(#"{"recordings":{}}"#.utf8))
        do {
            _ = try await malformed.recording(artist: "Lil Uzi Vert", title: "Silly Watch")
            XCTFail("Expected malformed response")
        } catch MusicBrainzRecommendationService.LookupError.malformedResponse {}
    }

    func testSuccessfulMatchUsesPersistentCacheAndLowConfidenceDoesNot() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = response(recordings: [recording(title: "Silly Watch", score: "100")])
        let (service, requests) = makeService(data: Data(fixture.utf8), cacheFile: file)
        _ = try await service.recording(artist: "Lil Uzi Vert", title: "Silly Watch")
        _ = try await service.recording(artist: "Lil Uzi Vert", title: "Silly Watch")
        XCTAssertEqual(requests.requests.count, 1)
        let (secondService, secondRequests) = makeService(data: Data(#"{"recordings":[]}"#.utf8), cacheFile: file)
        let cachedMatch = try await secondService.recording(artist: "Lil Uzi Vert", title: "Silly Watch")
        XCTAssertNotNil(cachedMatch)
        XCTAssertEqual(secondRequests.requests.count, 0)

        let low = response(recordings: [recording(title: "Silly Watch", score: "80")])
        let (lowService, lowRequests) = makeService(data: Data(low.utf8))
        _ = try await lowService.recording(artist: "Lil Uzi Vert", title: "Silly Watch")
        _ = try await lowService.recording(artist: "Lil Uzi Vert", title: "Silly Watch")
        XCTAssertEqual(lowRequests.requests.count, 2)
    }

    func testHTTP503RetriesOnceThenSucceeds() async throws {
        let fixture = Data(response(recordings: [recording(title: "Silly Watch", score: "100")]).utf8)
        let (service, recorder) = makeService(responses: [.http(503, Data()), .http(200, fixture)])
        let match = try await service.recording(artist: "Lil Uzi Vert", title: "Silly Watch")
        XCTAssertNotNil(match)
        XCTAssertEqual(recorder.requests.count, 2)
    }

    func testSecondHTTP503StopsAnd404DoesNotRetry() async throws {
        let (transient, transientRecorder) = makeService(responses: [
            .http(503, Data()), .http(503, Data())
        ])
        do {
            _ = try await transient.recording(artist: "Lil Uzi Vert", title: "Silly Watch")
            XCTFail("Expected HTTP 503")
        } catch MusicBrainzRecommendationService.LookupError.httpStatus(let status) {
            XCTAssertEqual(status, 503)
        }
        XCTAssertEqual(transientRecorder.requests.count, 2)

        let (permanent, permanentRecorder) = makeService(responses: [.http(404, Data())])
        do {
            _ = try await permanent.recording(artist: "Lil Uzi Vert", title: "Silly Watch")
            XCTFail("Expected HTTP 404")
        } catch MusicBrainzRecommendationService.LookupError.httpStatus(let status) {
            XCTAssertEqual(status, 404)
        }
        XCTAssertEqual(permanentRecorder.requests.count, 1)
    }

    func testTimeoutRetriesOnceAndKeepsProviderSpecificError() async throws {
        let (service, recorder) = makeService(responses: [
            .failure(URLError(.timedOut)), .failure(URLError(.timedOut))
        ])
        do {
            _ = try await service.recording(artist: "Lil Uzi Vert", title: "Silly Watch")
            XCTFail("Expected timeout")
        } catch MusicBrainzRecommendationService.LookupError.transport(let code) {
            XCTAssertEqual(code, .timedOut)
        }
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertEqual(
            MusicBrainzRecommendationService.LookupError.transport(.timedOut).localizedDescription,
            "MusicBrainz timeout"
        )
    }

    func testCancellationDuringBackoffPreventsSecondRequest() async throws {
        let firstRequest = expectation(description: "first MusicBrainz request")
        let (service, recorder) = makeService(
            responses: [.http(503, Data()), .http(200, Data())],
            retryDelayNanoseconds: 2_000_000_000,
            onRequest: { count in if count == 1 { firstRequest.fulfill() } }
        )
        let task = Task {
            try await service.recording(artist: "Lil Uzi Vert", title: "Silly Watch")
        }
        await fulfillment(of: [firstRequest], timeout: 3)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testCacheIsPersistedBeforeListenBrainzHandoff() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = Data(response(recordings: [recording(title: "Silly Watch", score: "100")]).utf8)
        let (service, recorder) = makeService(responses: [.http(200, fixture)], cacheFile: file)
        var handoffCount = 0
        let fallback = RadioListenBrainzFallback(
            recordingLookup: { artist, title in
                try await service.recording(artist: artist, title: title)
            },
            similarLookup: { mbid in
                handoffCount += 1
                let reopened = MusicBrainzRecordingCache(fileURL: file)
                let key = SongNormalization.text("Lil Uzi Vert") + "\u{1F}"
                    + SongNormalization.text("Silly Watch")
                let persisted = await reopened.identity(for: key)
                XCTAssertEqual(persisted?.recordingMBID, mbid)
                return []
            }
        )
        let seed = RecommendationSeed(
            youtubeVideoID: "sillywatch1",
            canonicalIdentity: SongIdentity(artist: "Lil Uzi Vert", title: "Silly Watch"),
            youtubeTitle: "Lil Uzi Vert - Silly Watch", youtubeChannel: "Lil Uzi Vert"
        )
        _ = try await fallback.candidates(for: seed, baseMatch: 0.5, limit: 50)
        XCTAssertEqual(handoffCount, 1)
        XCTAssertEqual(recorder.requests.count, 1)
    }

    private func makeService(
        data: Data, cacheFile: URL? = nil
    ) -> (MusicBrainzRecommendationService, MusicBrainzRequestRecorder) {
        makeService(responses: [.http(200, data)], cacheFile: cacheFile)
    }

    private func makeService(
        responses: [MusicBrainzFixtureReply],
        cacheFile: URL? = nil,
        retryDelayNanoseconds: UInt64 = 0,
        onRequest: ((Int) -> Void)? = nil
    ) -> (MusicBrainzRecommendationService, MusicBrainzRequestRecorder) {
        let recorder = MusicBrainzRequestRecorder(responses: responses, onRequest: onRequest)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MusicBrainzFixtureURLProtocol.self]
        MusicBrainzFixtureURLProtocol.recorder = recorder
        let cache = MusicBrainzRecordingCache(
            fileURL: cacheFile ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        return (MusicBrainzRecommendationService(
            session: URLSession(configuration: configuration), cache: cache,
            rateLimiter: nil, retryDelayNanoseconds: retryDelayNanoseconds
        ), recorder)
    }

    private func response(recordings: [String]) -> String {
        "{\"recordings\":[\(recordings.joined(separator: ","))]}"
    }

    private func recording(
        id: String? = nil, title: String, score: String, alias: String? = nil
    ) -> String {
        let aliasJSON = alias.map { #", "aliases":[{"name":"\#($0)","type":"Artist name"}]"# } ?? ""
        return """
        {"id":"\(id ?? original)","score":"\(score)","title":"\(title)",
         "artist-credit":[{"name":"Lil Uzi Vert","artist":{
           "id":"\(artistID)","name":"Lil Uzi Vert"\(aliasJSON)}}]}
        """
    }
}

private enum MusicBrainzFixtureReply {
    case http(Int, Data)
    case failure(URLError)
}

private final class MusicBrainzRequestRecorder {
    private let responses: [MusicBrainzFixtureReply]
    private let onRequest: ((Int) -> Void)?
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    init(responses: [MusicBrainzFixtureReply], onRequest: ((Int) -> Void)?) {
        self.responses = responses
        self.onRequest = onRequest
    }

    func reply(for request: URLRequest) -> MusicBrainzFixtureReply {
        lock.lock()
        let index = recordedRequests.count
        recordedRequests.append(request)
        let reply = responses[min(index, responses.count - 1)]
        lock.unlock()
        onRequest?(index + 1)
        return reply
    }
}

private final class MusicBrainzFixtureURLProtocol: URLProtocol {
    static var recorder: MusicBrainzRequestRecorder?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let recorder = Self.recorder, let url = request.url else { return }
        switch recorder.reply(for: request) {
        case .http(let status, let data):
            guard let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: nil
            ) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
