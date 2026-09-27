import Foundation

struct MediaSizeResolver {
    static func advertisedSize(for url: URL) -> Int64? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        for name in ["clen", "contentLength", "content-length"] {
            if let value = items.first(where: { $0.name == name })?.value,
               let size = Int64(value), size > 0 {
                return size
            }
        }
        return nil
    }

    static func serverSize(for url: URL) async -> Int64? {
        if let size = advertisedSize(for: url) { return size }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let response = response as? HTTPURLResponse,
              (200..<400).contains(response.statusCode) else { return nil }
        let size = response.expectedContentLength
        return size > 0 ? size : nil
    }

    static func combinedSize(_ first: Int64?, _ second: Int64?) -> Int64? {
        guard let first, let second else { return nil }
        let (sum, overflow) = first.addingReportingOverflow(second)
        return overflow ? nil : sum
    }
}
