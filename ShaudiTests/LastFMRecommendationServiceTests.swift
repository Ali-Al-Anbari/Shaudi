import Foundation
import XCTest
@testable import Shaudi

final class LastFMRecommendationServiceTests: XCTestCase {
    func testSimilarTracksDecodesAndMapsMultipleTracks() async throws {
        let service = makeService(json: """
        {"similartracks":{"track":[
          {"name":"  Strong Enough  ","match":"0.9","url":"https://www.last.fm/music/Cher/_/Strong+Enough","artist":{"name":" Cher "}},
          {"name":"Song Two","match":0.5,"artist":{"name":"Artist Two"}},
          {"name":"  ","match":"0.2","artist":{"name":"Artist Three"}}
        ],"@attr":{"artist":"Cher","track":"Believe"}}}
        """)

        let tracks = try await service.similarTracks(artist: "Cher", title: "Believe", limit: 50)

        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks.map(\.artist), ["Cher", "Artist Two"])
        XCTAssertEqual(tracks.map(\.title), ["Strong Enough", "Song Two"])
        XCTAssertEqual(tracks.map(\.match), [0.9, 0.5])
        XCTAssertNotNil(tracks[0].url)
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(FixtureURLProtocol.lastURL), resolvingAgainstBaseURL: false))
        let parameters = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(parameters["method"], "track.getSimilar")
        XCTAssertEqual(parameters["format"], "json")
        XCTAssertEqual(parameters["artist"], "Cher")
        XCTAssertEqual(parameters["track"], "Believe")
        XCTAssertEqual(parameters["autocorrect"], "1")
        XCTAssertEqual(parameters["limit"], "50")
        XCTAssertFalse((parameters["api_key"] ?? "").isEmpty)
    }

    func testSimilarTracksEmptyResponseReturnsNoCandidates() async throws {
        let service = makeService(json: """
        {"similartracks":{"track":[],"@attr":{"artist":"Lil Uzi Vert","track":"XO TOUR Llif3"}}}
        """)

        let tracks = try await service.similarTracks(artist: "Lil Uzi Vert", title: "XO TOUR Llif3")

        XCTAssertTrue(tracks.isEmpty)
        let components = try XCTUnwrap(URLComponents(
            url: XCTUnwrap(FixtureURLProtocol.lastURL), resolvingAgainstBaseURL: false
        ))
        let parameters = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(parameters["artist"], "Lil Uzi Vert")
        XCTAssertEqual(parameters["track"], "XO TOUR Llif3")
    }

    func testSimilarTracksMalformedResponseThrows() async throws {
        let service = makeService(json: """
        {"similartracks":{"track":{"name":"not an array"}}}
        """)

        do {
            _ = try await service.similarTracks(artist: "Cher", title: "Believe")
            XCTFail("Expected malformed response")
        } catch LastFMRecommendationService.ServiceError.malformedResponse {
        }
    }

    func testSimilarTracksAPIErrorThrowsEvenWithHTTP200() async throws {
        let service = makeService(json: """
        {"error":6,"message":"Track not found"}
        """)

        do {
            _ = try await service.similarTracks(artist: "Cher", title: "Believe")
            XCTFail("Expected Last.fm API error")
        } catch LastFMRecommendationService.ServiceError.api(let code, let message) {
            XCTAssertEqual(code, 6)
            XCTAssertEqual(message, "Track not found")
        }
    }

    func testSimilarTracksAcceptsCorrectedArtistAndTitleAttributes() async throws {
        let service = makeService(json: """
        {"similartracks":{"track":[
          {"name":"Strong Enough","match":"1.0","artist":{"name":"Cher"}}
        ],"@attr":{"artist":"Cher","track":"Believe"}}}
        """)

        let tracks = try await service.similarTracks(artist: "cher", title: "belive")

        XCTAssertEqual(tracks.map(\.title), ["Strong Enough"])
    }

    func testTopTracksDecodesWorkingResponseShape() async throws {
        let service = makeService(json: """
        {"toptracks":{"track":[
          {"name":"XO TOUR Llif3","artist":{"name":"Lil Uzi Vert"}}
        ],"@attr":{"artist":"Lil Uzi Vert","total":"74039"}}}
        """)

        let tracks = try await service.topTracks(artist: "Lil Uzi Vert", limit: 10)

        XCTAssertEqual(tracks, [LastFMTopTrack(artist: "Lil Uzi Vert", title: "XO TOUR Llif3")])
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(FixtureURLProtocol.lastURL), resolvingAgainstBaseURL: false))
        let parameters = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(parameters["method"], "artist.getTopTracks")
        XCTAssertEqual(parameters["artist"], "Lil Uzi Vert")
        XCTAssertEqual(parameters["autocorrect"], "1")
        XCTAssertEqual(parameters["limit"], "10")
        XCTAssertEqual(parameters["format"], "json")
    }

    private func makeService(json: String) -> LastFMRecommendationService {
        FixtureURLProtocol.responseData = Data(json.utf8)
        FixtureURLProtocol.lastURL = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return LastFMRecommendationService(session: URLSession(configuration: configuration))
    }
}

private final class FixtureURLProtocol: URLProtocol {
    static var responseData = Data()
    static var lastURL: URL?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastURL = request.url
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
