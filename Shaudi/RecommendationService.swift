//
//  RecommendationService.swift
//  Shaudi
//

import Foundation

struct RecommendationSeed {
    let youtubeVideoID: String
    let title: String
    let displayedArtist: String?
    let sourceChannel: String?
}

struct RecommendationService {
    private struct RankedCandidate {
        let result: YouTubeSearchResult
        let score: Int
        let signature: String
    }

    private let metadataClient = YouTubeMetadataClient()
    private let resultLimit = 3

    func recommendations(
        for seed: RecommendationSeed,
        excluding excludedVideoIDs: Set<String>
    ) async throws -> [YouTubeSearchResult] {
        let queries = focusedQueries(for: seed)
        var candidates: [YouTubeSearchResult] = []
        var seenVideoIDs = excludedVideoIDs
        seenVideoIDs.insert(normalizedVideoID(seed.youtubeVideoID))

        for query in queries {
            let page = try await metadataClient.search(query: query)
            for result in page.results {
                let videoID = normalizedVideoID(result.youtubeVideoID)
                guard !videoID.isEmpty, seenVideoIDs.insert(videoID).inserted else {
                    continue
                }
                candidates.append(result)
            }

            if rankedCandidates(candidates, seed: seed).count >= resultLimit {
                break
            }
        }

        return Array(
            rankedCandidates(candidates, seed: seed)
                .prefix(resultLimit)
                .map(\.result)
        )
    }

    private func focusedQueries(for seed: RecommendationSeed) -> [String] {
        let artist = cleanedQueryComponent(
            seed.displayedArtist ?? seed.sourceChannel ?? ""
        )
        let title = cleanedQueryComponent(seed.title)

        var queries: [String] = []
        if !artist.isEmpty {
            queries.append("\(artist) \(title) similar songs music")
            queries.append("\(artist) songs official audio")
        } else {
            queries.append("\(title) similar songs music")
            queries.append("\(title) related music")
        }

        var seen = Set<String>()
        return queries.filter { seen.insert($0.lowercased()).inserted }
    }

    private func rankedCandidates(
        _ candidates: [YouTubeSearchResult],
        seed: RecommendationSeed
    ) -> [RankedCandidate] {
        let seedArtistTokens = tokens(
            seed.displayedArtist ?? seed.sourceChannel ?? ""
        )
        let seedTitleTokens = meaningfulTitleTokens(seed.title)
        let seedSignature = titleSignature(seed.title, artistTokens: seedArtistTokens)

        let ranked = candidates.enumerated().compactMap { index, result -> RankedCandidate? in
            let normalizedTitle = normalizedText(result.title)
            guard !containsExcludedVariant(normalizedTitle) else {
                return nil
            }

            let candidateArtistTokens = tokens(result.channelTitle)
            let candidateTitleTokens = meaningfulTitleTokens(result.title)
            let signature = titleSignature(
                result.title,
                artistTokens: candidateArtistTokens.union(seedArtistTokens)
            )
            guard !signature.isEmpty, signature != seedSignature else {
                return nil
            }

            let artistOverlap = seedArtistTokens.intersection(candidateArtistTokens).count
            let titleOverlap = seedTitleTokens.intersection(candidateTitleTokens).count
            var score = max(0, 30 - index)

            if !seedArtistTokens.isEmpty, candidateArtistTokens == seedArtistTokens {
                score += 80
            } else {
                score += artistOverlap * 24
            }
            score += titleOverlap * 12

            if normalizedTitle.contains("official audio")
                || normalizedTitle.contains("official music video")
            {
                score += 10
            }
            if containsSoftVariant(normalizedTitle) {
                score -= 32
            }

            guard score >= 8 else {
                return nil
            }
            return RankedCandidate(result: result, score: score, signature: signature)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.result.youtubeVideoID < rhs.result.youtubeVideoID
        }

        var seenSignatures = Set<String>()
        return ranked.filter { seenSignatures.insert($0.signature).inserted }
    }

    private func containsExcludedVariant(_ title: String) -> Bool {
        [
            "reaction", "interview", "tutorial", "karaoke", "sped up",
            "speed up", "slowed", "nightcore", "8d audio", " youtube shorts",
            " #shorts"
        ].contains { title.contains($0) }
    }

    private func containsSoftVariant(_ title: String) -> Bool {
        ["lyrics", "lyric video", " live", "cover"].contains {
            title.contains($0)
        }
    }

    private func titleSignature(
        _ title: String,
        artistTokens: Set<String>
    ) -> String {
        let ignored = artistTokens.union([
            "official", "audio", "video", "music", "lyrics", "lyric", "live",
            "cover", "remix", "visualizer", "hd", "hq"
        ])
        let remaining = tokens(title).subtracting(ignored)
        return remaining.sorted().joined(separator: " ")
    }

    private func meaningfulTitleTokens(_ value: String) -> Set<String> {
        tokens(value).subtracting([
            "official", "audio", "video", "music", "lyrics", "lyric", "the",
            "and", "feat", "ft", "with", "from"
        ])
    }

    private func tokens(_ value: String) -> Set<String> {
        Set(
            normalizedText(value)
                .split(separator: " ")
                .map(String.init)
                .filter { $0.count > 1 }
        )
    }

    private func normalizedText(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")
    }

    private func cleanedQueryComponent(_ value: String) -> String {
        normalizedText(value)
    }

    private func normalizedVideoID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
