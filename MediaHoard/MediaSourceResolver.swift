import Foundation
import YouTubeKit

struct MediaSourceResolver {
    func choices(for input: String) async throws -> (String, [MediaChoice]) {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host?.lowercased() else {
            throw MediaError.unsupported
        }

        if isYouTube(host) {
            guard let videoID = youtubeVideoID(from: url) else { throw MediaError.unsupported }
            let video = YouTube(videoID: videoID)
            let streams = try await video.streams
            let metadata = try await video.metadata
            let title = metadata?.title ?? "YouTube video"
            let safeStreams = streams.filter { $0.url.scheme?.lowercased() == "https" }
            var choices = safeStreams.enumerated().compactMap { index, stream -> MediaChoice? in
                let ext = stream.fileExtension.rawValue
                guard ext != "unknown" else { return nil }
                if stream.includesVideoAndAudioTrack {
                    return MediaChoice(id: "video-\(index)", title: "Video · \(stream.videoResolution ?? 0)p", url: stream.url, audioURL: nil, fileExtension: ext, expectedSizeBytes: MediaSizeResolver.advertisedSize(for: stream.url), kind: .video, detail: "Combined audio and video")
                }
                if stream.includesAudioTrack && !stream.includesVideoTrack {
                    return MediaChoice(id: "audio-\(index)", title: "Audio · \(ext.uppercased())", url: stream.url, audioURL: nil, fileExtension: ext, expectedSizeBytes: MediaSizeResolver.advertisedSize(for: stream.url), kind: .audio, detail: stream.bitrate.map { "\($0 / 1000) kbps" } ?? "Audio only")
                }
                return nil
            }
            let audioStreams = safeStreams.filter {
                $0.includesAudioTrack && !$0.includesVideoTrack && $0.fileExtension.rawValue == "m4a" && $0.audioCodec?.isNativelyPlayable == true
            }
            let videoStreams = safeStreams.filter {
                guard $0.includesVideoTrack && !$0.includesAudioTrack,
                      $0.fileExtension.rawValue == "mp4",
                      $0.isNativelyPlayable,
                      let resolution = $0.videoResolution,
                      resolution > 0 else { return false }
                if case .avc1 = $0.videoCodec { return true }
                if case .mp4v = $0.videoCodec { return true }
                return false
            }
            if let audio = audioStreams.max(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }) {
                for (index, videoStream) in videoStreams.enumerated() {
                    let resolution = videoStream.videoResolution ?? 0
                    let bitrate = audio.bitrate.map { " · \($0 / 1000) kbps audio" } ?? ""
                    choices.append(MediaChoice(id: "muxed-\(index)", title: "Video · \(resolution)p", url: videoStream.url, audioURL: audio.url, fileExtension: "mp4", expectedSizeBytes: MediaSizeResolver.combinedSize(MediaSizeResolver.advertisedSize(for: videoStream.url), MediaSizeResolver.advertisedSize(for: audio.url)), kind: .video, detail: "MP4 with audio\(bitrate)"))
                }
            }
            choices.sort { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind == .video }
                if lhs.kind == .video {
                    let leftResolution = Int(lhs.title.split(separator: "·").last?.trimmingCharacters(in: .whitespaces).dropLast() ?? "0") ?? 0
                    let rightResolution = Int(rhs.title.split(separator: "·").last?.trimmingCharacters(in: .whitespaces).dropLast() ?? "0") ?? 0
                    if leftResolution != rightResolution { return leftResolution > rightResolution }
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            guard !choices.isEmpty else { throw MediaError.noStreams }
            return (title, await resolvingSizes(for: choices))
        }

        let allowedHosts = ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "music.youtube.com"]
        guard !allowedHosts.contains(host), !host.hasSuffix(".youtube.com") else { throw MediaError.unsupported }
        let ext = url.pathExtension.lowercased()
        let supportedExtensions = ["mp4", "mov", "m4v", "mp3", "m4a", "aac", "wav", "webm", "mp4a"]
        guard supportedExtensions.contains(ext) else { throw MediaError.unsupported }
        let kind: MediaChoice.Kind = ["mp3", "m4a", "aac", "wav", "mp4a"].contains(ext) ? .audio : .direct
        let choice = MediaChoice(id: "direct", title: "Original · \(ext.uppercased())", url: url, audioURL: nil, fileExtension: ext, expectedSizeBytes: await MediaSizeResolver.serverSize(for: url), kind: kind, detail: host)
        return (url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? "Download", [choice])
    }

    private func isYouTube(_ host: String) -> Bool {
        host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    private func resolvingSizes(for choices: [MediaChoice]) async -> [MediaChoice] {
        await withTaskGroup(of: (Int, Int64?).self) { group in
            for (index, choice) in choices.enumerated() where choice.expectedSizeBytes == nil {
                group.addTask {
                    let firstSize = await MediaSizeResolver.serverSize(for: choice.url)
                    guard let audioURL = choice.audioURL else { return (index, firstSize) }
                    let audioSize = await MediaSizeResolver.serverSize(for: audioURL)
                    return (index, MediaSizeResolver.combinedSize(firstSize, audioSize))
                }
            }
            var resolved = choices
            for await (index, size) in group {
                resolved[index].expectedSizeBytes = size
            }
            return resolved
        }
    }

    private func youtubeVideoID(from url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        let candidate: String?
        if host == "youtu.be" {
            candidate = url.pathComponents.dropFirst().first
        } else if url.path == "/watch" {
            candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value
        } else {
            let parts = url.pathComponents.dropFirst()
            if let marker = parts.firstIndex(where: { ["shorts", "embed", "live", "v"].contains($0) }), parts.index(after: marker) < parts.endIndex {
                candidate = parts[parts.index(after: marker)]
            } else {
                candidate = nil
            }
        }
        guard let candidate, candidate.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else { return nil }
        return candidate
    }
}
