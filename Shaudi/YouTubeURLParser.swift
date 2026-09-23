//
//  YouTubeURLParser.swift
//  Shaudi
//

import Foundation

enum YouTubeURLParser {
    struct Video {
        let url: URL
        let id: String
    }

    static func parse(_ urlString: String) -> Video? {
        guard
            let components = URLComponents(string: urlString),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host?.lowercased(),
            components.user == nil,
            components.password == nil,
            components.port == nil,
            let url = components.url
        else {
            return nil
        }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let videoID: String?

        switch host {
        case "youtu.be", "www.youtu.be":
            videoID = pathComponents.count == 1 ? pathComponents[0] : nil

        case "youtube.com", "www.youtube.com", "m.youtube.com":
            if pathComponents == ["watch"] {
                videoID = components.queryItems?.first(where: { $0.name == "v" })?.value
            } else if pathComponents.count == 2, pathComponents[0] == "shorts" {
                videoID = pathComponents[1]
            } else {
                videoID = nil
            }

        default:
            videoID = nil
        }

        guard let videoID, isUsableVideoID(videoID) else {
            return nil
        }

        return Video(url: url, id: videoID)
    }

    struct PlaylistReference: Equatable {
        let url: URL
        let id: String
    }

    static func parsePlaylist(_ urlString: String) -> PlaylistReference? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if isUsablePlaylistID(trimmed),
           !trimmed.contains("/"),
           !trimmed.contains("?"),
           !trimmed.contains("&"),
           let canonicalURL = URL(string: "https://www.youtube.com/playlist?list=\(trimmed)") {
            return PlaylistReference(url: canonicalURL, id: trimmed)
        }

        guard
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host?.lowercased(),
            components.user == nil,
            components.password == nil,
            components.port == nil
        else {
            return nil
        }

        let playlistID: String?
        switch host {
        case "youtu.be", "www.youtu.be":
            playlistID = components.queryItems?.first(where: { $0.name == "list" })?.value

        case "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com":
            playlistID = components.queryItems?.first(where: { $0.name == "list" })?.value

        default:
            playlistID = nil
        }

        guard let playlistID, isUsablePlaylistID(playlistID) else {
            return nil
        }

        guard let canonicalURL = URL(string: "https://www.youtube.com/playlist?list=\(playlistID)") else {
            return nil
        }

        return PlaylistReference(url: canonicalURL, id: playlistID)
    }

    static func isUsablePlaylistID(_ playlistID: String) -> Bool {
        let trimmed = playlistID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )

        return trimmed.utf8.count >= 2
            && trimmed.utf8.count <= 128
            && trimmed.unicodeScalars.allSatisfy(allowedCharacters.contains)
    }

    static func isUsableVideoID(_ videoID: String) -> Bool {
        let allowedCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )

        return videoID.utf8.count == 11
            && videoID.unicodeScalars.allSatisfy(allowedCharacters.contains)
    }
}
