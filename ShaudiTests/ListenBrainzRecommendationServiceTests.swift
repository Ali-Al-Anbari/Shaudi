import Foundation
import XCTest
@testable import Shaudi

@MainActor
final class ListenBrainzRecommendationServiceTests: XCTestCase {
    func testValidSimilarRecordingsDecodeAndMapInRankOrder() async throws {
        let json = """
        [
          {"recording_mbid":"f802669f-45aa-4ec6-8221-26a73739e440","recording_name":"R.I.P.","artist_credit_name":"Playboi Carti","artist_credit_mbids":null,"score":60},
          {"recording_mbid":"d3ff669f-45aa-4ec6-8221-26a73739e440","recording_name":"Second Song","artist_credit_name":"Another Artist","artist_credit_mbids":["8837b875-3689-4646-b3fd-d8b53815c7a8"],"score":40}
        ]
        """
        let (service, recorder) = makeService(json: json)
        let seed = UUID(uuidString: "0262bdd4-3e27-420c-ad79-a2b934c40b6c")!
        let recordings = try await service.similarRecordings(to: seed)
        XCTAssertEqual(recordings.count, 2)
        XCTAssertEqual(recordings[0].title, "R.I.P.")
        XCTAssertNil(recordings[0].artistMBIDs)
        XCTAssertEqual(recordings[1].artistMBIDs?.count, 1)
        let candidates = ListenBrainzRecommendationService.candidates(
            from: recordings, limit: 50, baseMatch: 0.5
        )
        XCTAssertEqual(candidates.map(\.title), ["R.I.P.", "Second Song"])
        XCTAssertGreaterThan(candidates[0].match, candidates[1].match)
        let url = try XCTUnwrap(recorder.requests.first?.url)
        let parameters = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertTrue(parameters?.contains(URLQueryItem(name: "recording_mbids", value: seed.uuidString.lowercased())) == true)
        XCTAssertTrue(parameters?.contains(URLQueryItem(name: "algorithm", value: ListenBrainzRecommendationService.algorithm)) == true)
    }

    func testEmptyAndMalformedResponses() async throws {
        let (empty, _) = makeService(json: "[]")
        let emptyResults = try await empty.similarRecordings(to: UUID())
        XCTAssertTrue(emptyResults.isEmpty)
        let (malformed, _) = makeService(json: #"{"payload":[]}"#)
        do {
            _ = try await malformed.similarRecordings(to: UUID())
            XCTFail("Expected malformed response")
        } catch ListenBrainzRecommendationService.SimilarError.malformedResponse {}
    }

    func testBlankAndDuplicateCandidatesAreDroppedAndLimitIsRespected() throws {
        let data = Data("""
        [
          {"recording_mbid":"f802669f-45aa-4ec6-8221-26a73739e440","recording_name":"R.I.P.","artist_credit_name":"Playboi Carti","score":60},
          {"recording_mbid":"f802669f-45aa-4ec6-8221-26a73739e440","recording_name":"R.I.P.","artist_credit_name":"Playboi Carti","score":50},
          {"recording_mbid":"d3ff669f-45aa-4ec6-8221-26a73739e440","recording_name":"   ","artist_credit_name":"Artist","score":40},
          {"recording_mbid":"c3ff669f-45aa-4ec6-8221-26a73739e440","recording_name":"Song","artist_credit_name":"   ","score":30},
          {"recording_mbid":"b3ff669f-45aa-4ec6-8221-26a73739e440","recording_name":"Second","artist_credit_name":"Other","score":20}
        ]
        """.utf8)
        let recordings = try JSONDecoder().decode([ListenBrainzSimilarRecording].self, from: data)
        let candidates = ListenBrainzRecommendationService.candidates(
            from: recordings, limit: 1, baseMatch: 0.5
        )
        XCTAssertEqual(candidates.map(\.title), ["R.I.P."])
        XCTAssertEqual(ListenBrainzRecommendationService.candidates(
            from: recordings, limit: 50, baseMatch: 0.5
        ).map(\.title), ["R.I.P.", "Second"])
    }

    func testHTTP503RetriesOnceThenSucceeds() async throws {
        let (service, recorder) = makeService(responses: [
            .http(503, Data()), .http(200, Data("[]".utf8))
        ])
        let candidates = try await service.similarRecordings(to: UUID())
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertEqual(recorder.requests.count, 2)
    }

    func testSecondHTTP503StopsAnd4xxDoesNotRetry() async throws {
        let (transient, transientRecorder) = makeService(responses: [
            .http(503, Data()), .http(503, Data())
        ])
        do {
            _ = try await transient.similarRecordings(to: UUID())
            XCTFail("Expected HTTP 503")
        } catch ListenBrainzRecommendationService.SimilarError.httpStatus(let status) {
            XCTAssertEqual(status, 503)
        }
        XCTAssertEqual(transientRecorder.requests.count, 2)

        let (permanent, permanentRecorder) = makeService(responses: [.http(403, Data())])
        do {
            _ = try await permanent.similarRecordings(to: UUID())
            XCTFail("Expected HTTP 403")
        } catch ListenBrainzRecommendationService.SimilarError.httpStatus(let status) {
            XCTAssertEqual(status, 403)
        }
        XCTAssertEqual(permanentRecorder.requests.count, 1)
    }

    func testTimeoutErrorNamesListenBrainzAndRetriesOnce() async throws {
        let (service, recorder) = makeService(responses: [
            .failure(URLError(.timedOut)), .failure(URLError(.timedOut))
        ])
        do {
            _ = try await service.similarRecordings(to: UUID())
            XCTFail("Expected timeout")
        } catch ListenBrainzRecommendationService.SimilarError.transport(let code) {
            XCTAssertEqual(code, .timedOut)
        }
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertEqual(
            ListenBrainzRecommendationService.SimilarError.transport(.timedOut).localizedDescription,
            "ListenBrainz timeout"
        )
    }

    private func makeService(json: String) -> (ListenBrainzRecommendationService, ListenBrainzRequestRecorder) {
        makeService(responses: [.http(200, Data(json.utf8))])
    }

    private func makeService(
        responses: [ListenBrainzFixtureReply]
    ) -> (ListenBrainzRecommendationService, ListenBrainzRequestRecorder) {
        let recorder = ListenBrainzRequestRecorder(responses: responses)
        ListenBrainzFixtureURLProtocol.recorder = recorder
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ListenBrainzFixtureURLProtocol.self]
        return (ListenBrainzRecommendationService(
            session: URLSession(configuration: configuration),
            rateLimiter: nil, retryDelayNanoseconds: 0
        ), recorder)
    }
}

private enum ListenBrainzFixtureReply {
    case http(Int, Data)
    case failure(URLError)
}

private final class ListenBrainzRequestRecorder {
    private let responses: [ListenBrainzFixtureReply]
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    init(responses: [ListenBrainzFixtureReply]) { self.responses = responses }

    func reply(for request: URLRequest) -> ListenBrainzFixtureReply {
        lock.lock()
        let index = recordedRequests.count
        recordedRequests.append(request)
        let reply = responses[min(index, responses.count - 1)]
        lock.unlock()
        return reply
    }
}

private final class ListenBrainzFixtureURLProtocol: URLProtocol {
    static var recorder: ListenBrainzRequestRecorder?
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
