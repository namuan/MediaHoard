import Foundation
import SwiftUI

@MainActor
final class DownloadManager: NSObject, ObservableObject, @preconcurrency URLSessionDownloadDelegate {
    @Published private(set) var files: [LibraryFile] = []
    @Published private(set) var progress: Double?
    @Published private(set) var speedBytesPerSecond: Double?
    @Published private(set) var activeName: String?
    @Published var errorMessage: String?

    private var session: URLSession!
    private var activeTask: URLSessionDownloadTask?
    private var muxTask: Task<Void, Never>?
    private var activeChoice: MediaChoice?
    private var downloadedVideoURL: URL?
    private var downloadedAudioURL: URL?
    private var isDownloadingAudio = false
    private var speedSamples: [(date: Date, bytes: Int64)] = []
    private var currentName = "download"
    private let folder: URL
    private let visibleFolder: URL

    override init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = support.appendingPathComponent("Downloads", isDirectory: true)
        visibleFolder = documents.appendingPathComponent("Downloads", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: visibleFolder, withIntermediateDirectories: true)
        migrateVisibleFiles()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        refresh()
    }

    func start(_ choice: MediaChoice, title: String) {
        guard activeTask == nil, muxTask == nil else { return }
        currentName = Self.safeFilename(title) + "." + choice.fileExtension
        activeChoice = choice
        downloadedVideoURL = nil
        downloadedAudioURL = nil
        isDownloadingAudio = false
        activeName = currentName
        progress = nil
        speedBytesPerSecond = nil
        speedSamples = [(Date(), 0)]
        errorMessage = nil
        activeTask = session.downloadTask(with: choice.url)
        activeTask?.resume()
    }

    func cancel() {
        activeTask?.cancel()
        muxTask?.cancel()
        activeTask = nil
        muxTask = nil
        clearTemporaryTrack()
        activeChoice = nil
        activeName = nil
        progress = nil
        speedBytesPerSecond = nil
        speedSamples = []
    }

    func delete(_ file: LibraryFile) {
        do {
            try FileManager.default.removeItem(at: file.url)
            let visibleURL = visibleFolder.appendingPathComponent(file.name)
            try? FileManager.default.removeItem(at: visibleURL)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        let mediaFiles = contents.filter { !$0.lastPathComponent.hasPrefix(".") }
        for file in mediaFiles {
            let visibleURL = visibleFolder.appendingPathComponent(file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: visibleURL.path) {
                do {
                    try FileManager.default.linkItem(at: file, to: visibleURL)
                } catch {
                    try? FileManager.default.copyItem(at: file, to: visibleURL)
                }
            }
        }
        files = mediaFiles.map(LibraryFile.init(url:)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func migrateVisibleFiles() {
        let visibleFiles = (try? FileManager.default.contentsOfDirectory(at: visibleFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for visibleFile in visibleFiles {
            let libraryURL = folder.appendingPathComponent(visibleFile.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: libraryURL.path) else { continue }
            try? FileManager.default.moveItem(at: visibleFile, to: libraryURL)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        }
        let now = Date()
        speedSamples.append((now, totalBytesWritten))
        let cutoff = now.addingTimeInterval(-3)
        while speedSamples.count > 2 && speedSamples[1].date < cutoff {
            speedSamples.removeFirst()
        }
        if let first = speedSamples.first, let last = speedSamples.last {
            let elapsed = last.date.timeIntervalSince(first.date)
            if elapsed > 0 {
                speedBytesPerSecond = Double(last.bytes - first.bytes) / elapsed
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            finish(with: MediaError.invalidResponse.localizedDescription)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            finish(with: MediaError.invalidResponse.localizedDescription)
            return
        }

        do {
            let values = try location.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) > 0 else { throw MediaError.emptyFile }

            if let choice = activeChoice, let audioURL = choice.audioURL {
                let trackURL = try temporaryTrackURL(extension: isDownloadingAudio ? "m4a" : "mp4")
                try FileManager.default.moveItem(at: location, to: trackURL)
                if !isDownloadingAudio {
                    downloadedVideoURL = trackURL
                    isDownloadingAudio = true
                    activeName = "Downloading audio track…"
                    progress = nil
                    speedBytesPerSecond = nil
                    speedSamples = [(Date(), 0)]
                    activeTask = session.downloadTask(with: audioURL)
                    activeTask?.resume()
                } else if let downloadedVideoURL {
                    downloadedAudioURL = trackURL
                    activeTask = nil
                    activeName = "Combining audio and video…"
                    progress = nil
                    speedBytesPerSecond = nil
                    speedSamples = []
                    muxTask = Task { await finalize(videoURL: downloadedVideoURL, audioURL: trackURL) }
                } else {
                    throw MediaError.invalidResponse
                }
                return
            }

            let destination = uniqueURL(for: currentName)
            try FileManager.default.moveItem(at: location, to: destination)
            refresh()
            finish()
        } catch {
            finish(with: error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        finish(with: error.localizedDescription)
    }

    private func finalize(videoURL: URL, audioURL: URL) async {
        do {
            let combinedURL = try await MediaMuxer.combine(videoURL: videoURL, audioURL: audioURL)
            try Task.checkCancellation()
            let destination = uniqueURL(for: currentName)
            try FileManager.default.moveItem(at: combinedURL, to: destination)
            refresh()
            finish()
        } catch is CancellationError {
            clearTemporaryTrack()
            activeChoice = nil
            activeName = nil
            progress = nil
            muxTask = nil
        } catch {
            finish(with: error.localizedDescription)
        }
    }

    private func finish(with error: String? = nil) {
        if let error { errorMessage = error }
        activeTask = nil
        muxTask = nil
        activeChoice = nil
        activeName = nil
        progress = nil
        speedBytesPerSecond = nil
        speedSamples = []
        clearTemporaryTrack()
    }

    private func temporaryTrackURL(extension fileExtension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MediaHoard-\(UUID().uuidString).\(fileExtension)")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func clearTemporaryTrack() {
        if let downloadedVideoURL { try? FileManager.default.removeItem(at: downloadedVideoURL) }
        if let downloadedAudioURL { try? FileManager.default.removeItem(at: downloadedAudioURL) }
        downloadedVideoURL = nil
        downloadedAudioURL = nil
        isDownloadingAudio = false
    }

    private func uniqueURL(for filename: String) -> URL {
        let original = URL(fileURLWithPath: filename)
        var candidate = folder.appendingPathComponent(filename)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(original.deletingPathExtension().lastPathComponent) (\(index)).\(original.pathExtension)")
            index += 1
        }
        return candidate
    }

    private static func safeFilename(_ value: String) -> String {
        let cleaned = value.unicodeScalars.filter { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_")).contains($0) }
        let result = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String((result.isEmpty ? "download" : result).prefix(100))
    }
}
