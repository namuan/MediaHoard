import Foundation

struct MediaChoice: Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case video
        case audio
        case direct
    }

    let id: String
    let title: String
    let url: URL
    let audioURL: URL?
    let fileExtension: String
    var expectedSizeBytes: Int64?
    let kind: Kind
    let detail: String
}

struct LibraryFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
    var name: String { url.lastPathComponent }
    var size: Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}

enum MediaError: LocalizedError {
    case unsupported
    case noStreams
    case invalidResponse
    case emptyFile

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Enter a direct HTTPS media link or a supported YouTube video URL."
        case .noStreams:
            return "No downloadable audio or combined audio/video streams were found."
        case .invalidResponse:
            return "The server did not return a successful download."
        case .emptyFile:
            return "The downloaded file was empty."
        }
    }
}
