import ImageIO
import SwiftUI

/// Resolves the best available image from a video ID without a YouTube Data API request.
@MainActor
final class YouTubeArtwork {
    static let shared = YouTubeArtwork()

    typealias Fetch = @Sendable (URL) async throws -> (Data, URLResponse)

    private let fetch: Fetch
    private let cache = NSCache<NSString, UIImage>()
    private var requests: [String: Task<UIImage?, Never>] = [:]

    init(fetch: @escaping Fetch = { try await URLSession.shared.data(from: $0) }) {
        self.fetch = fetch
        cache.totalCostLimit = 64 * 1_024 * 1_024
    }

    static func candidates(videoID: String, fallback: URL?) -> [URL] {
        let validID = videoID.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil
        var urls: [URL] = []
        if validID {
            for name in ["maxresdefault", "sddefault", "hqdefault"] {
                if let url = URL(string: "https://i.ytimg.com/vi/\(videoID)/\(name).jpg") {
                    urls.append(url)
                }
            }
        }
        if let fallback, !urls.contains(fallback) { urls.append(fallback) }
        return urls
    }

    func image(videoID: String, fallback: URL?) async -> UIImage? {
        let key = (videoID.isEmpty ? fallback?.absoluteString : videoID) ?? ""
        guard !key.isEmpty else { return nil }
        if let image = cache.object(forKey: key as NSString) { return image }
        if let request = requests[key] { return await request.value }

        let fetch = self.fetch
        let candidates = Self.candidates(videoID: videoID, fallback: fallback)
        let request = Task<UIImage?, Never> {
            for url in candidates {
                do {
                    let (data, response) = try await fetch(url)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode),
                          let image = Self.decode(data),
                          Self.isUsable(image, for: url) else { continue }
                    return image
                } catch { continue }
            }
            return nil
        }
        requests[key] = request
        let image = await request.value
        if let image {
            let pixels = Int(image.size.width * image.scale * image.size.height * image.scale)
            cache.setObject(image, forKey: key as NSString, cost: pixels * 4)
        }
        requests[key] = nil
        return image
    }

    private static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_600
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func isUsable(_ image: UIImage, for url: URL) -> Bool {
        let width = image.size.width * image.scale
        let height = image.size.height * image.scale
        switch url.lastPathComponent {
        case "maxresdefault.jpg": return width >= 1_000 && height >= 500
        case "sddefault.jpg": return width >= 640 && height >= 360
        case "hqdefault.jpg": return width >= 480 && height >= 270
        default: return width >= 2 && height >= 2
        }
    }
}

struct YouTubeArtworkView<Placeholder: View>: View {
    let videoID: String
    let fallback: URL?
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: "\(videoID)|\(fallback?.absoluteString ?? "")") {
            image = nil
            image = await YouTubeArtwork.shared.image(videoID: videoID, fallback: fallback)
        }
    }
}
