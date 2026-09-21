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

    static func isUsableVideoID(_ videoID: String) -> Bool {
        let allowedCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )

        return videoID.utf8.count == 11
            && videoID.unicodeScalars.allSatisfy(allowedCharacters.contains)
    }
}
