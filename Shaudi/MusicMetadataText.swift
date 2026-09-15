//
//  MusicMetadataText.swift
//  Shaudi
//

import Foundation

enum MusicMetadataText {
    private nonisolated static let namedEntities = [
        "quot": "\"",
        "apos": "'",
        "amp": "&",
        "lt": "<",
        "gt": ">",
        "nbsp": "\u{00A0}",
        "ndash": "–",
        "mdash": "—",
        "lsquo": "‘",
        "rsquo": "’",
        "ldquo": "“",
        "rdquo": "”",
        "hellip": "…"
    ]

    nonisolated static func decoded(_ value: String) -> String {
        guard value.contains("&") else {
            return value
        }

        var result = value
        for _ in 0..<3 {
            let decoded = decodeOnce(result)
            guard decoded != result else {
                return result
            }
            result = decoded
        }
        return result
    }

    private nonisolated static func decodeOnce(_ value: String) -> String {
        let pattern = #"&(?:#(?:[xX][0-9a-fA-F]+|[0-9]+)|[A-Za-z]+);"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return value
        }

        var result = value
        let matches = expression.matches(
            in: result,
            range: NSRange(result.startIndex..<result.endIndex, in: result)
        )
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else {
                continue
            }
            let entity = String(result[range])
            guard let replacement = replacement(for: entity) else {
                continue
            }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private nonisolated static func replacement(for entity: String) -> String? {
        let body = entity.dropFirst().dropLast()
        if body.hasPrefix("#") {
            let numeric = body.dropFirst()
            let value: UInt32?
            if numeric.hasPrefix("x") || numeric.hasPrefix("X") {
                value = UInt32(numeric.dropFirst(), radix: 16)
            } else {
                value = UInt32(numeric, radix: 10)
            }
            guard let value, let scalar = UnicodeScalar(value) else {
                return nil
            }
            return String(Character(scalar))
        }
        return namedEntities[body.lowercased()]
    }
}
